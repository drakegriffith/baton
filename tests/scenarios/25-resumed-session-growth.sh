#!/usr/bin/env bash
# Post-review test (no Gherkin row of its own; amends D6): the SECOND limit
# of the night.
#
# Every account symlinks projects/ back into ~/.claude, so a relaunched
# `claude --resume <id>` re-opens the transcript file that ALREADY EXISTS on
# disk. A watcher that only looks for a file which "starts existing after
# launch" therefore sees nothing for the rest of the night: the first handoff
# works, the second never happens, and an unattended run stops on the second
# account. This scenario reproduces that shape directly -- the transcript
# file is on disk BEFORE baton launches, and gains its LIMIT line mid-run.
#
# Two mutants are pinned:
#   * "watch for a new file"       -> nothing ever grows into existence here,
#                                     so no handoff happens and the run hangs.
#   * "classify the whole file"    -> the pre-launch content is itself a LIMIT
#                                     line (the one that caused the previous
#                                     handoff), so the child would be killed
#                                     before the test ever appends anything.
#                                     The mid-run quiet window below is what
#                                     makes that visible instead of merely
#                                     lucky.
# A third: the file that does NOT grow sorts alphabetically first, so a
# watcher that reports "the first transcript in the dir" resumes the wrong
# session id.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "25-resumed-session-growth"
fresh_root

tdir="$(config_dir_of a)/projects/$(cwd_slug)"
mkdir -p "$tdir"
printf '%s\n' 'You have hit your usage limit. resets 9:00pm (UTC)' > "$tdir/aaa-stale.jsonl"
printf '%s\n' 'You have hit your usage limit. resets 10:00pm (UTC)' > "$tdir/sess-carried.jsonl"

# No STEP_TRANSCRIPT: this child writes no new transcript file, exactly like
# a real `--resume` of the session already on disk.
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(9)
STEP_STDOUT=("done from b")
EOF

start_night --some-project-args

# Several poll intervals of quiet (BATON_WATCH_INTERVAL is 0.2 here): the
# pre-launch LIMIT lines are not this session's, and must not act.
sleep 1.5
scenario_check "child still running after several polls of pre-launch content" \
  $(kill -0 "$NIGHT_PID" 2>/dev/null; echo $?)
scenario_check "no SIGTERM from pre-launch content" $([ ! -s "$(signals_log_of a)" ]; echo $?)
scenario_check "a not marked dead by pre-launch content" $(! is_dead_marked a; echo $?)
scenario_check "b not launched by pre-launch content" \
  $([ "$(invocation_count b)" -eq 0 ]; echo $?)

printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$tdir/sess-carried.jsonl"

# A regression here HANGS (the watcher simply never sees the limit line), and
# a hang must be recorded as a failure, not left to trip over an unset
# NIGHT_EXIT under `set -u` and take the whole scenario's result line with it.
if wait_for_night_exit 10; then
  scenario_check "night process exited" 0
else
  scenario_check "night process exited" 1
  NIGHT_EXIT=-1
  stop_night
fi
scenario_check "the appended limit line killed the child" $([ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "a marked dead with future epoch" \
  $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
scenario_check "handoff announced naming a and b" \
  $(printf '%s' "$(night_stderr)" | grep -q "'a'" && printf '%s' "$(night_stderr)" | grep -q "'b'"; echo $?)
# b's handoff resumes a's session, which goes through run_watched's
# --resume session lock (lib/watch.sh lock_claim "session:$id") and needs a
# working process table (_runs_ps_usable). Refused ps -> refused resume.
scenario_check "b resumed the file that GREW, not the one that sat still" \
  $(grep -q -- "--resume sess-carried" "$(fake_log)"; echo $?) cni
scenario_check "b did not resume the stale transcript" \
  $(! grep -q -- "--resume aaa-stale" "$(fake_log)"; echo $?)
scenario_check "final exit code matches b's exit code" $([ "$NIGHT_EXIT" -eq 9 ]; echo $?) cni

cleanup_root
scenario_end
