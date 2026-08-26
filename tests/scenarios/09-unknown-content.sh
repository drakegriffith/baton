#!/usr/bin/env bash
# Gherkin: "Unrecognized transcript content is classified UNKNOWN and never
# treated as a limit". QA-DOC section 5 row 9.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "09-unknown-content-safe"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-unknown")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
STEP_BLOCK_TICKS=(20)
EOF

start_night
f=$(wait_for_transcript a 5)
scenario_check "transcript file appeared" $([ -n "$f" ]; echo $?)

printf '%s\n' 'Here is the code you asked for...' >> "$f"
printf '%s\n' 'Sure, let me explain how this works.' >> "$f"
printf '%s\n' 'That rate limiter class handles retries.' >> "$f"

# Give the watcher several poll intervals (0.2s each per fresh_root) to
# (not) react.
sleep 1.5

scenario_check "child not killed" $(! [ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "a not marked dead" $(! is_dead_marked a; echo $?)
# "handoff:" with the colon, not bare "handoff": since issue #2 the AUTH
# branch names the handoff LOG path on stderr, so a bare "handoff" also
# matches a run that merely mentioned where instructions went. This fixture
# never reaches AUTH, so the loose grep passes today -- but it would then be
# asserting something other than what it says. The announcement this line is
# actually about is "baton: handoff: account ... switching to ...".
scenario_check "no handoff/crash text on stderr yet" $(! grep -qi "handoff:\|no live account" "$SCRATCH/night.err"; echo $?)
scenario_check "night still running" $(kill -0 "$NIGHT_PID" 2>/dev/null; echo $?)

# STEP_BLOCK_TICKS=20 (2s) makes the fake claude for "a" exit(0) on its own,
# with no external signal -- a real clean exit, never an interrupted one.
# The run must follow it out with that same code.
wait_for_night_exit 10
scenario_check "night process eventually exited" $?
scenario_check "exit code matches child's own clean exit (0)" $([ "$NIGHT_EXIT" -eq 0 ]; echo $?)
scenario_check "child was never sent SIGTERM" $(! [ -s "$(signals_log_of a)" ]; echo $?)

cleanup_root
scenario_end
