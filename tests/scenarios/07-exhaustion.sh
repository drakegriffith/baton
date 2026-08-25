#!/usr/bin/env bash
# Gherkin: "All accounts are limited and baton dies with the no-live-account
# message". QA-DOC section 5 row 7.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "07-exhaustion"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF

start_night
wait_for_night_exit 10
scenario_check "night process exited" $?
scenario_check "exit nonzero" $([ "$NIGHT_EXIT" -ne 0 ]; echo $?)
scenario_check "existing no-live-account message on stderr" $(grep -q "no live account\. baton --status to see dead marks; baton --revive <name> to override" "$SCRATCH/night.err"; echo $?)
scenario_check "a marked dead with future epoch" $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
scenario_check "b marked dead with future epoch" $(is_dead_marked b && [ "$(dead_epoch_of b)" -gt "$(date +%s)" ]; echo $?)

cleanup_root
scenario_end
