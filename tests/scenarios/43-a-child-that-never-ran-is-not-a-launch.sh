#!/usr/bin/env bash
# Delta-review finding (major): LAUNCHED was written straight after the
# async fork, so it recorded that bash SUCCEEDED IN FORKING, not that a
# session started.
#
# `cmd &` returns a pid whatever happens next. If the exec fails -- the
# binary is missing, or is not executable -- the child exits 126/127
# immediately and nothing ever ran, but the fork already handed back a pid
# and the log already said LAUNCHED. That is the same defect the previous
# round fixed one layer up: a durable record asserting work that did not
# happen. Moving the line from "before the lock" to "after the fork" moved
# the window; it did not close it.
#
# The second half of the same finding: runs_record_start's exit status was
# discarded. The receipt IS the durable evidence -- it is what lib/runs.sh
# reads at restart to tell a live orphan from a unit that never started -- so
# a LAUNCHED line written when the receipt failed to land claims evidence
# that does not exist.
#
# Absence-is-not-evidence: "no LAUNCHED line" is asserted only alongside the
# ATTEMPT line that must still be there (a refusal is not silent) and the
# failure line that must name the exit code. Three positive facts, not one
# absence.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "43-a-child-that-never-ran-is-not-a-launch"
fresh_root

HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"

# 127 is the shell's "command not found". The fake claude reproduces the
# OBSERVABLE (a child that is gone before the first watch tick, with the exit
# code that means it never executed) rather than deleting the binary, which
# would also break the probe that follows and confuse the two failures.
write_behavior a <<'EOF'
STEP_EXIT=(127 127)
STEP_STDOUT=("" "")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(127 127)
STEP_STDOUT=("" "")
EOF

start_night
wait_for_night_exit 15
scenario_check "the night run terminated rather than hanging" $?

count_log() { local n; n=$(grep -cE -- "$1" "$HANDOFF_LOG_PATH" 2>/dev/null); printf '%s' "${n:-0}"; }

scenario_check "the handoff log exists" $([ -f "$HANDOFF_LOG_PATH" ]; echo $?)
log_lines=$(stream_lines "$HANDOFF_LOG_PATH")
if [ "$log_lines" -eq 0 ]; then
  echo "43-a-child-that-never-ran-is-not-a-launch: COULD NOT INSPECT -- the handoff log holds 0 lines" >&2
  cleanup_root
  exit 2
fi
scenario_check "inspected more than zero handoff-log lines (got $log_lines)" \
  $([ "$log_lines" -gt 0 ]; echo $?)

# Positive control: the attempt was recorded. A build that logged nothing at
# all would otherwise pass the claim below.
scenario_check "the attempt was recorded as an attempt (got $(count_log "ATTEMPT:.*'a'"))" \
  $([ "$(count_log "ATTEMPT:.*'a'")" -ge 1 ]; echo $?)

# The claim.
scenario_check "a child that exited 127 left NO launch record (got $(count_log 'LAUNCHED:'))" \
  $([ "$(count_log 'LAUNCHED:')" -eq 0 ]; echo $?)

# And the failure is not silent: the operator learns the launch failed and
# with which code.
scenario_check "the failure is recorded, naming the exit code (got $(count_log 'LAUNCH FAILED.*127'))" \
  $([ "$(count_log 'LAUNCH FAILED.*127')" -ge 1 ]; echo $?)
scenario_check "the failure line names the account" \
  $([ "$(count_log "LAUNCH FAILED.*'a'")" -ge 1 ]; echo $?)

# The streams stay clean through the new path too.
scenario_check "stderr hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
scenario_check "positive control: that predicate can see a leak" \
  $([ "$(predicate_positive_control "$SCRATCH/predicate-control.txt")" -eq 3 ]; echo $?)

kill_fake_claude a
kill_fake_claude b
cleanup_root
scenario_end
