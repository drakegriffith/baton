#!/usr/bin/env bash
# Gherkin: "Unattended interactive session hits its limit and the run
# continues on the next account" (features/failover.feature, headline
# scenario). QA-DOC section 5 row 1.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "01-interactive-limit-headline"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-headline")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(9)
STEP_STDOUT=("done from b")
EOF

start_night --some-project-args
f=$(wait_for_transcript a 5)
scenario_check "transcript file appeared" $([ -n "$f" ]; echo $?)

printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$f"

wait_for_night_exit 10
scenario_check "night process exited" $?

log="$(fake_log)"
scenario_check "a launched exactly once" $([ "$(grep -c "config=$(config_dir_of a) " "$log")" -eq 1 ]; echo $?)
scenario_check "a received sigterm" $([ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "a marked dead with future epoch" $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
scenario_check "handoff announced naming a and b" $(printf '%s' "$(night_stderr)" | grep -q "'a'" && printf '%s' "$(night_stderr)" | grep -q "'b'"; echo $?)
scenario_check "b launched with --resume and a's session id" $(grep -q -- "--resume sess-headline" "$log"; echo $?)
scenario_check "final exit code matches b's exit code" $([ "$NIGHT_EXIT" -eq 9 ]; echo $?)

cleanup_root
scenario_end
