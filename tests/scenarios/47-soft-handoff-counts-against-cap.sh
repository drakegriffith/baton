#!/usr/bin/env bash
# A soft handoff is a handoff: it counts against BATON_MAX_HANDOFFS and its
# cap stop obeys issue #6's contract (exit 75, resume pointer in the handoff
# log, nothing runnable on stderr).
#
# Why this is its own scenario: the soft trigger is the first handoff cause
# baton can raise while the account is still WORKING, so an implementation
# that routes it around the cap would rotate all night on a signal file that
# is 1% over a threshold, and the operator's cap would silently not exist.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "47-soft-handoff-counts-against-cap"
fresh_root
add_account c

COMPACT_LINE='{"type":"user","isCompactSummary":true,"message":{"content":"continued from a previous conversation"}}'

write_usage() {
  local name="$1" pct="$2" now
  now=$(date +%s)
  mkdir -p "$BATON_ACCOUNTS_ROOT/$name"
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"written_at":%s}\n' \
    "$pct" "$((now + 900))" "$now" > "$BATON_ACCOUNTS_ROOT/$name/.rate-limits.json"
}

export BATON_MAX_HANDOFFS=1
export BATON_QUIET_SECS=1

write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-cap-soft-a")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_TRANSCRIPT=("sess-cap-soft-b")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_usage a 90
write_usage b 90

start_night
a_transcript=$(wait_for_transcript a 5)
scenario_check "a's transcript appeared" $([ -n "$a_transcript" ]; echo $?)
[ -n "$a_transcript" ] && printf '%s\n' "$COMPACT_LINE" >> "$a_transcript"

b_transcript=$(wait_for_transcript b 15)
scenario_check "the first soft handoff reached b" $([ -n "$b_transcript" ]; echo $?)
[ -n "$b_transcript" ] && printf '%s\n' "$COMPACT_LINE" >> "$b_transcript"

wait_for_night_exit 25
scenario_check "the night run finished" $?
scenario_check "the cap stop uses baton's reserved exit 75" \
  $([ "${NIGHT_EXIT:-0}" -eq 75 ]; echo $?)
scenario_check "stderr names BATON_MAX_HANDOFFS" \
  $(grep -q "BATON_MAX_HANDOFFS" "$SCRATCH/night.err"; echo $?)
# The pair-check from scenario 08: c is still alive, so "exhausted" would be
# the wrong cause.
scenario_check "stderr does NOT claim accounts are exhausted" \
  $(! grep -q "no live account" "$SCRATCH/night.err"; echo $?)
scenario_check "the one permitted soft handoff did happen (b ran)" \
  $([ "$(invocation_count b)" -ge 1 ]; echo $?)
scenario_check "c was never launched past the cap" \
  $([ "$(invocation_count c)" -eq 0 ]; echo $?)
scenario_check "both soft-switched accounts carry a soft dead mark" \
  $([ "$(dead_reason_of a)" = soft ] && [ "$(dead_reason_of b)" = soft ]; echo $?)

handoff_log_path="$BATON_ACCOUNTS_ROOT/.handoff.log"
log_subjects=$(grep -c . "$handoff_log_path" 2>/dev/null)
err_subjects=$(stream_lines "$SCRATCH/night.err")
scenario_check "the handoff log was inspected (got $log_subjects lines)" \
  $([ "${log_subjects:-0}" -gt 0 ]; echo $?)
scenario_check "stderr was inspected (got $err_subjects lines)" \
  $([ "$err_subjects" -gt 0 ]; echo $?)
control=$(predicate_positive_control "$SCRATCH/control")
scenario_check "the runnable-command predicate is not blind (control 3, got $control)" \
  $([ "$control" -eq 3 ]; echo $?)
scenario_check "issue #6: the handoff log carries the exact resume pointer" \
  $(grep -qF "baton b --resume sess-cap-soft-b" "$handoff_log_path"; echo $?)
scenario_check "issue #2: no runnable command reached stderr" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
scenario_check "stderr points at the handoff log for the resume line" \
  $(grep -qF "the resume line is in the handoff log: $handoff_log_path" "$SCRATCH/night.err"; echo $?)

unset BATON_MAX_HANDOFFS BATON_QUIET_SECS
cleanup_root
scenario_end
