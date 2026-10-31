defmodule Kontor.Automations do
  @moduledoc "Context module for webhook registration and delivery for n8n automation integration."

  import Ecto.Query
  require Logger
  alias Kontor.Repo
  alias Kontor.Automations.Webhook

  @doc "Register a new webhook for the given tenant."
  def register_webhook(tenant_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("tenant_id", tenant_id)

    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
  end

  @doc "List all webhooks for the given tenant."
  def list_webhooks(tenant_id) do
    Repo.all(from w in Webhook, where: w.tenant_id == ^tenant_id, order_by: [asc: w.inserted_at])
  end

  @doc """
  Deliver a skill-scoped webhook payload with an async HTTP POST.

  Delivery lives here rather than in the AI pipeline so that no module under
  `lib/kontor/ai/` performs a direct HTTP call — ARCH-003 reserves outbound
  requests for the designated clients.
  """
  def post_webhook(url, payload) do
    Task.start(fn ->
      case Req.post(url, json: payload) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Webhook POST to #{url} failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Fire a single webhook with an async HTTP POST carrying the event payload.
  Signs the request body with HMAC-SHA256 using the webhook secret and includes
  the signature in the `X-Kontor-Signature` header.
  """
  def fire_webhook(%Webhook{} = webhook, event_type, payload) do
    Task.start(fn ->
      body = Jason.encode!(%{event_type: event_type, payload: payload})
      signature = hmac_signature(webhook.secret, body)

      result =
        Req.post(webhook.url,
          body: body,
          headers: [
            {"content-type", "application/json"},
            {"x-kontor-signature", "sha256=#{signature}"},
            {"x-kontor-event", event_type}
          ]
        )

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case result do
        {:ok, %{status: status}} when status in 200..299 ->
          webhook
          |> Webhook.changeset(%{last_triggered_at: now, failure_count: 0})
          |> Repo.update()

        _ ->
          webhook
          |> Webhook.changeset(%{failure_count: (webhook.failure_count || 0) + 1})
          |> Repo.update()
      end
    end)

    :ok
  end

  @doc """
  Find all active webhooks for the tenant that match the event_type and fire them.
  """
  def fire_event(tenant_id, event_type, payload) do
    webhooks =
      Repo.all(
        from w in Webhook,
          where: w.tenant_id == ^tenant_id and w.active == true and ^event_type in w.event_types
      )

    Enum.each(webhooks, &fire_webhook(&1, event_type, payload))

    {:ok, length(webhooks)}
  end

  defp hmac_signature(nil, _body), do: ""
  defp hmac_signature(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
