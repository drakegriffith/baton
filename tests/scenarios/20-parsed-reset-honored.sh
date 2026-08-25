#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): scenario 02 pins the FALLBACK (no
# reset clause -> dead 5h) and scenario 01 only asserts "dead until some
# future time", so nothing proved the parsed reset time is used at all --
# replacing parse_reset_epoch's result with a constant 0 kept the whole
# suite green while silently parking every limited account for the full 5
# hours instead of until its real reset. This pins the parsed value
# end-to-end, through the live-transcript path.
#
# The fixture message is built from the wall clock (one hour ahead, in UTC)
# so the assertion is deterministic whatever time the suite runs at: a reset
# time that is still ahead of "now" must land within the next couple of
# hours, never at the 5h fallback.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "20-parsed-reset-honored"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-reset")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

start_night
f=$(wait_for_transcript a 5)
scenario_check "transcript file appeared" $([ -n "$f" ]; echo $?)

start=$(date +%s)
printf 'You have hit your usage limit. resets %s (UTC)\n' "$(date -u -v+1H '+%-I:%M%p')" >> "$f"

wait_for_night_exit 15
scenario_check "night process exited" $?

got=$(dead_epoch_of a)
scenario_check "a marked dead" $(is_dead_marked a; echo $?)
scenario_check "dead-until is in the future" $([ "${got:-0}" -gt "$start" ]; echo $?)
scenario_check "dead-until honors the parsed reset (<= 2h), not the 5h fallback" \
  $([ "$(( got - start ))" -le 7200 ]; echo $?)
scenario_check "dead reason is limit" $([ "$(dead_reason_of a)" = limit ]; echo $?)

cleanup_root
scenario_end
