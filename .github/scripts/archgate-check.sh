#!/usr/bin/env bash
#
# Run the archgate ADR gate and fail loudly when it did not actually evaluate
# the ADR corpus.
#
# A plain `archgate check` is not a governance gate on its own:
#
#  1. archgate skips every ADR whose file scope does not intersect the
#     changed-file set and still exits 0. A PR that touches nothing governed
#     would report success without evaluating a single rule. `--staged` pins
#     the changed-file set to the git index, which is empty in CI, so every ADR
#     in the corpus is evaluated on every run.
#  2. an ADR whose frontmatter does not parse is dropped from the corpus
#     silently. The report lists those under `unparsedAdrs`; this script fails
#     the build when that list is not empty.
#
# On top of that it asserts that every ADR declaring `rules: true` produced at
# least one result, so a skipped ADR fails the build instead of passing it.
# The assertions fail closed: an empty or unreadable ADR corpus, a corpus in
# which no ADR declares `rules: true`, and a report that evaluated no rule at
# all are all errors, never an empty list that compares equal to nothing.
#
# The archgate version is pinned: the self-hosted leg runs the binary the
# runner host was provisioned with (there is no upstream linux/arm64 release)
# and the hosted leg installs the same version, so both legs evaluate the same
# rules.
set -uo pipefail

EXPECTED_ARCHGATE_VERSION="0.60.0"
REPORT="${RUNNER_TEMP:-/tmp}/archgate-report.json"
mkdir -p "$(dirname "$REPORT")"

# Locate the archgate binary. The self-hosted Linux/ARM64 runners ship a
# source-built archgate on PATH (upstream publishes no linux/arm64 asset), and
# the hosted leg installs the pinned release via archgate/setup-action.
if command -v archgate >/dev/null 2>&1; then
  ARCHGATE_BIN="$(command -v archgate)"
elif [ -x "${HOME:-/nonexistent}/.archgate/bin/archgate" ]; then
  ARCHGATE_BIN="$HOME/.archgate/bin/archgate"
else
  echo "::error::archgate was not found on PATH nor at $HOME/.archgate/bin/archgate"
  exit 1
fi

version="$("$ARCHGATE_BIN" --version 2>&1 | tr -d '\r')"
version_token="$(printf '%s' "$version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "archgate binary: $ARCHGATE_BIN"
echo "archgate version: $version"
if [ "$version_token" != "$EXPECTED_ARCHGATE_VERSION" ]; then
  echo "::error::archgate $EXPECTED_ARCHGATE_VERSION is required so the self-hosted and hosted legs evaluate the same rules; found '$version'"
  exit 1
fi

status=0

# Keep the most specific failure: archgate exits 2 for rule errors and 1 for
# error-severity violations, and the assertions below must not downgrade that.
fail_gate() {
  echo "::error::$1"
  if [ "$status" -eq 0 ]; then
    status=1
  fi
}

"$ARCHGATE_BIN" check --staged --output json --verbose >"$REPORT" || status=$?

# GitHub Actions annotations, one per violation.
jq -r '
  .results[]? as $result
  | $result.violations[]?
  | (if .severity == "error" then "error"
     elif .severity == "warning" then "warning"
     else "notice" end) as $level
  | "::" + $level
    + (if .file then " file=" + .file else "" end)
    + (if .line then ",line=" + (.line | tostring) else "" end)
    + " title=" + $result.adrId + "/" + $result.ruleId + "::"
    + (.message | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A"))
' "$REPORT"

unparsed="$(jq -r '.unparsedAdrs[]?' "$REPORT")"
if [ -n "$unparsed" ]; then
  fail_gate "ADR frontmatter failed to parse, so the ADR was dropped from the corpus: $(echo "$unparsed" | tr '\n' ' ')"
fi

# ── Non-vacuity assertions ────────────────────────────────────────────────
# `archgate adr list --json` prints plain text ("No ADRs found.") instead of
# JSON when the corpus is empty. Piping that straight into jq made the
# expectation list degrade to an empty one, and the comparison below then
# passed with nothing evaluated — the very vacuous pass this script exists to
# prevent. Capture the raw payload first and treat a non-JSON payload as an
# error instead of as an empty list.
adr_json="$("$ARCHGATE_BIN" adr list --json 2>&1)" || adr_json=""
if [ -z "$adr_json" ] || ! printf '%s' "$adr_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
  fail_gate "archgate adr list did not return a JSON array — the ADR corpus is empty or unreadable, so no rule can be verified"
  echo "archgate adr list output: $adr_json"
  adr_json='[]'
fi

expected="$(printf '%s' "$adr_json" | jq -c '[.[] | select(.rules == true) | .id]')"

# A corpus in which no ADR declares `rules: true` would evaluate nothing too.
if [ "$(printf '%s' "$expected" | jq -r 'length')" -eq 0 ]; then
  fail_gate "no ADR declares rules: true — the ADR gate would evaluate nothing"
fi

evaluated="$(jq -c '[.results[]?.adrId] | unique' "$REPORT")"
missing="$(jq -rn --argjson expected "$expected" --argjson evaluated "$evaluated" '$expected - $evaluated | join(", ")')"
if [ -n "$missing" ]; then
  fail_gate "archgate evaluated no rules for ADR(s): $missing — the gate would report success without checking them"
fi

# Independent proof that rules actually ran, taken from the report alone: it
# does not depend on `adr list` at all.
if ! jq -e '.total > 0' "$REPORT" >/dev/null 2>&1; then
  fail_gate "archgate reported no evaluated rules (total=0) — the gate would pass without checking anything"
fi

if [ "$status" -ne 0 ]; then
  echo "archgate gate failed"
  exit "$status"
fi

echo "archgate gate passed"
