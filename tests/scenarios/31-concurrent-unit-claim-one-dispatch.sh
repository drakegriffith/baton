#!/usr/bin/env bash
# baton#2 added acceptance (root cause 4, split-brain re-dispatch): "Two
# concurrent --pickup-then-dispatch attempts on the same unit produce exactly
# one dispatch; the loser exits nonzero and names the holding pid."
#
# The board `--pickup` prints is a pure function of the receipts on disk and
# carries no ownership, which is correct for a projection and is exactly why
# the projection cannot be the thing that arbitrates. Two restarted
# orchestrators read the identical board and reach the identical conclusion.
# This scenario is the arbitration they are missing.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "31-concurrent-unit-claim-one-dispatch"
fresh_root
export BATON_LOCK_PROV=test

UNIT="night-20260825T193000Z-4242-a"
DISPATCH_LOG="$SCRATCH/dispatches.log"
: > "$DISPATCH_LOG"

# Both orchestrators run the identical command: claim the unit, then do the
# work. The work is slow enough that a loser cannot win by arriving after the
# winner has already finished and released -- which would be a different
# (and legitimate) outcome, not the race this asserts on.
"$BATON_BIN" --claim "unit:$UNIT" -- sh -c "echo dispatched >> '$DISPATCH_LOG'; sleep 2" \
  >"$SCRATCH/one.out" 2>"$SCRATCH/one.err" &
P1=$!
"$BATON_BIN" --claim "unit:$UNIT" -- sh -c "echo dispatched >> '$DISPATCH_LOG'; sleep 2" \
  >"$SCRATCH/two.out" 2>"$SCRATCH/two.err" &
P2=$!

wait "$P1"; RC1=$?
wait "$P2"; RC2=$?

dispatches=$(grep -c 'dispatched' "$DISPATCH_LOG" 2>/dev/null || true)
winners=0; losers=0
[ "$RC1" -eq 0 ] && winners=$((winners + 1)) || losers=$((losers + 1))
[ "$RC2" -eq 0 ] && winners=$((winners + 1)) || losers=$((losers + 1))

# The whole point, stated as a count rather than as an absence: exactly one.
scenario_check "exactly one dispatch happened" $([ "$dispatches" -eq 1 ]; echo $?)
scenario_check "exactly one claimer exited 0" $([ "$winners" -eq 1 ]; echo $?)
scenario_check "exactly one claimer exited nonzero" $([ "$losers" -eq 1 ]; echo $?)
# A dispatch count of zero would satisfy "not two" while proving nothing, so
# it is refused explicitly rather than left to the equality above.
scenario_check "the claim layer did not simply block both (>0 dispatches)" \
  $([ "$dispatches" -gt 0 ]; echo $?)

if [ "$RC1" -ne 0 ]; then loser_err="$SCRATCH/one.err"; winner_pid="$P2"; else loser_err="$SCRATCH/two.err"; winner_pid="$P1"; fi
scenario_check "the loser named the holding pid on stderr" \
  $(grep -q "$winner_pid" "$loser_err"; echo $?)
scenario_check "the loser's message says the subject is locked" \
  $(grep -qi "locked" "$loser_err"; echo $?)

# Presence, not absence: the run really did inspect a claim subject. A gate
# that inspected zero subjects failed, however green it looks.
status="$("$BATON_BIN" --lock-status "unit:$UNIT" 2>&1)"; strc=$?
scenario_check "--lock-status inspected more than zero claim subjects" \
  $(printf '%s' "$status" | grep -qE 'inspected=[1-9][0-9]*'; echo $?)
scenario_check "after both finished the unit is free again, exit 0" \
  $([ "$strc" -eq 0 ]; echo $?)
scenario_check "the released claim reads free, not held" \
  $(printf '%s' "$status" | grep -q 'state=free'; echo $?)

# A released subject must still be claimable, or one night of work would
# permanently retire a unit name.
"$BATON_BIN" --claim "unit:$UNIT" -- sh -c "echo dispatched >> '$DISPATCH_LOG'" >/dev/null 2>&1
scenario_check "a released unit can be claimed again" \
  $([ "$(grep -c 'dispatched' "$DISPATCH_LOG")" -eq 2 ]; echo $?)

# --claim needs the work it guards, because a claim held by a process that
# has already exited is stale on arrival and would arbitrate nothing.
"$BATON_BIN" --claim "unit:$UNIT" >/dev/null 2>&1
scenario_check "--claim with no command to guard is refused" $([ $? -ne 0 ]; echo $?)

cleanup_root
scenario_end
