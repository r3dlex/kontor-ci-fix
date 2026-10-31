defmodule Kontor.CI.ArchgateCheckTest do
  @moduledoc """
  Regression coverage for `.github/scripts/archgate-check.sh`.

  The script is the ADR gate's non-vacuity guarantee: it must fail the build
  when the archgate run did not actually evaluate the ADR corpus.

  Before the fix, an empty corpus made `archgate adr list --json` print plain
  text ("No ADRs found.") instead of JSON. The `jq` filter behind the
  expectation list then failed, `expected` degraded to an empty string, the
  comparison against the empty string failed again, and the difference came
  out empty — so the gate reported success having evaluated zero rules. Every
  case below drives the real script with a stub `archgate` on PATH, so the
  assertions are about the script's behaviour and not about a fixture.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../.github/scripts/archgate-check.sh", __DIR__)

  setup do
    stub_dir =
      Path.join(System.tmp_dir!(), "kontor-archgate-stub-#{System.unique_integer([:positive])}")

    File.mkdir_p!(stub_dir)
    on_exit(fn -> File.rm_rf!(stub_dir) end)

    File.write!(Path.join(stub_dir, "archgate"), """
    #!/usr/bin/env bash
    case "$1" in
      --version) echo "archgate ${STUB_VERSION:-0.60.0}" ;;
      check) cat "$STUB_DIR/report.json" ;;
      adr) cat "$STUB_DIR/adr-list.txt" ;;
      *) echo "unexpected archgate invocation: $*" >&2; exit 64 ;;
    esac
    """)

    File.chmod!(Path.join(stub_dir, "archgate"), 0o755)

    %{stub_dir: stub_dir}
  end

  test "passes when every ADR that declares rules was evaluated", %{stub_dir: stub_dir} do
    {output, status} = run_gate(stub_dir, report(), adr_list())

    assert status == 0
    assert output =~ "archgate gate passed"
  end

  test "fails closed when the ADR corpus is empty", %{stub_dir: stub_dir} do
    {output, status} = run_gate(stub_dir, empty_report(), "No ADRs found.\n")

    refute status == 0
    assert output =~ "did not return a JSON array"
    refute output =~ "archgate gate passed"
  end

  test "fails closed when the ADR list is not JSON at all", %{stub_dir: stub_dir} do
    {output, status} = run_gate(stub_dir, report(), "error: cannot read .archgate/adrs\n")

    refute status == 0
    assert output =~ "did not return a JSON array"
  end

  test "fails closed when no ADR declares rules: true", %{stub_dir: stub_dir} do
    {output, status} =
      run_gate(stub_dir, report(), ~s([{"id":"ARCH-001","title":"t","domain":"d","rules":false}]\n))

    refute status == 0
    assert output =~ "no ADR declares rules: true"
  end

  test "fails closed when the report evaluated no rule at all", %{stub_dir: stub_dir} do
    {output, status} = run_gate(stub_dir, empty_report(), adr_list())

    refute status == 0
    assert output =~ "total=0"
  end

  test "fails closed when an ADR that declares rules was not evaluated", %{stub_dir: stub_dir} do
    partial_report = """
    {
      "total": 1,
      "passed": 1,
      "failed": 0,
      "warnings": 0,
      "errors": 0,
      "unparsedAdrs": [],
      "results": [
        {"adrId": "ARCH-001", "ruleId": "rule-a", "violations": []}
      ]
    }
    """

    {output, status} = run_gate(stub_dir, partial_report, adr_list())

    refute status == 0
    assert output =~ "evaluated no rules for ADR(s): ARCH-002"
  end

  test "fails closed when the archgate version is not the pinned one", %{stub_dir: stub_dir} do
    {output, status} = run_gate(stub_dir, report(), adr_list(), version: "0.59.0")

    refute status == 0
    assert output =~ "0.60.0 is required"
  end

  defp run_gate(stub_dir, report, adr_list, opts \\ []) do
    File.write!(Path.join(stub_dir, "report.json"), report)
    File.write!(Path.join(stub_dir, "adr-list.txt"), adr_list)

    runner_temp = Path.join(stub_dir, "runner-temp")
    File.mkdir_p!(runner_temp)

    {output, status} =
      System.cmd("bash", [@script],
        env: [
          {"PATH", "#{stub_dir}:#{System.get_env("PATH") || ""}"},
          {"STUB_DIR", stub_dir},
          {"STUB_VERSION", Keyword.get(opts, :version, "0.60.0")},
          {"RUNNER_TEMP", runner_temp}
        ],
        stderr_to_stdout: true
      )

    {output, status}
  end

  defp report do
    """
    {
      "total": 2,
      "passed": 2,
      "failed": 0,
      "warnings": 0,
      "errors": 0,
      "unparsedAdrs": [],
      "results": [
        {"adrId": "ARCH-001", "ruleId": "rule-a", "violations": []},
        {"adrId": "ARCH-002", "ruleId": "rule-b", "violations": []}
      ]
    }
    """
  end

  defp empty_report do
    """
    {
      "total": 0,
      "passed": 0,
      "failed": 0,
      "warnings": 0,
      "errors": 0,
      "unparsedAdrs": [],
      "results": []
    }
    """
  end

  defp adr_list do
    ~s([{"id":"ARCH-001","title":"a","domain":"d","rules":true},) <>
      ~s({"id":"ARCH-002","title":"b","domain":"d","rules":true}]\n)
  end
end
