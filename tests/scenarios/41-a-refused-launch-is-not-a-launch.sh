#!/usr/bin/env bash
# Review finding (major): the handoff log recorded a launch that never
# happened.
#
# night_mode wrote "launching as account 'x'" and, on rotation, "resuming
# under 'x' with --resume <id>" BEFORE calling run_watched -- and run_watched
# is where the single-writer guard lives. When the session lock is held by
# another live process, run_watched dies without ever reaching the CLI, and
# the log is left asserting that baton resumed a session it was refused.
#
# Why that is worse than a cosmetic wrong line: the handoff log is the ONLY
# durable record of the night (issue #2's whole fix moved instructions into
# it), it is read hours later by someone who cannot see the terminal, and
# the receipts in lib/runs.sh are the thing that decides at restart whether
# work needs re-dispatching. A log that says "resumed session S under b"
# when b never started points the operator at a session to go look for and,
# worse, makes a refusal -- the guard WORKING -- indistinguishable from a
# launch that started and vanished.
#
# The fix is a tense, not a new mechanism: night_mode logs ATTEMPT (what it
# is about to try), and the LAUNCHED line is appended by run_watched only
# after the lock is held AND the launch receipt exists.
#
# Absence-is-not-evidence discipline: "no LAUNCHED line for b" is only
# meaningful if LAUNCHED lines are written at all. The successful launch of
# account a in the same run is the positive control for that.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "41-a-refused-launch-is-not-a-launch"
fresh_root
export BATON_LOCK_PROV=test

SID="sess-refused"
HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"

# A live foreign process already holds the session the handoff is about to
# resume. Planted through the real CLI, so nothing here knows the lock
# format.
"$BATON_BIN" --claim "session:$SID" -- sleep 30 >/dev/null 2>&1 &
HOLDER=$!
waited=0
while [ ! -e "$BATON_ACCOUNTS_ROOT/.locks/session_$SID.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done
scenario_check "positive control: the contested session lock is held before --night starts" \
  $([ -e "$BATON_ACCOUNTS_ROOT/.locks/session_$SID.lock/owner" ]; echo $?)

# a launches, writes the contested transcript, then hits its limit and
# rotates. b is where the refusal happens.
write_behavior a <<EOF
STEP_EXIT=(0)
STEP_TRANSCRIPT=("$SID")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(9)
STEP_STDOUT=("done from b")
EOF

start_night
f=$(wait_for_transcript a 10)
scenario_check "positive control: account a's transcript appeared" $([ -n "$f" ]; echo $?)
printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$f"

wait_for_night_exit 15
scenario_check "the --night run terminated rather than hanging" $?
scenario_check "the run exited nonzero rather than resuming as a second writer" \
  $([ "${NIGHT_EXIT:-0}" -ne 0 ]; echo $?)

# The load-bearing consequence, re-derived here rather than assumed from the
# exit code: b never reached the CLI.
scenario_check "account b was never launched with --resume on the locked session" \
  $(! grep -q -- "--resume $SID" "$(fake_log)"; echo $?)

# --- the log ---------------------------------------------------------------
scenario_check "the handoff log exists" $([ -f "$HANDOFF_LOG_PATH" ]; echo $?)

log_lines=$(stream_lines "$HANDOFF_LOG_PATH")
if [ "$log_lines" -eq 0 ]; then
  echo "41-a-refused-launch-is-not-a-launch: COULD NOT INSPECT -- the handoff log holds 0 lines" >&2
  kill -KILL "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  kill_fake_claude a; kill_fake_claude b
  cleanup_root
  exit 2
fi
scenario_check "inspected more than zero handoff-log lines (got $log_lines)" \
  $([ "$log_lines" -gt 0 ]; echo $?)

count_log() { local n; n=$(grep -cE "$1" "$HANDOFF_LOG_PATH" 2>/dev/null); printf '%s' "${n:-0}"; }

# Positive control: LAUNCHED lines are written at all. Without this, "no
# LAUNCHED line for b" would pass on a build that stopped writing them.
launched_a=$(count_log "LAUNCHED:.*'a'")
scenario_check "positive control: the launch that DID happen left a LAUNCHED line for 'a' (got $launched_a)" \
  $([ "$launched_a" -ge 1 ]; echo $?)

# The attempt is recorded as an attempt: a refusal must not be silent either.
attempt_b=$(count_log "ATTEMPT:.*'b'")
scenario_check "the refused handoff left an ATTEMPT line naming 'b' (got $attempt_b)" \
  $([ "$attempt_b" -ge 1 ]; echo $?)

# The claim.
launched_b=$(count_log "LAUNCHED:.*'b'")
scenario_check "the refused handoff left NO launch record for 'b' (got $launched_b)" \
  $([ "$launched_b" -eq 0 ]; echo $?)
scenario_check "no line claims the contested session was resumed" \
  $([ "$(count_log "LAUNCHED:.*$SID")" -eq 0 ]; echo $?)

# The log is still not a place commands get printed FROM -- it is allowed to
# carry them, the streams are not. Re-asserted here because this commit adds
# new lines to both.
scenario_check "stderr of the refused run hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
scenario_check "positive control: that predicate can see a leak" \
  $([ "$(predicate_positive_control "$SCRATCH/predicate-control.txt")" -eq 3 ]; echo $?)

kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
kill_fake_claude a
kill_fake_claude b
cleanup_root
scenario_end
