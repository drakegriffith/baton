#!/usr/bin/env bash
# Gherkin: "Reset time missing from the transcript line falls back to the
# default dead duration". QA-DOC section 5 row 2.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "02-reset-fallback"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-nofallback")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

start_time=$(date +%s)
start_night
f=$(wait_for_transcript a 5)
scenario_check "transcript file appeared" $([ -n "$f" ]; echo $?)

printf '%s\n' 'you have hit your usage limit, try again soon' >> "$f"

wait_for_night_exit 10
scenario_check "night process exited" $?

# DEFAULT_DEAD is 5h == 18000s; allow 30s slack for test run time.
expect=$((start_time + 18000))
got=$(dead_epoch_of a)
diff=$((got - expect))
[ "$diff" -lt 0 ] && diff=$((-diff))
scenario_check "dead epoch equals start+5h within tolerance" $([ "$diff" -le 30 ]; echo $?)

cleanup_root
scenario_end
