#!/usr/bin/env bash
# Gherkin: "Headless child exits after an auth failure and the run rotates
# to the next account". QA-DOC section 5 row 4. D4: AUTH treated same as
# LIMIT for rotation, but always dead exactly 1h with reason "auth".
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "04-headless-auth-rotate"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("Not logged in. Please run /login" "Not logged in. Please run /login")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

start_time=$(date +%s)
start_night
wait_for_night_exit 10
scenario_check "night process exited" $?

scenario_check "a marked dead" $(is_dead_marked a; echo $?)
scenario_check "a dead reason is auth" $([ "$(dead_reason_of a)" = auth ]; echo $?)
expect=$((start_time + 3600))
got=$(dead_epoch_of a)
diff=$((got - expect)); [ "$diff" -lt 0 ] && diff=$((-diff))
scenario_check "a dead for ~1 hour" $([ "$diff" -le 30 ]; echo $?)
scenario_check "baton relaunched under b" $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)

cleanup_root
scenario_end
