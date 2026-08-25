#!/usr/bin/env bash
# Gherkin: "Child exits cleanly and baton exits with the same code, no
# rotation". QA-DOC section 5 row 5.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "05-clean-exit-no-rotation"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("all good")
EOF

start_night
wait_for_night_exit 10
scenario_check "night process exited" $?
scenario_check "exit code 0" $([ "$NIGHT_EXIT" -eq 0 ]; echo $?)
scenario_check "a not marked dead" $(! is_dead_marked a; echo $?)
scenario_check "no second claude process ever launched" $([ "$(grep -c "config=$(config_dir_of b) " "$(fake_log)" 2>/dev/null)" -eq 0 ]; echo $?)

cleanup_root
scenario_end
