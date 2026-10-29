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
  echo "::error::ADR frontmatter failed to parse, so the ADR was dropped from the corpus: $(echo "$unparsed" | tr '\n' ' ')"
  status=1
fi

expected="$("$ARCHGATE_BIN" adr list --json | jq -c '[.[] | select(.rules == true) | .id]')"
evaluated="$(jq -c '[.results[]?.adrId] | unique' "$REPORT")"
missing="$(jq -rn --argjson expected "$expected" --argjson evaluated "$evaluated" '$expected - $evaluated | join(", ")')"
if [ -n "$missing" ]; then
  echo "::error::archgate evaluated no rules for ADR(s): $missing — the gate would report success without checking them"
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo "archgate gate failed"
  exit "$status"
fi

echo "archgate gate passed"
