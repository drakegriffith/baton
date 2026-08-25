#!/usr/bin/env bash
# Gherkin: "Child exits with a nonzero non-limit code and baton propagates
# it, no rotation". QA-DOC section 5 row 6.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "06-nonzero-exit-no-rotation"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(7)
STEP_STDOUT=("something ordinary went wrong")
EOF

start_night
wait_for_night_exit 10
scenario_check "night process exited" $?
scenario_check "exit code 7 propagated" $([ "$NIGHT_EXIT" -eq 7 ]; echo $?)
scenario_check "a not marked dead" $(! is_dead_marked a; echo $?)
scenario_check "no second claude process ever launched" $([ "$(grep -c "config=$(config_dir_of b) " "$(fake_log)" 2>/dev/null)" -eq 0 ]; echo $?)

cleanup_root
scenario_end
