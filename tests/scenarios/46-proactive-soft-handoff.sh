#!/usr/bin/env bash
# Gherkin: features/failover.feature D8 -- the proactive ("soft") handoff.
#
# The subject is a CONJUNCTION, so the scenario is four runs, not one: a
# compaction checkpoint alone must not switch, a high usage fraction alone
# must not switch, an unreadable/stale signal must not switch (fail closed),
# and only all three together may. A build that switches on the compaction
# sighting alone passes a one-run version of this test and burns an account
# every time a long session compacts.
#
# The three-fact conjunction is no longer the default: it is what
# BATON_SOFT_NEED_COMPACT=1 asks for, so this whole scenario runs under that
# knob and stays the pin on the legacy shape. The default two-fact trigger
# has its own scenario (49).
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "46-proactive-soft-handoff"
export BATON_SOFT_NEED_COMPACT=1

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

# --- 5. the quiet window is a CONDITION, not a comment --------------------
# Everything phase 2 needs is true here -- a compaction checkpoint and 85% of
# the window -- except that the session kept working. A build whose third
# condition is prose rather than a guard kills a session in the middle of the
# turn that follows the checkpoint, which is exactly the mid-turn orphan
# hazard of issues #2 and #12, and phases 1-4 all still pass for it.
fresh_root
# 3s, not the 1s the phases above use. The quiet window is measured in whole
# seconds, so a 1s window is really "somewhere between 0 and 1 second" once
# the two samples land either side of a second boundary -- a 0.3s write
# cadence can slip through it, and the test would fail on a build that is
# correct. 3s leaves a full second of margin on a cadence that never goes
# quiet at all.
export BATON_QUIET_SECS=3
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-busy")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(3)
STEP_STDOUT=("resumed after the busy stretch")
EOF
write_usage a 85
start_night
f=$(wait_for_transcript a 5)
scenario_check "5: a's transcript appeared" $([ -n "$f" ]; echo $?)
[ -n "$f" ] && printf '%s
' "$COMPACT_LINE" >> "$f"

# Fifteen writes, 0.3s apart: four and a half seconds of work, and never
# more than 0.3s of silence against a 3s window. The poll interval is 0.2s,
# so a build without the guard gets twenty-odd chances to fire and needs one.
busy_kill=0
i=0
while [ "$i" -lt 15 ]; do
  printf '%s
' '{"type":"assistant","message":{"content":"still mid-turn after the checkpoint"}}' >> "$f"
  sleep 0.3
  is_dead_marked a && busy_kill=1
  i=$((i + 1))
done
scenario_check "5: no handoff while the transcript kept growing (checked 15 times)"   $([ "$busy_kill" -eq 0 ]; echo $?)
scenario_check "5: b was not launched mid-turn" $([ "$(invocation_count b)" -eq 0 ]; echo $?)
scenario_check "5: a's child was not killed mid-turn"   $([ ! -s "$(signals_log_of a)" ]; echo $?)

# Now the session goes quiet, and the SAME three facts finally hold. Asserted
# so the phase above cannot pass by the trigger being broken outright.
wait_for_night_exit 20
scenario_check "5: the handoff did fire once the writing stopped" $?
scenario_check "5: a is marked dead with reason soft after the quiet window"   $([ "$(dead_reason_of a)" = soft ]; echo $?)
scenario_check "5: b resumed a's session once it was quiet"   $(grep -q -- "--resume sess-soft-busy" "$(fake_log)"; echo $?)
cleanup_root

unset BATON_QUIET_SECS
unset BATON_SOFT_NEED_COMPACT
scenario_end
