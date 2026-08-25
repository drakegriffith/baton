#!/usr/bin/env bash
# tests/run.sh -- focused suite entry point (bash tests/run.sh). Runs the
# lib/detect.sh unit tests plus every Gherkin-scenario-mapped test under
# tests/scenarios/, each against its own fresh temp HOME + BATON_ACCOUNTS_ROOT
# (see tests/fixtures/lib.sh), and reports a pass/fail tally.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BATON_BIN="$HERE/../baton"
export FIXTURES_DIR="$HERE/fixtures"
RESULTS_FILE="$(mktemp)"
export RESULTS_FILE
trap 'rm -f "$RESULTS_FILE"' EXIT

chmod +x "$FIXTURES_DIR/bin/claude" 2>/dev/null || true

for f in "$HERE"/unit/*.sh; do
  [ -e "$f" ] || continue
  echo "== unit: $(basename "$f") =="
  bash "$f"
done

for f in "$HERE"/scenarios/*.sh; do
  [ -e "$f" ] || continue
  echo "== scenario: $(basename "$f") =="
  bash "$f"
done

# grep -c always prints a count (even 0) but exits nonzero when the count is
# 0 -- don't chain `|| echo 0` after it, that would print a second "0" line.
total=$(grep -cE '^(PASS|FAIL) ' "$RESULTS_FILE" 2>/dev/null)
passed=$(grep -c '^PASS ' "$RESULTS_FILE" 2>/dev/null)
failed=$(grep -c '^FAIL ' "$RESULTS_FILE" 2>/dev/null)

echo "----"
grep '^FAIL ' "$RESULTS_FILE" 2>/dev/null || true
echo "TESTS: $total  PASS: $passed  FAIL: $failed"

[ "$failed" -eq 0 ]
