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

COMPACT_LINE='{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued from a previous conversation..."}}'
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

# --- 4. no transcript ever observed is not a turn boundary ----------------
# Codex B1 / Kimi F3. `last_growth` is initialised at launch, so with the
# compaction conjunct off, high fresh usage plus one quiet window used to
# fire on a child that had not written a single byte yet -- startup, a long
# first tool call, a subagent -- and the handoff then resumed with a bare
# `-c` and no session id. Absence of a transcript is absence of evidence.
fresh_root
export BATON_QUIET_SECS=1
write_behavior a <<'EOF'
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_usage a 85
start_night
# Several quiet windows. A build without the guard has fired by now.
sleep 3
tdir="$(config_dir_of a)/projects/$(cwd_slug)"
n_transcripts=$(ls "$tdir"/*.jsonl 2>/dev/null | grep -c .)
scenario_check "4: the fixture really wrote no transcript (got ${n_transcripts:-0})" \
  $([ "${n_transcripts:-0}" -eq 0 ]; echo $?)
scenario_check "4: a was not marked dead with no transcript ever seen" \
  $(! is_dead_marked a; echo $?)
scenario_check "4: b was never launched with no transcript ever seen" \
  $([ "$(invocation_count b)" -eq 0 ]; echo $?)
scenario_check "4: a's child was not killed with no transcript ever seen" \
  $([ ! -s "$(signals_log_of a)" ]; echo $?)
stop_night
kill_fake_claude a
cleanup_root

# --- 5. the session resumed is the transcript that GREW -------------------
# Codex B2 / Kimi F1. A checkpoint sighting used to win the session id
# permanently, even with the knob at 0: an older transcript carrying a
# compaction marker beat the transcript the session is actually writing to.
# A 2.1.259 session that rolls to a new transcript file mid-run (after
# /clear, for one) makes that the common path, not a corner case.
fresh_root
# 3s, not 1s: the two staged writes below have to land inside one quiet
# window, or the handoff fires before the second transcript exists.
export BATON_QUIET_SECS=3
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-old")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(5)
STEP_STDOUT=("resumed the current transcript")
EOF
write_usage a 85
start_night
old=$(wait_for_transcript a 5)
scenario_check "5: a's first transcript appeared" $([ -n "$old" ]; echo $?)
tdir="$(config_dir_of a)/projects/$(cwd_slug)"
current="$tdir/sess-current.jsonl"
# The OLD transcript is the one carrying the checkpoint...
[ -n "$old" ] && printf '%s\n' "$COMPACT_LINE" >> "$old"
sleep 1
# ...and the CURRENT one is the session that is running.
printf '%s\n' "$ORDINARY_LINE" >> "$current"
sleep 1
n_files=$(ls "$tdir"/*.jsonl 2>/dev/null | grep -c .)
scenario_check "5: both transcripts exist in a's project dir (got ${n_files:-0})" \
  $([ "${n_files:-0}" -eq 2 ]; echo $?)
wait_for_night_exit 25
scenario_check "5: the night run finished" $?
log="$(fake_log)"
scenario_check "5: b resumed the transcript that grew last" \
  $(grep -q -- "--resume sess-current" "$log"; echo $?)
scenario_check "5: b did NOT resume the older checkpoint transcript" \
  $(! grep -q -- "--resume sess-old" "$log"; echo $?)
handoff_log_path="$BATON_ACCOUNTS_ROOT/.handoff.log"
scenario_check "5: the handoff log names the current session" \
  $(grep -q "will resume session sess-current under 'b'" "$handoff_log_path"; echo $?)
cleanup_root

# --- 6. the quiet check is re-validated immediately before the kill -------
# Codex B3. Quiet detection and the TERM are check-then-act: a child can
# append after touched_since returns and before the kill, so the cut lands
# mid-write. The window is a few microseconds of in-process shell between
# two statements, and the fixture cannot reliably schedule an append inside
# it, so the guard is pinned DIRECTLY -- soft_still_quiet as a unit, plus an
# assertion that the trigger calls it -- rather than by a flaky race test.
# Said plainly: this phase proves the guard is correct and is called, not
# that the race is closed. Transcript silence still cannot tell idle from a
# long tool call; only a real turn-complete signal could.
fresh_root
probe_dir="$SCRATCH/guard"
mkdir -p "$probe_dir"
watch_lib="$(dirname "$BATON_BIN")/lib/watch.sh"
guard_probe() { # FILE SIZE MTIME -> the exit status soft_still_quiet gives
  ( . "$watch_lib" >/dev/null 2>&1
    soft_still_quiet "$1" "$2" "$3"; echo $? )
}
pf="$probe_dir/probe.jsonl"
printf 'aaaa\n' > "$pf"
psize=$(wc -c < "$pf" | tr -d ' ')
pmtime=$(stat -f %m "$pf")
scenario_check "6: an untouched transcript is still quiet" \
  $([ "$(guard_probe "$pf" "$psize" "$pmtime")" -eq 0 ]; echo $?)
printf 'bbbb\n' >> "$pf"
scenario_check "6: a transcript that grew is NOT still quiet" \
  $([ "$(guard_probe "$pf" "$psize" "$pmtime")" -ne 0 ]; echo $?)
# Same size, newer mtime: a rewrite is a write, and size alone would miss it.
pf2="$probe_dir/probe2.jsonl"
printf 'aaaa\n' > "$pf2"
p2size=$(wc -c < "$pf2" | tr -d ' ')
p2mtime=$(stat -f %m "$pf2")
sleep 1
printf 'cccc\n' > "$pf2"
scenario_check "6: a same-size rewrite is NOT still quiet" \
  $([ "$(guard_probe "$pf2" "$p2size" "$p2mtime")" -ne 0 ]; echo $?)
scenario_check "6: a vanished transcript is NOT still quiet" \
  $([ "$(guard_probe "$probe_dir/gone.jsonl" 5 1)" -ne 0 ]; echo $?)
scenario_check "6: an empty path is NOT still quiet" \
  $([ "$(guard_probe "" 5 1)" -ne 0 ]; echo $?)
# The call site. A guard nothing calls is a guard that inspected nothing.
scenario_check "6: the soft trigger actually calls the guard" \
  $(grep -q 'soft_still_quiet "\$soft_pick"' "$watch_lib"; echo $?)
cleanup_root

unset BATON_QUIET_SECS
scenario_end
