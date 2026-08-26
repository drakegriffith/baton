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

# The OTHER half of the handoff line's resume hint. This rotation is driven
# by the post-exit probe, not by a transcript line, so there is no session id
# and the hint must be a bare `-c`. It is asserted here because this is the
# only scenario that reaches that branch; its partner, the `--resume <id>`
# branch, is asserted in scenario 41, where the id doubling was found --
# ${VAR:+--resume $VAR}${VAR:--c} emits a SET value twice, because `:-`
# falls back to the word only when the variable is unset or empty.
HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"
handoff_hint=$(grep -c -- 'will resume under .* with -c$' "$HANDOFF_LOG_PATH" 2>/dev/null)
scenario_check "the sessionless handoff logs a bare -c hint (got ${handoff_hint:-0})" \
  $([ "${handoff_hint:-0}" -ge 1 ]; echo $?)

cleanup_root
scenario_end
