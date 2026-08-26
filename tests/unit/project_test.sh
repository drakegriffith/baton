#!/usr/bin/env bash
# Unit tests for runs_project -- the compact JSON board a restarted
# orchestrator reads INSTEAD of the raw pile. Its whole reason to exist is
# that the reader's cost must not grow with how long the dead session ran, so
# what is asserted here is: every unit appears exactly once, the counts sum to
# the total, and the exit code distinguishes "clean" from "needs a human"
# from "could not inspect".
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/pickup.sh"
. "$HERE/../../lib/runs.sh"
. "$HERE/../fixtures/lib.sh"

SCRATCH_P="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_P"' EXIT
export BATON_RUNS_PROV=test

check() { # $1 name, $2 got, $3 expected
  if [ "$2" = "$3" ]; then record_pass "unit:runs_project:$1"
  else record_fail "unit:runs_project:$1" "expected [$3] got [$2]"; fi
}

# check_cni -- like check, but for a classification that can only land in
# dead-partial/orphan-running when the process table can actually be asked
# (u-dead and u-orphan below are probed via runs_alive -> ps). When it
# mismatches AND this environment's ps is confirmed unusable (ps_usable,
# tests/fixtures/lib.sh), pickup_classify correctly falls back to `unknown`
# for a refused process table -- that is not a runs_project defect, so it is
# recorded as could-not-inspect rather than FAIL. In a working environment
# this behaves exactly like check. See baton#7.
check_cni() { # $1 name, $2 got, $3 expected
  if [ "$2" = "$3" ]; then record_pass "unit:runs_project:$1"
  elif ! ps_usable; then record_cni "unit:runs_project:$1" "expected [$3] got [$2] (ps unusable in this environment)"
  else record_fail "unit:runs_project:$1" "expected [$3] got [$2]"; fi
}

field_of() { # $1 json, $2 key -> first scalar value for that key
  printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1
}
num_of() { # like field_of but an absent field is 0, so a missing count is a
           # wrong sum rather than a shell syntax error that hides the row
  local v; v="$(field_of "$1" "$2")"
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}
status_of() { # $1 json, $2 unit -> that unit's status (one unit per line)
  printf '%s\n' "$1" | grep "\"unit\":[[:space:]]*\"$2\"" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# ---- an empty board is could-not-inspect, NOT a pass ----------------------
# A sweep that inspected zero subjects found nothing because it looked at
# nothing. Reporting that as a clean board is how a live orphan gets
# re-dispatched: the caller sees success and proceeds.
export BATON_RUNS_DIR="$SCRATCH_P/empty"
out="$(runs_project 2>/dev/null)"; rc=$?
check "empty-board-exit-2" "$rc" "2"
check "empty-board-verdict" "$(field_of "$out" verdict)" "could-not-inspect"
check "empty-board-counts-zero" "$(field_of "$out" inspected)" "0"

# A runs directory that does not exist at all is the same verdict, never a
# crash and never silence.
export BATON_RUNS_DIR="$SCRATCH_P/nonexistent-dir"
out="$(runs_project 2>/dev/null)"; rc=$?
check "missing-dir-exit-2" "$rc" "2"
check "missing-dir-verdict" "$(field_of "$out" verdict)" "could-not-inspect"

# ---- a board with real units --------------------------------------------
export BATON_RUNS_DIR="$SCRATCH_P/board"
SELF_FP="$(runs_fingerprint $$)"

# u-done: started and finished. Its exit code is on disk.
runs_record_start u-done 424242 "some old process" "claude --night -p one"
runs_record_complete u-done 0

# u-dead: started, never finished, pid long gone. 424243 is not running under
# that fingerprint, so the probe confirms death rather than assuming it.
runs_record_start u-dead 424243 "a process that is not there" "claude --night -p two"

# u-orphan: started, no completion, and genuinely alive -- this test's own
# shell, which is the one process whose liveness is certain.
runs_record_start u-orphan $$ "$SELF_FP" "claude --night -p three"

out="$(runs_project 2>/dev/null)"; rc=$?

check "three-units-inspected" "$(field_of "$out" inspected)" "3"
check "done-classified"   "$(status_of "$out" u-done)"   "done"
check_cni "dead-classified"   "$(status_of "$out" u-dead)"   "dead-partial"
check_cni "orphan-classified" "$(status_of "$out" u-orphan)" "orphan-running"

# The totality check reconcile.py pays for with assert_sums: a unit that
# falls out of every bucket would otherwise vanish silently from the board.
sum=$(( $(num_of "$out" done) + $(num_of "$out" dead-partial) + $(num_of "$out" orphan-running) + $(num_of "$out" never-started) + $(num_of "$out" unknown) ))
check "counts-sum-to-inspected" "$sum" "3"

# An orphan on the board means work may still be running, so the board is not
# clean and the caller must not blindly re-dispatch: exit 1, needs a decision.
check "orphan-present-exit-1" "$rc" "1"

# Provenance travels with the projection, so a self-test board can never be
# read as a real one.
check "prov-stamped" "$(field_of "$out" prov)" "test"

# ---- a board that needs nothing ------------------------------------------
export BATON_RUNS_DIR="$SCRATCH_P/clean"
runs_record_start u-a 424244 "gone" "claude -p a"
runs_record_complete u-a 0
runs_record_start u-b 424245 "gone too" "claude -p b"
runs_record_complete u-b 3
out="$(runs_project 2>/dev/null)"; rc=$?
check "all-done-exit-0" "$rc" "0"
check "all-done-verdict" "$(field_of "$out" verdict)" "resolved"
check "nonzero-child-exit-still-done" "$(status_of "$out" u-b)" "done"

# ---- a board carrying contradictory evidence -----------------------------
# A completion receipt with no start receipt. The classifier calls this
# unknown; the projection must surface it as needing a human rather than
# quietly counting it done.
export BATON_RUNS_DIR="$SCRATCH_P/torn"
runs_record_complete u-torn 0
out="$(runs_project 2>/dev/null)"; rc=$?
check "torn-classified" "$(status_of "$out" u-torn)" "unknown"
check "torn-exit-1" "$rc" "1"
check "torn-verdict" "$(field_of "$out" verdict)" "needs-reconcile"
