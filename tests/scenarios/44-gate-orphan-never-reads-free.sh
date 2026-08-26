#!/usr/bin/env bash
# baton#12 gap 3: a gate directory without an owner record (a crash between
# winning the gate and writing the owner) must never be reported as free.
# The reporters (--lock-status, --locks) and the acquirer (--claim) must agree
# that the subject is could-not-inspect, exit 2, with the lock-result marker.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "44-gate-orphan-never-reads-free"
fresh_root
export BATON_LOCK_PROV=test

SID="orphan-sess-001"
LOCKS="$(baton_lock_dir)"
SUBJECT_DIR="$LOCKS/session_${SID}.lock"

# Plant the orphan: a gate directory with token `none` and no owner file.
mkdir -p "$SUBJECT_DIR"
mkdir -p "$SUBJECT_DIR/g-none"

MARKER='lock-result=could-not-inspect'

# --- --lock-status ---------------------------------------------------------
status="$("$BATON_BIN" --lock-status "session:$SID" 2>&1)"; strc=$?
scenario_check "--lock-status on a gate orphan exits 2" \
  $([ "$strc" -eq 2 ]; echo $?)
scenario_check "--lock-status reports state=could-not-inspect" \
  $(printf '%s' "$status" | grep -q 'state=could-not-inspect'; echo $?)
scenario_check "--lock-status reports it inspected the subject" \
  $(printf '%s' "$status" | grep -qE 'inspected=[1-9][0-9]*'; echo $?)
scenario_check "--lock-status carries the could-not-inspect marker" \
  $(printf '%s' "$status" | grep -q "$MARKER"; echo $?)
scenario_check "--lock-status never says free" \
  $(! printf '%s' "$status" | grep -q 'state=free'; echo $?)

# --- --locks ---------------------------------------------------------------
locks_out="$("$BATON_BIN" --locks 2>&1)"; lkrc=$?
scenario_check "--locks on a gate orphan exits 2" \
  $([ "$lkrc" -eq 2 ]; echo $?)
scenario_check "--locks lists the orphan as could-not-inspect" \
  $(printf '%s' "$locks_out" | grep -q 'could-not-inspect'; echo $?)
scenario_check "--locks counts the orphan as inspected" \
  $(printf '%s' "$locks_out" | grep -qE 'inspected [1-9][0-9]* lock subject'; echo $?)
scenario_check "--locks carries the could-not-inspect marker" \
  $(printf '%s' "$locks_out" | grep -q "$MARKER"; echo $?)
scenario_check "--locks never says free" \
  $(! printf '%s' "$locks_out" | grep -q 'state=free'; echo $?)

# --- --claim ---------------------------------------------------------------
claim_err="$("$BATON_BIN" --claim "session:$SID" -- sh -c "echo RAN > '$SCRATCH/ran'" 2>&1)"; clrc=$?
scenario_check "--claim on a gate orphan exits 2" \
  $([ "$clrc" -eq 2 ]; echo $?)
scenario_check "--claim ran no guarded command" \
  $([ ! -e "$SCRATCH/ran" ]; echo $?)
scenario_check "--claim carries the could-not-inspect marker" \
  $(printf '%s' "$claim_err" | grep -q "$MARKER"; echo $?)

# --- all three entry points agree it is not free ----------------------------
scenario_check "all three reporters/acquirer agree on exit 2" \
  $([ "$strc" -eq 2 ] && [ "$lkrc" -eq 2 ] && [ "$clrc" -eq 2 ]; echo $?)
scenario_check "none of the three says state=free" \
  $(! printf '%s%s%s' "$status" "$locks_out" "$claim_err" | grep -q 'state=free'; echo $?)

cleanup_root
scenario_end
