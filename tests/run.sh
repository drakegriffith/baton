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

# A scenario that dies mid-file (an unset variable under `set -u`, a fixture
# that aborts) never reaches scenario_end, so it writes NO result line -- and
# a missing line is invisible in a PASS/FAIL tally: the suite just reports
# one fewer test and still exits 0. Absence of a result is a failure to
# inspect, not a pass, so it is recorded as one.
for f in "$HERE"/scenarios/*.sh; do
  [ -e "$f" ] || continue
  echo "== scenario: $(basename "$f") =="
  before=$(grep -cE '^(PASS|FAIL|CNI) ' "$RESULTS_FILE" 2>/dev/null || true)
  bash "$f"
  after=$(grep -cE '^(PASS|FAIL|CNI) ' "$RESULTS_FILE" 2>/dev/null || true)
  if [ "$after" -eq "$before" ]; then
    echo "FAIL $(basename "$f" .sh) -- [scenario recorded no result: died before scenario_end]" >> "$RESULTS_FILE"
  fi
done

# grep -c always prints a count (even 0) but exits nonzero when the count is
# 0 -- don't chain `|| echo 0` after it, that would print a second "0" line.
#
# COULD-NOT-INSPECT is a third bucket, not a PASS and not a FAIL (baton#7).
# A scenario or unit check lands here only when it explicitly marked itself
# as depending on the real process table (tests/fixtures/lib.sh's
# scenario_check ... cni, or a unit test's own *_cni helper) AND this
# environment's `ps` genuinely could not answer (same positive control
# lib/runs.sh uses: `ps -p 1`). It is never a substitute for a real pass:
# exit code 2 below means "could not verify", not "verified clean", and it
# only wins over 0 when FAIL is zero -- any real failure still exits 1.
total=$(grep -cE '^(PASS|FAIL|CNI) ' "$RESULTS_FILE" 2>/dev/null)
passed=$(grep -c '^PASS ' "$RESULTS_FILE" 2>/dev/null)
failed=$(grep -c '^FAIL ' "$RESULTS_FILE" 2>/dev/null)
cni=$(grep -c '^CNI ' "$RESULTS_FILE" 2>/dev/null)

echo "----"
grep '^FAIL ' "$RESULTS_FILE" 2>/dev/null || true
grep '^CNI ' "$RESULTS_FILE" 2>/dev/null || true
echo "TESTS: $total  PASS: $passed  FAIL: $failed  COULD-NOT-INSPECT: $cni"

if [ "$failed" -ne 0 ]; then
  exit 1
elif [ "$cni" -ne 0 ]; then
  exit 2
else
  exit 0
fi
