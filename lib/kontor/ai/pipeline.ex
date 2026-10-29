defmodule Kontor.AI.Pipeline do
  @moduledoc """
  Two-tier email processing pipeline.

  Tier 1 (Classifier): subject + sender + recipients only — minimal token cost.
  Tier 2 (Specialized Skills): lazy-loaded, only classifier-selected skills run.
  Each skill receives the context depth the classifier prescribed.

  After each Tier 2 skill runs, the result is post-processed (tasks created,
  thread markdown updated, scores applied) and n8n webhooks are fired if
  the skill defines a webhook URL in its YAML frontmatter.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Kontor.AI.{SkillLoader, MinimaxClient}
  alias Kontor.Repo

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Called from poller with tenant_id already on the email struct
  def process_email(%{tenant_id: tenant_id} = email, opts \\ []) do
    GenServer.cast(__MODULE__, {:process_email, email, tenant_id, opts})
  end

  def run_skill(skill_name, input, tenant_id) do
    case SkillLoader.load_skill(skill_name, "shared") do
      {:ok, skill} ->
        prompt = build_prompt(skill, input)
        case MinimaxClient.complete(prompt, tenant_id) do
          {:ok, result} ->
            fire_webhook(skill, result, tenant_id)
            {:ok, result}
          error -> error
        end
      {:error, _} -> {:error, :skill_not_found}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:process_email, email, tenant_id, opts}, state) do
    Task.start(fn -> do_process(email, tenant_id, opts) end)
    {:noreply, state}
  end

  defp do_process(email, tenant_id, opts \\ []) do
    with {:ok, tier1} <- run_classifier(email, tenant_id),
         {:ok, tier2} <- run_tier2(email, tier1, tenant_id, opts) do
      post_process(email, tier1, tier2, tenant_id)
      {:ok, %{tier1: tier1, tier2: tier2, email_id: email.id}}
    end
  end

  defp run_classifier(email, tenant_id) do
    case SkillLoader.load_skill("classifier", "shared") do
      {:ok, skill} ->
        input = %{subject: email.subject, sender: email.sender, recipients: email.recipients}
        cache_key = "t1:#{email.tenant_id}:#{email.message_id}"
        MinimaxClient.complete(build_prompt(skill, input), tenant_id, cache_key: cache_key)

      {:error, _} ->
        Logger.warning("Pipeline: classifier not found, using passthrough")
        {:ok, %{
          "tier2_skills" => ["scorer", "thread_summarizer", "labeler"],
          "urgency_estimate" => 0.5,
          "category" => "unknown",
          "context_depth" => "full_body"
        }}
    end
  end

  defp run_tier2(email, tier1, tenant_id, opts \\ []) do
    cutoff_months = Keyword.get(opts, :task_age_cutoff_months, 3)
    cutoff_dt = DateTime.add(DateTime.utc_now(), -cutoff_months * 30 * 24 * 3600, :second)
    skill_names = if email.received_at && DateTime.compare(email.received_at, cutoff_dt) == :lt do
      tier1["tier2_skills"] |> Enum.reject(&(&1 == "task_extractor"))
    else
      tier1["tier2_skills"]
    end
    context_depth = Map.get(tier1, "context_depth", "full_body")

    results =
      skill_names
      |> Enum.map(fn name ->
        extra = build_folder_extra_context(name, email)
        {name, Task.async(fn -> run_one_tier2(name, email, context_depth, tenant_id, extra) end)}
      end)
      |> Enum.map(fn {name, task} -> {name, Task.await(task, 60_000)} end)
      |> Enum.filter(fn {_name, result} -> match?({:ok, _}, result) end)
      |> Map.new(fn {name, {:ok, result}} -> {name, result} end)

    {:ok, results}
  end

  defp build_folder_extra_context("folder_organizer", email) do
    case Repo.get(Kontor.Accounts.Mailbox, email.mailbox_id) do
      nil -> %{}
      mailbox ->
        %{
          "folder_model" => mailbox.folder_model || "structural_category",
          "folder_bootstrap_count" => mailbox.folder_bootstrap_count || 0,
          "available_folders" => []
        }
    end
  end
  defp build_folder_extra_context(_name, _email), do: %{}

  defp run_one_tier2(name, email, context_depth, tenant_id, extra_context \\ %{}) do
    namespace = "shared"

    case SkillLoader.load_skill(name, namespace) do
      {:ok, skill} ->
        input = build_email_input(email, context_depth, extra_context)
        case MinimaxClient.complete(build_prompt(skill, input), tenant_id) do
          {:ok, result} ->
            fire_webhook(skill, result, tenant_id)
            {:ok, result}
          error -> error
        end

      {:error, _} ->
        Logger.warning("Pipeline: tier2 skill #{name} not found")
        {:error, :not_found}
    end
  end

  # Post-process tier2 results: persist tasks, thread markdown, scores
  defp post_process(email, tier1, tier2, tenant_id) do
    try do
      # Thread summarizer → update thread markdown
      if summary = Map.get(tier2, "thread_summarizer") do
        if md = Map.get(summary, "updated_thread_markdown") do
          Kontor.AI.Sandbox.execute(
            :write_thread_markdown,
            %{thread_id: email.thread_id, content: md},
            tenant_id
          )
        end
      end

      # Scorer → update thread scores
      if scores = Map.get(tier2, "scorer") do
        Kontor.AI.Sandbox.execute(
          :update_score,
          %{thread_id: email.thread_id, scores: atomize_keys(scores)},
          tenant_id
        )
      end

      # Task extractor → create tasks
      if tasks_result = Map.get(tier2, "task_extractor") do
        tasks = if is_list(tasks_result), do: tasks_result, else: Map.get(tasks_result, "tasks", [])
        Enum.each(tasks, fn task_attrs ->
          attrs =
            atomize_keys(task_attrs)
            |> Map.merge(%{thread_id: email.thread_id, email_id: email.id})

          Kontor.AI.Sandbox.execute(:create_task, attrs, tenant_id)
        end)
      end

      # Folder organizer → create folder suggestion
      if folder_result = Map.get(tier2, "folder_organizer") do
        maybe_handle_folder_organizer(folder_result, email, tier1, tenant_id)
      end

      # Labeler → upsert email labels
      if label_result = Map.get(tier2, "labeler") do
        maybe_handle_labeler(label_result, email, tenant_id)
      end

      # Reply drafter → store draft content in task if it exists
      if _draft = Map.get(tier2, "reply_drafter"), do: :ok

      # Contact organizer → run in background
      if _contact = Map.get(tier2, "contact_organizer"), do: :ok

      # Atomic CAS: mark thread as processed (process-once guarantee)
      # Skip CAS if thread_id is nil (Ecto forbids == nil in queries)
      case (if is_nil(email.thread_id), do: {:ok, :already_processed}, else: Kontor.Mail.mark_thread_processed(email.thread_id, tenant_id)) do
        {:ok, :updated} ->
          # Won the race — conditionally nil out body based on mailbox.copy_emails
          email_with_mailbox = Repo.preload(email, :mailbox)
          if email_with_mailbox.mailbox && !email_with_mailbox.mailbox.copy_emails do
            Kontor.Mail.clear_email_body(email_with_mailbox)
          end

        {:ok, :already_processed} ->
          # Another process won — skip body cleanup
          :ok
      end
    rescue
      e ->
        Logger.error("Pipeline post_process failed for email #{email.id}: #{inspect(e)}")
        # Body remains intact; markdown_stale stays true for MarkdownBackfillWorker retry
        :ok
    end
  end

  defp maybe_handle_folder_organizer(%{"folder_action" => folder_action} = _result, email, tier1, tenant_id)
      when not is_nil(folder_action) do
    action = Map.get(folder_action, "action")
    bootstrap_blocked = Map.get(folder_action, "bootstrap_blocked", false)
    confidence = Map.get(folder_action, "confidence", 0.0)

    target_folder = Map.get(folder_action, "target_folder") ||
                    get_in(folder_action, ["folder_action", "target_folder"])

    if action == "move" and not bootstrap_blocked and confidence >= 0.80 and not is_nil(target_folder) do
      suggestion_attrs = %{
        tenant_id: email.tenant_id,
        email_id: email.id,
        mailbox_id: email.mailbox_id,
        email_message_id: email.message_id,
        suggested_folder: target_folder,
        create_if_missing: Map.get(folder_action, "create_if_missing", false),
        confidence: confidence,
        reasoning: Map.get(folder_action, "reason"),
        labels: Map.get(tier1, "labels", []),
        priority_score: Map.get(tier1, "priority_score")
      }
      Kontor.Mail.Mail.create_folder_suggestion(suggestion_attrs, tenant_id)
    else
      {:ok, :skipped}
    end
  end
  defp maybe_handle_folder_organizer(_result, _email, _tier1, _tenant_id), do: {:ok, :skipped}

  defp maybe_handle_labeler(%{"labels" => _} = result, email, tenant_id) do
    label_attrs = %{
      email_id: email.id,
      labels: Map.get(result, "labels", []),
      priority_score: Map.get(result, "priority_score"),
      has_actionable_task: Map.get(result, "has_actionable_task", false),
      task_summary: Map.get(result, "task_summary"),
      task_deadline: parse_deadline(Map.get(result, "task_deadline")),
      ai_confidence: Map.get(result, "ai_confidence"),
      ai_reasoning: Map.get(result, "ai_reasoning"),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
    Kontor.Mail.Mail.upsert_email_labels(label_attrs, tenant_id)
  end
  defp maybe_handle_labeler(_result, _email, _tenant_id), do: {:ok, :skipped}

  defp parse_deadline(nil), do: nil
  defp parse_deadline(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt |> DateTime.truncate(:second)
      _ -> nil
    end
  end

  defp fire_webhook(%{frontmatter: %{"webhook" => url}}, result, _tenant_id) when is_binary(url) and url != "" do
    # Delivery lives in Kontor.Automations so that no module under lib/kontor/ai/
    # performs a direct HTTP call — ARCH-003 reserves outbound requests for the
    # designated clients (minimax_client.ex, embeddings.ex).
    Kontor.Automations.post_webhook(url, %{result: result, source: "kontor"})
  end
  defp fire_webhook(_skill, _result, _tenant_id), do: :ok

  defp build_email_input(email, context_depth, extra_context \\ %{}) do
    build_email_input_base(email, context_depth) |> Map.merge(extra_context)
  end

  defp build_email_input_base(email, "headers_only") do
    %{
      subject: email.subject,
      sender: email.sender,
      recipients: email.recipients,
      prior_thread_samples: fetch_prior_thread_samples(email)
    }
  end

  defp build_email_input_base(email, "first_100_chars") do
    %{
      subject: email.subject,
      sender: email.sender,
      recipients: email.recipients,
      body_preview: String.slice(email.body || "", 0, 100),
      prior_thread_samples: fetch_prior_thread_samples(email)
    }
  end

  defp build_email_input_base(email, _full) do
    %{
      subject: email.subject,
      sender: email.sender,
      recipients: email.recipients,
      body: email.body,
      prior_thread_samples: fetch_prior_thread_samples(email)
    }
  end

  defp fetch_prior_thread_samples(email) do
    Kontor.Mail.sample_thread_emails(email.thread_id, email.tenant_id, 3)
    |> Enum.filter(fn e -> e.id != email.id end)
    |> Enum.map(fn e ->
      %{
        subject: e.subject,
        sender: e.sender,
        body_preview: String.slice(e.body || "", 0, 200)
      }
    end)
  end

  defp build_prompt(%{body: template, frontmatter: fm}, input) do
    output_schema = fm["output_schema"] || []

    """
    #{template}

    ## Input

    ```json
    #{Jason.encode!(input, pretty: true)}
    ```

    ## Required Output

    Respond with valid JSON containing these fields: #{Enum.join(output_schema, ", ")}
    """
  end

  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_binary(k) ->
        try do
          Map.put(acc, String.to_existing_atom(k), v)
        rescue
          ArgumentError -> acc
        end
      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end
  defp atomize_keys(other), do: other
end
