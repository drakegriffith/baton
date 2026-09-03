#!/usr/bin/env bash
# Gherkin: features/failover.feature D8 -- the soft trigger's DEFAULT shape.
#
# D8 used to be a conjunction of three facts. The compaction sighting never
# guarded the cut (it only ARMS a candidate; the quiet window is what gates
# the kill), and tying the handoff to it meant an account at 95% of its
# five-hour window that simply had not compacted recently rode the window to
# the limit. So the default is now two facts -- usage over the threshold AND
# a quiet transcript -- and BATON_SOFT_NEED_COMPACT=1 restores the old three.
#
# Three phases, one per falsifiable claim: the default fires with no marker
# anywhere, the knob at 1 refuses the same run, and a bad knob value dies
# before a child exists.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "49-soft-switch-needs-no-compaction-by-default"

# write_usage NAME PCT [AGE_SECS] -- the statusline's signal file, exactly
# where the contract puts it ($ACCOUNTS_ROOT/<name>/.rate-limits.json).
# Written by the TEST, never by baton: baton only ever reads it. Same shape
# scenario 46 writes; duplicated rather than shared because the two
# scenarios pin opposite settings of the same knob and a shared helper would
# invite one to be changed for the other.
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

ORDINARY_LINE='{"type":"assistant","message":{"content":"still working on the refactor, no checkpoint here"}}'

# --- 1. default: 85% + quiet, and NOT ONE compaction marker ---------------
fresh_root
export BATON_QUIET_SECS=1
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-nomarker")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(9)
STEP_STDOUT=("carried on from b with no checkpoint")
EOF
write_usage a 85
start_night
f=$(wait_for_transcript a 5)
scenario_check "1: a's transcript appeared" $([ -n "$f" ]; echo $?)
# Ordinary traffic only. The marker is asserted ABSENT rather than merely
# not written: a build that still needs the checkpoint could otherwise pass
# on a marker some fixture wrote for its own reasons.
[ -n "$f" ] && printf '%s\n' "$ORDINARY_LINE" >> "$f"
scenario_check "1: no compaction marker exists anywhere in a's transcript" \
  $(! grep -q 'isCompactSummary' "$f"; echo $?)

wait_for_night_exit 20
scenario_check "1: the night run finished" $?
log="$(fake_log)"
scenario_check "1: a's child was killed (sigterm recorded)" $([ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "1: a is marked dead" $(is_dead_marked a; echo $?)
scenario_check "1: a's dead mark reads reason soft" \
  $([ "$(dead_reason_of a)" = soft ]; echo $?)
# The session id is the basename of the transcript that GREW, since no
# checkpoint sighting ever named one.
scenario_check "1: b was launched with --resume and the grown transcript's id" \
  $(grep -q -- "--resume sess-soft-nomarker" "$log"; echo $?)
scenario_check "1: the run finished on b's exit code" $([ "${NIGHT_EXIT:-0}" -eq 9 ]; echo $?)

handoff_log_path="$BATON_ACCOUNTS_ROOT/.handoff.log"
log_subjects=$(grep -c . "$handoff_log_path" 2>/dev/null)
scenario_check "1: the handoff log was inspected and is non-empty (got $log_subjects)" \
  $([ "${log_subjects:-0}" -gt 0 ]; echo $?)
# The durable morning line, verbatim. It must NOT claim a checkpoint that
# never happened: the operator reading it hours later is deciding whether
# baton left a working account for a good reason.
expected_line="ATTEMPT: proactive handoff (soft) -- account 'a' at 85% of its 5h window (quiet 1s, no compaction checkpoint required); will resume session sess-soft-nomarker under 'b'"
scenario_check "1: the handoff log carries the exact no-checkpoint line" \
  $(grep -qF "$expected_line" "$handoff_log_path"; echo $?)
[ -f "$handoff_log_path" ] && grep -qF "$expected_line" "$handoff_log_path" || {
  echo "49: expected [$expected_line]" >&2
  echo "49: handoff log was:" >&2; cat "$handoff_log_path" 2>/dev/null >&2
}
scenario_check "1: no line claims a compaction checkpoint was seen" \
  $(! grep -q 'after a compaction checkpoint' "$handoff_log_path"; echo $?)
# Issue #2/#12: nothing new may put a runnable command on the shared tty.
err_subjects=$(stream_lines "$SCRATCH/night.err")
control=$(predicate_positive_control "$SCRATCH/control")
scenario_check "1: the runnable-command predicate is not blind (control 3, got $control)" \
  $([ "$control" -eq 3 ]; echo $?)
scenario_check "1: stderr was inspected (got $err_subjects lines)" \
  $([ "$err_subjects" -gt 0 ]; echo $?)
scenario_check "1: no runnable command reached stderr" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
cleanup_root

# --- 2. BATON_SOFT_NEED_COMPACT=1 restores the three-fact conjunction -----
# The old scenario-46 phase 4 case, moved to its knob: 99% and quiet is not
# enough when the operator has asked for the checkpoint.
fresh_root
export BATON_QUIET_SECS=1
export BATON_SOFT_NEED_COMPACT=1
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-soft-knobbed")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_usage a 99
start_night
f=$(wait_for_transcript a 5)
scenario_check "2: a's transcript appeared" $([ -n "$f" ]; echo $?)
[ -n "$f" ] && printf '%s\n' "$ORDINARY_LINE" >> "$f"
# Long enough for several quiet windows to elapse: a build that ignored the
# knob would have switched by now.
sleep 3
scenario_check "2: 99% and quiet did not mark a dead under the knob" \
  $(! is_dead_marked a; echo $?)
scenario_check "2: b was never launched under the knob" \
  $([ "$(invocation_count b)" -eq 0 ]; echo $?)
scenario_check "2: a's child was not killed under the knob" \
  $([ ! -s "$(signals_log_of a)" ]; echo $?)
stop_night
kill_fake_claude a
unset BATON_SOFT_NEED_COMPACT
cleanup_root

# --- 3. a bad knob value dies before any child is launched ----------------
# Same contract as the three numeric knobs of scenario 18: refused into
# baton's error contract, naming the knob, with no child ever forked.
fresh_root
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("should never run")
EOF
out=$(env BATON_SOFT_NEED_COMPACT=2 "$BATON_BIN" --night 2>&1); rc=$?
scenario_check "3: BATON_SOFT_NEED_COMPACT=2 exits nonzero (got $rc)" \
  $([ "$rc" -ne 0 ]; echo $?)
scenario_check "3: the failure names the knob on stderr" \
  $(printf '%s' "$out" | grep -q 'BATON_SOFT_NEED_COMPACT'; echo $?)
scenario_check "3: no raw shell error leaked" \
  $(! printf '%s' "$out" | grep -qE "integer expression|invalid time interval|line [0-9]+:"; echo $?)
scenario_check "3: no child was launched at all" \
  $([ "$(invocation_count a)" -eq 0 ]; echo $?)
cleanup_root

unset BATON_QUIET_SECS
scenario_end
