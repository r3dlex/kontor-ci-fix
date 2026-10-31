defmodule Kontor.CI.SelfHostedWorkflowTest do
  @moduledoc """
  Regression coverage for the self-hosted legs of the GitHub Actions workflows.

  Two invariants are locked here:

    1. Every self-hosted job that installs Elixir with `erlef/setup-beam`
       declares `env.ImageOS` and isolates `MIX_HOME`/`HEX_HOME` under
       `$RUNNER_TEMP`. setup-beam resolves its target OS from `ImageOS` and
       aborts when it is unset ("Tried to map a target OS from env. variable
       'ImageOS' (got undefined)"), and the macOS runners share one `$HOME`
       with the Linux ones, so a shared Hex archive is corrupted by
       concurrent jobs.
    2. Every artifact upload fails the job when it finds no files, and every
       self-hosted release leg asserts that the artifact was really produced
       before it reports success. Burrito writes `burrito_out/<release>_<target>`,
       so a glob that only matches a bare `<target>` name uploads nothing —
       with `if-no-files-found: warn` that shipped a release without a binary.

  The pre-fix `release.yml` violated every one of these rules, so this file
  fails against it and passes against the fixed workflows.
  """

  use ExUnit.Case, async: true

  @workflows Path.expand("../../.github/workflows", __DIR__)

  test "every self-hosted job that installs Elixir declares ImageOS and isolates Mix and Hex" do
    violations =
      for path <- workflow_files(),
          {job_id, job} <- jobs(path),
          self_hosted?(job),
          installs_elixir?(job),
          reason <- install_policy_violations(job),
          do: "#{Path.basename(path)}:#{job_id}: #{reason}"

    assert violations == []
  end

  test "every release artifact upload fails the job when it finds no files" do
    release = Path.join(@workflows, "release.yml")

    violations =
      for {job_id, job} <- jobs(release),
          step <- steps(job),
          String.contains?(to_string(step["uses"] || ""), "actions/upload-artifact"),
          with_options = step["with"] || %{},
          to_string(with_options["if-no-files-found"] || "") != "error",
          do: "#{job_id}:#{step["name"] || step["uses"]}"

    assert violations == []
  end

  test "the self-hosted release legs assert the artifact exists before reporting success" do
    release = Path.join(@workflows, "release.yml")

    for {job_id, job} <- jobs(release),
        self_hosted?(job),
        installs_elixir?(job) do
      gate = Enum.find(steps(job), &(&1["id"] == "gate"))

      assert gate, "#{job_id} has no gate step"

      run = to_string(gate["run"] || "")

      assert run =~ "BURRITO_TARGET", "#{job_id}: the gate step does not look at the built artifact"
      assert run =~ "burrito_out/", "#{job_id}: the gate step does not look at burrito's output dir"
      assert run =~ "exit 1", "#{job_id}: the gate step cannot fail"
    end
  end

  test "the self-hosted release legs upload a glob that matches burrito's output name" do
    release = Path.join(@workflows, "release.yml")

    for {job_id, job} <- jobs(release),
        self_hosted?(job),
        installs_elixir?(job) do
      upload =
        Enum.find(steps(job), &String.contains?(to_string(&1["uses"] || ""), "upload-artifact"))

      assert upload, "#{job_id} does not upload an artifact"

      path = to_string((upload["with"] || %{})["path"] || "")
      target = target_of(job)

      assert target, "#{job_id} does not name its burrito target"

      # Burrito names the binary burrito_out/<release>_<target>, so the glob
      # needs a wildcard on both sides of the target to match it.
      assert path =~ "*#{target}*",
             "#{job_id}: the upload path #{path} cannot match burrito_out/<release>_#{target}"
    end
  end

  defp workflow_files, do: Path.wildcard(Path.join(@workflows, "*.yml"))

  defp jobs(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, document} -> Map.get(document, "jobs", %{})
      _ -> %{}
    end
  end

  defp steps(job), do: List.wrap(job["steps"] || [])

  defp self_hosted?(job) do
    case job["runs-on"] do
      labels when is_list(labels) -> "self-hosted" in labels
      _ -> false
    end
  end

  defp installs_elixir?(job) do
    Enum.any?(steps(job), &String.contains?(to_string(&1["uses"] || ""), "setup-beam"))
  end

  defp install_policy_violations(job) do
    violations = []

    violations =
      if blank?(get_in(job, ["env", "ImageOS"])) do
        violations ++ ["env.ImageOS is not set, so setup-beam aborts on a self-hosted runner"]
      else
        violations
      end

    run_scripts =
      job
      |> steps()
      |> Enum.map_join("\n", &to_string(&1["run"] || ""))

    violations =
      if String.contains?(run_scripts, "MIX_HOME=$RUNNER_TEMP/") do
        violations
      else
        violations ++ ["no step isolates MIX_HOME under $RUNNER_TEMP"]
      end

    violations =
      if String.contains?(run_scripts, "HEX_HOME=$RUNNER_TEMP/") do
        violations
      else
        violations ++ ["no step isolates HEX_HOME under $RUNNER_TEMP"]
      end

    violations
  end

  defp target_of(job) do
    job
    |> steps()
    |> Enum.find_value(fn step ->
      target = to_string((step["env"] || %{})["BURRITO_TARGET"] || "")

      if target == "", do: nil, else: target
    end)
  end

  defp blank?(value), do: value in [nil, ""]
end
