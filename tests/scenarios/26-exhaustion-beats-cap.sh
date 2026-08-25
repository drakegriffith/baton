#!/usr/bin/env bash
# Post-review test (no Gherkin row of its own; it pins the ORDER of two rows
# that already exist -- exhaustion and the handoff cap).
#
# When the last account of the night hits its limit and the cap happens to be
# exhausted at the same moment, the run has two candidate explanations and
# only one of them is true. Checking the cap first names the wrong one: the
# operator reads "handoff cap (1) reached; raise it with BATON_MAX_HANDOFFS"
# out of a log at 7am and raises a cap that would have changed nothing, when
# in fact every account was rate-limited and the real answer is to wait for a
# reset or add an account.
#
# The mirror of this test is scenario 08: same cap, one account still alive,
# and there the CAP message is the correct one. Between them, an
# implementation that answers with one fixed message fails one of the two,
# and so does either ordering of the two checks.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "26-exhaustion-beats-cap"
fresh_root

# Cap = accounts - 1: the cap is exactly used up by the final handoff, so
# both explanations are live at the moment the run ends.
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
if wait_for_night_exit 15; then
  scenario_check "night process exited" 0
else
  scenario_check "night process exited" 1
  NIGHT_EXIT=-1
  stop_night
fi
scenario_check "exit nonzero" $([ "$NIGHT_EXIT" -ne 0 ]; echo $?)
scenario_check "stderr reports no live account" $(grep -q "no live account" "$SCRATCH/night.err"; echo $?)
scenario_check "stderr does NOT blame the handoff cap" \
  $(! grep -q "handoff cap" "$SCRATCH/night.err"; echo $?)
# The run really did reach the terminal rotation (rather than dying early for
# some other reason): the one permitted handoff happened first.
scenario_check "the permitted handoff to b did happen" $([ "$(invocation_count b)" -ge 1 ]; echo $?)
scenario_check "a marked dead with future epoch" \
  $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
scenario_check "b marked dead with future epoch" \
  $(is_dead_marked b && [ "$(dead_epoch_of b)" -gt "$(date +%s)" ]; echo $?)

unset BATON_MAX_HANDOFFS
cleanup_root
scenario_end
