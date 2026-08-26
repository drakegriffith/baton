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
scenario_check "existing no-live-account message on stderr" $(grep -q "no live account under " "$SCRATCH/night.err"; echo $?)
# This row used to pin the message's exact tail: "baton --status to see dead
# marks; baton --revive <name> to override". That is two runnable command
# lines on a stream the operator and the `claude` child share -- issue #2
# root cause 2, on the exact path an exhausted night ends on -- so the test
# was pinning the bug. The message now names the recovery as a noun and a
# knob; the commands themselves go to the handoff log. The Gherkin row's
# actual requirement (name BATON_ACCOUNTS_ROOT and --revive) is unchanged
# and still asserted, here and below.
scenario_check "the exhaustion message still names the --revive knob" \
  $(grep -q -- "--revive" "$SCRATCH/night.err"; echo $?)
scenario_check "positive control: the predicate about to be used can see a leak" \
  $([ "$(predicate_positive_control "$SCRATCH/predicate-control.txt")" -eq 3 ]; echo $?)
scenario_check "positive control: stderr held more than zero lines to inspect" \
  $([ "$(stream_lines "$SCRATCH/night.err")" -gt 0 ]; echo $?)
scenario_check "the exhaustion message hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
scenario_check "the exact recovery commands are in the handoff log instead" \
  $(grep -q "baton --revive <name>" "$BATON_ACCOUNTS_ROOT/.handoff.log" 2>/dev/null; echo $?)
# The Gherkin requires this message name BATON_ACCOUNTS_ROOT, and it means
# the ROOT ACTUALLY IN USE, not just the string "BATON_ACCOUNTS_ROOT":
# read out of an unattended log, "no live account" alone cannot be told
# apart from "baton was pointed at an empty directory and never saw your
# accounts". Both halves are asserted so neither can be dropped.
scenario_check "message names the resolved accounts root" $(grep -qF "$BATON_ACCOUNTS_ROOT" "$SCRATCH/night.err"; echo $?)
scenario_check "message names the BATON_ACCOUNTS_ROOT knob" $(grep -q "BATON_ACCOUNTS_ROOT" "$SCRATCH/night.err"; echo $?)
scenario_check "a marked dead with future epoch" $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
scenario_check "b marked dead with future epoch" $(is_dead_marked b && [ "$(dead_epoch_of b)" -gt "$(date +%s)" ]; echo $?)

cleanup_root
scenario_end
