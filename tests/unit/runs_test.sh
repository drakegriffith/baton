#!/usr/bin/env bash
# Unit tests for lib/runs.sh -- receipts on disk and the liveness probe.
#
# This module is allowed to touch the OS (it asks `ps` about a pid) but not
# another baton module, so it is still safe to source directly. The probe is
# the ONLY place a bucket's `alive` token comes from, which is why its
# pid-reuse guard is tested here rather than inferred from the classifier.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/runs.sh"
. "$HERE/../fixtures/lib.sh"

check_alive() { # $1 name, $2 pid, $3 fingerprint, $4 expected
  local got
  got="$(runs_alive "$2" "$3")"
  if [ "$got" = "$4" ]; then
    record_pass "unit:runs_alive:$1"
  else
    record_fail "unit:runs_alive:$1" "expected $4 got $got for pid=$2 fp=[$3]"
  fi
}

# This very shell is the one process whose liveness we know for certain, so
# it is the positive control: if this row ever fails, the probe never reached
# the process table and every `no` it reports is worthless.
SELF_FP="$(runs_fingerprint $$)"
check_alive "self-matching-fingerprint" "$$" "$SELF_FP" yes

# THE PID-REUSE GUARD (acceptance 4). Same live pid, a fingerprint belonging
# to some other command: the recorded process is NOT what is running under
# that number now, so it must not read as alive. A bare `kill -0` cannot tell
# these apart, which is exactly why the fingerprint is recorded at launch.
check_alive "live-pid-wrong-fingerprint" "$$" "sleep 99999 started-in-1999" no

# THE EXEC CASE (baton#2). Same live pid, same START TIME, a different command
# line: this is the recorded process after an `exec`, not a stranger. It is the
# normal path, not a corner case -- run_watched launches `env -u
# CLAUDE_CONFIG_DIR claude ...` and records the fingerprint the instant the pid
# exists, racing the child's own exec, so the receipt sometimes holds the
# pre-exec argv. Reading that as a death reported a LIVE orphan as gone, and
# `dead-partial` maps to action `reconcile`.
check_alive "same-birth-after-exec" "$$" "$(runs_birth "$SELF_FP") some other command line" yes

# ...and the guard that makes the row above safe: a different start time is
# still a different process, however similar the command line looks.
check_alive "different-birth-same-command" "$$" "Mon Jan  1 00:00:00 1999 ${SELF_FP#* * * * * }" no

# runs_birth itself: a fingerprint too short to carry a start time yields
# nothing, so a truncated or planted record stays unmatchable rather than
# matching everything.
if [ -z "$(runs_birth 'three word thing')" ]; then
  record_pass "unit:runs_birth:too-short-yields-nothing"
else
  record_fail "unit:runs_birth:too-short-yields-nothing" "got [$(runs_birth 'three word thing')]"
fi
if [ -z "$(runs_birth '')" ]; then
  record_pass "unit:runs_birth:empty-yields-nothing"
else
  record_fail "unit:runs_birth:empty-yields-nothing" "got [$(runs_birth '')]"
fi
# A glob in the command-line half must not be expanded into a directory
# listing while the fingerprint is being split into fields.
if [ "$(runs_birth 'Tue Aug 25 17:16:01 2026 sh -c *')" = "Tue Aug 25 17:16:01 2026" ]; then
  record_pass "unit:runs_birth:glob-in-command-is-not-expanded"
else
  record_fail "unit:runs_birth:glob-in-command-is-not-expanded" "got [$(runs_birth 'Tue Aug 25 17:16:01 2026 sh -c *')]"
fi

# A pid that has exited. Reaped and gone is a CONFIRMED death, the only
# evidence that lets a unit be re-dispatched safely.
DEAD_PID="$( (exec sh -c 'echo $$') )"
sleep 0.1
check_alive "exited-process" "$DEAD_PID" "whatever it was" no

# ---- could-not-inspect rows: exit 2 is not a pass ------------------------
# A probe that cannot ask the question must say so. If `ps` is unavailable,
# every pid would otherwise report "no" and a board full of live orphans
# would read as a board full of safely-re-dispatchable dead units -- the
# exact failure this whole mechanism exists to prevent.
got_noprobe="$(PATH=/nonexistent runs_alive "$$" "$SELF_FP")"
if [ "$got_noprobe" = unknown ]; then
  record_pass "unit:runs_alive:no-ps-available-is-unknown"
else
  record_fail "unit:runs_alive:no-ps-available-is-unknown" "expected unknown got $got_noprobe"
fi

# Malformed pids are never silently treated as absent processes.
check_alive "empty-pid"       ""      "$SELF_FP" unknown
check_alive "nonnumeric-pid"  "abc"   "$SELF_FP" unknown
check_alive "negative-pid"    "-1"    "$SELF_FP" unknown
check_alive "zero-pid"        "0"     "$SELF_FP" unknown
# An empty recorded fingerprint means the receipt was truncated mid-write;
# there is nothing to match against, so liveness is undetermined, not false.
check_alive "empty-fingerprint" "$$"   ""        unknown

# ---- receipts on disk ----------------------------------------------------
SCRATCH_RUNS="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_RUNS"' EXIT
export BATON_RUNS_DIR="$SCRATCH_RUNS"

# A start receipt is written BEFORE the child is known to have done anything,
# and it is what makes "never-started" distinguishable from "died instantly".
runs_record_start u1 $$ "$SELF_FP" "claude --night"
if [ -f "$SCRATCH_RUNS/u1.start" ]; then
  record_pass "unit:runs_record_start:writes-receipt"
else
  record_fail "unit:runs_record_start:writes-receipt" "no receipt at $SCRATCH_RUNS/u1.start"
fi

# Fields survive the round trip. A receipt whose pid or fingerprint cannot be
# read back is a receipt that cannot defeat pid reuse.
got_pid="$(runs_field "$SCRATCH_RUNS/u1.start" pid)"
check_field() { # $1 name, $2 got, $3 expected
  if [ "$2" = "$3" ]; then record_pass "unit:runs_field:$1"
  else record_fail "unit:runs_field:$1" "expected [$3] got [$2]"; fi
}
check_field "pid-round-trip" "$got_pid" "$$"
check_field "fingerprint-round-trip" "$(runs_field "$SCRATCH_RUNS/u1.start" fingerprint)" "$SELF_FP"
check_field "unit-round-trip" "$(runs_field "$SCRATCH_RUNS/u1.start" unit)" "u1"

# Every receipt is stamped live-or-test, so a self-test row can never be read
# as a real one (the provenance rule the lifecycle-reconciler already pays
# for: 9 unstamped rows once made a self-test write indistinguishable from a
# real failure).
check_field "prov-defaults-live" "$(runs_field "$SCRATCH_RUNS/u1.start" prov)" "live"
BATON_RUNS_PROV=test runs_record_start u2 $$ "$SELF_FP" "claude --night"
check_field "prov-honors-override" "$(runs_field "$SCRATCH_RUNS/u2.start" prov)" "test"

# A completion receipt carries the exit code, and it is the ONLY thing that
# closes a unit.
runs_record_complete u1 7
check_field "exit-code-recorded" "$(runs_field "$SCRATCH_RUNS/u1.complete" exit)" "7"

# A field that is not in the receipt reads back empty rather than as some
# neighbouring field's value.
check_field "absent-field-is-empty" "$(runs_field "$SCRATCH_RUNS/u1.start" nosuchfield)" ""
# A receipt file that does not exist reads back empty and does not error out
# under set -u.
check_field "absent-file-is-empty" "$(runs_field "$SCRATCH_RUNS/nope.start" pid)" ""
