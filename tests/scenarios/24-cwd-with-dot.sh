#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): the transcript slug rule replaces
# BOTH `/` and `.` with `-`, and every other scenario runs from the repo
# checkout, whose absolute path happens to contain no dot -- so a slug rule
# that only handled `/` passed the whole suite while making --night blind
# in any project directory with a dot in its name (`my.project`,
# `site.com`, a versioned dir). The watcher would find no transcript, give
# up after BATON_SESSION_WAIT_SECS, and never see the limit line. Kills
# mutant M25.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "24-cwd-with-dot-in-name"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-dotted")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

back="$PWD"
mkdir -p "$SCRATCH/my.project.v2"
cd "$SCRATCH/my.project.v2" || exit 1

start_night
f=$(wait_for_transcript a 5)
scenario_check "transcript file appeared under the dotted cwd" $([ -n "$f" ]; echo $?)
printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$f"

wait_for_night_exit 15
scenario_check "night process exited" $?
scenario_check "the watcher saw the limit line and killed the child" $([ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "a was marked dead" $(is_dead_marked a; echo $?)
scenario_check "handed off to b" $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)
scenario_check "b resumed a's session by id" $(grep -q -- "--resume sess-dotted" "$(fake_log)"; echo $?)

cd "$back" || exit 1
cleanup_root
scenario_end
