#!/usr/bin/env bash
# Gherkin: "Headless child exits after hitting its limit and the run rotates
# to the next account". QA-DOC section 5 row 3.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "03-headless-limit-rotate"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(3 3)
STEP_STDOUT=("you hit your usage limit" "you hit your usage limit, resets 6am")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

start_night
wait_for_night_exit 10
scenario_check "night process exited" $?

scenario_check "a marked dead with future epoch" $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
scenario_check "handoff announced naming a and b" $(printf '%s' "$(night_stderr)" | grep -q "'a'" && printf '%s' "$(night_stderr)" | grep -q "'b'"; echo $?)
scenario_check "baton relaunched under b" $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)
scenario_check "exactly 2 invocations for a (launch + post-exit probe)" $([ "$(invocation_count a)" -eq 2 ]; echo $?)
scenario_check "run did not exit with child's own exit code (3)" $([ "$NIGHT_EXIT" -ne 3 ]; echo $?)

cleanup_root
scenario_end
