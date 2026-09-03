#!/usr/bin/env bash
# Gherkin: features/failover.feature D8 -- the proactive ("soft") handoff.
#
# The subject is a CONJUNCTION, so the scenario is four runs, not one: a
# compaction checkpoint alone must not switch, a high usage fraction alone
# must not switch, an unreadable/stale signal must not switch (fail closed),
# and only all three together may. A build that switches on the compaction
# sighting alone passes a one-run version of this test and burns an account
# every time a long session compacts.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "46-proactive-soft-handoff"

COMPACT_LINE='{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued from a previous conversation..."}}'

# write_usage NAME PCT [AGE_SECS] -- the statusline's signal file, exactly
# where the contract puts it ($ACCOUNTS_ROOT/<name>/.rate-limits.json).
# Written by the TEST, never by baton: baton only ever reads it.
write_usage() {
  local name="$1" pct="$2" age="${3:-0}" now
  now=$(date +%s)
  mkdir -p "$BATON_ACCOUNTS_ROOT/$name"
  cat > "$BATON_ACCOUNTS_ROOT/$name/.rate-limits.json" <<EOF
{"five_hour":{"used_percentage":$pct,"resets_at":$((now + 900))},
 "seven_day":{"used_percentage":12,"resets_at":$((now + 90000))},
 "written_at":$((now - age))}
EOF
}

# --- 1. negative control: compaction seen, but only 40% of the window ------
fresh_root
export BATON_QUIET_SECS=1
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-neg")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_usage a 40
start_night
f=$(wait_for_transcript a 5)
scenario_check "1: a's transcript appeared" $([ -n "$f" ]; echo $?)
[ -n "$f" ] && printf '%s\n' "$COMPACT_LINE" >> "$f"
# Long enough for several quiet windows to elapse: a build that switches
# would have switched by now.
sleep 3
scenario_check "1: a was NOT marked dead at 40% of its window" \
  $(! is_dead_marked a; echo $?)
scenario_check "1: b was never launched at 40%" $([ "$(invocation_count b)" -eq 0 ]; echo $?)
scenario_check "1: a's child is still running (no kill at 40%)" \
  $([ ! -s "$(signals_log_of a)" ]; echo $?)
stop_night
kill_fake_claude a
cleanup_root

# --- 2. positive: compaction + 85% + a quiet window -> soft handoff --------
fresh_root
export BATON_QUIET_SECS=1
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-a")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(7)
STEP_STDOUT=("carried on from b")
EOF
write_usage a 85
start_night
f=$(wait_for_transcript a 5)
scenario_check "2: a's transcript appeared" $([ -n "$f" ]; echo $?)
[ -n "$f" ] && printf '%s\n' "$COMPACT_LINE" >> "$f"

wait_for_night_exit 20
scenario_check "2: the night run finished" $?
log="$(fake_log)"
scenario_check "2: a's child was killed (sigterm recorded)" $([ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "2: a is marked dead" $(is_dead_marked a; echo $?)
scenario_check "2: a's dead mark reads reason soft, not limit" \
  $([ "$(dead_reason_of a)" = soft ]; echo $?)
scenario_check "2: a's dead-until is in the future" \
  $([ "$(dead_epoch_of a 2>/dev/null || echo 0)" -gt "$(date +%s)" ]; echo $?)
scenario_check "2: b was launched with --resume and a's session id" \
  $(grep -q -- "--resume sess-soft-a" "$log"; echo $?)
scenario_check "2: the run finished on b's exit code" $([ "${NIGHT_EXIT:-0}" -eq 7 ]; echo $?)

handoff_log_path="$BATON_ACCOUNTS_ROOT/.handoff.log"
log_subjects=$(grep -c . "$handoff_log_path" 2>/dev/null)
scenario_check "2: the handoff log was inspected and is non-empty (got $log_subjects)" \
  $([ "${log_subjects:-0}" -gt 0 ]; echo $?)
# The durable morning line, asserted verbatim. This is the only record an
# operator reads hours later, and it has to say WHY the account was left
# while it still worked -- a generic "unavailable" line would be a lie.
expected_line="ATTEMPT: proactive handoff (soft) -- account 'a' at 85% of its 5h window after a compaction checkpoint (quiet 1s); will resume session sess-soft-a under 'b'"
scenario_check "2: the handoff log carries the exact soft-handoff line" \
  $(grep -qF "$expected_line" "$handoff_log_path"; echo $?)
[ -f "$handoff_log_path" ] && grep -qF "$expected_line" "$handoff_log_path" || {
  echo "46: expected [$expected_line]" >&2
  echo "46: handoff log was:" >&2; cat "$handoff_log_path" 2>/dev/null >&2
}
# Issue #2/#12: nothing new may put a runnable command on the shared tty.
err_subjects=$(stream_lines "$SCRATCH/night.err")
control=$(predicate_positive_control "$SCRATCH/control")
scenario_check "2: the runnable-command predicate is not blind (control 3, got $control)" \
  $([ "$control" -eq 3 ]; echo $?)
scenario_check "2: stderr was inspected (got $err_subjects lines)" \
  $([ "$err_subjects" -gt 0 ]; echo $?)
scenario_check "2: no runnable command reached stderr" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
cleanup_root

# --- 3. fail closed: the signal file is stale, so usage is unknown ---------
fresh_root
export BATON_QUIET_SECS=1
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-stale")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
# 95% -- but written 4000 seconds ago, well past BATON_USAGE_MAX_AGE's 600s
# default. An old number about a five-hour window is not a small error, it is
# a different window.
write_usage a 95 4000
start_night
f=$(wait_for_transcript a 5)
scenario_check "3: a's transcript appeared" $([ -n "$f" ]; echo $?)
[ -n "$f" ] && printf '%s\n' "$COMPACT_LINE" >> "$f"
sleep 3
scenario_check "3: a stayed alive on a stale signal (unknown never arms)" \
  $(! is_dead_marked a; echo $?)
scenario_check "3: b was never launched on a stale signal" \
  $([ "$(invocation_count b)" -eq 0 ]; echo $?)
stop_night
kill_fake_claude a
cleanup_root

# --- 4. high usage with no compaction checkpoint does not switch ----------
fresh_root
export BATON_QUIET_SECS=1
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-nocompact")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_usage a 99
start_night
f=$(wait_for_transcript a 5)
scenario_check "4: a's transcript appeared" $([ -n "$f" ]; echo $?)
# Ordinary traffic, no compaction marker anywhere in it.
[ -n "$f" ] && printf '%s\n' '{"type":"assistant","message":{"content":"still working on the refactor"}}' >> "$f"
sleep 3
scenario_check "4: 99% alone did not mark a dead" $(! is_dead_marked a; echo $?)
scenario_check "4: 99% alone did not launch b" $([ "$(invocation_count b)" -eq 0 ]; echo $?)
stop_night
kill_fake_claude a
cleanup_root

unset BATON_QUIET_SECS
scenario_end
