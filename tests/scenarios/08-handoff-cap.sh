#!/usr/bin/env bash
# Gherkin: "Handoff cap is reached before every account is exhausted".
# QA-DOC section 5 row 8.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "08-handoff-cap"
fresh_root
add_account c

export BATON_MAX_HANDOFFS=1

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
scenario_check "stderr names the cap 1" $(grep -q "1" "$SCRATCH/night.err"; echo $?)
scenario_check "stderr names BATON_MAX_HANDOFFS" $(grep -q "BATON_MAX_HANDOFFS" "$SCRATCH/night.err"; echo $?)
scenario_check "c never probed or launched" $([ "$(invocation_count c)" -eq 0 ]; echo $?)

unset BATON_MAX_HANDOFFS
cleanup_root
scenario_end
