#!/usr/bin/env bash
# baton#2 added acceptance (the orphan-kill rule): "A reconcile that redoes an
# orphan-running unit kills the matched orphan and confirms it gone before
# launching the replacement; the scenario asserts no window in which both are
# alive."
#
# `--pickup` classifies a surviving orphan as `orphan-running` with action
# `monitor`, and scenario 28 proves it is never re-dispatched automatically.
# But an operator (or a reconciler) can still DECIDE to redo the unit, and
# that decision is the moment the duplicate this whole issue is about gets
# launched with everyone's blessing. `--redispatch` is the only sanctioned
# path for that decision, and it kills first and CONFIRMS by re-probing.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "32-redispatch-kills-and-confirms-orphan"
fresh_root
export BATON_LOCK_PROV=test

# --- manufacture a real orphan (scenario 28's shape) -----------------------
write_behavior a <<'EOF'
STEP_BLOCK=(1)
STEP_TRANSCRIPT=("sess-redispatch")
STEP_STDOUT=("working on it")
EOF

start_night
transcript="$(wait_for_transcript a 10)"
scenario_check "the child launched (transcript exists)" $([ -n "$transcript" ]; echo $?)
stop_night   # kill the PARENT: the child is reparented and keeps running

RUNS="$BATON_ACCOUNTS_ROOT/.runs"
start_receipt="$(ls -1 "$RUNS"/*.start 2>/dev/null | head -1)"
scenario_check "a start receipt survived the parent" $([ -n "$start_receipt" ]; echo $?)
UNIT="$(basename "${start_receipt:-none}" .start)"
ORPHAN_PID="$(sed -n 's/^pid=//p' "${start_receipt:-/dev/null}" 2>/dev/null | head -1)"
scenario_check "the receipt names a numeric orphan pid" \
  $(printf '%s' "$ORPHAN_PID" | grep -qE '^[0-9]+$'; echo $?)

# The precondition is ASSERTED, not assumed: if the orphan were already dead
# every "no overlap" check below would pass for the wrong reason.
#
# It is polled rather than sampled once. The parent was just SIGKILLed and the
# child is mid-reparenting; a single sample taken inside that window is a
# measurement of the harness, not of the board. The poll is bounded, and the
# assertion below still fails (with the last board printed) if the state never
# arrives -- a settle window is not a retry-until-green.
board=""
waited=0
while [ "$waited" -lt 50 ]; do
  board="$("$BATON_BIN" --pickup 2>/dev/null)"
  printf '%s' "$board" | grep -q '"status": "orphan-running"' && break
  sleep 0.1
  waited=$((waited + 1))
done
scenario_check "precondition: the board reads orphan-running" \
  $(printf '%s' "$board" | grep -q '"status": "orphan-running"'; echo $?)
printf '%s' "$board" | grep -q '"status": "orphan-running"' || {
  echo "32: board never reached orphan-running; last board was:" >&2
  printf '%s\n' "$board" >&2
  echo "32: receipt was:" >&2; cat "$start_receipt" >&2
  echo "32: ps said: [$(ps -p "${ORPHAN_PID:-0}" -o lstart=,args= 2>/dev/null | tr -s '[:space:]' ' ')]" >&2
}
scenario_check "precondition: the orphan really is alive right now" \
  $([ -n "$(ps -p "${ORPHAN_PID:-0}" -o args= 2>/dev/null)" ]; echo $?)

# --- a redispatch that loses the claim kills NOTHING -----------------------
# Claim ordering matters: kill-then-claim would let a loser destroy the
# winner's orphan and then be refused, which is worse than doing nothing.
"$BATON_BIN" --claim "unit:$UNIT" -- sleep 20 >/dev/null 2>"$SCRATCH/holder.err" &
HOLDER=$!
waited=0
while [ ! -e "$BATON_ACCOUNTS_ROOT/.locks/unit_$UNIT.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done

refused="$("$BATON_BIN" --redispatch "$UNIT" -- sh -c "echo replacement >> '$SCRATCH/replacement.log'" 2>&1)"; refrc=$?
scenario_check "a redispatch on a claimed unit exits nonzero" $([ "$refrc" -ne 0 ]; echo $?)
scenario_check "the refused redispatch names the holding pid" \
  $(printf '%s' "$refused" | grep -q "$HOLDER"; echo $?)
scenario_check "the refused redispatch launched no replacement" \
  $([ ! -e "$SCRATCH/replacement.log" ]; echo $?)
# The one that would be silent and catastrophic: a loser that killed anyway.
scenario_check "the refused redispatch killed nothing -- the orphan is still alive" \
  $([ -n "$(ps -p "${ORPHAN_PID:-0}" -o args= 2>/dev/null)" ]; echo $?)

kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
sleep 0.3

# --- the real redispatch ---------------------------------------------------
# The replacement's FIRST instruction records what the process table says
# about the orphan. If there were any window in which both were alive, this
# capture is the instant it would show, because it runs before the
# replacement does anything else.
"$BATON_BIN" --redispatch "$UNIT" -- \
  sh -c "ps -p $ORPHAN_PID -o args= > '$SCRATCH/overlap' 2>/dev/null; echo replacement >> '$SCRATCH/replacement.log'" \
  >"$SCRATCH/redispatch.out" 2>"$SCRATCH/redispatch.err"
redrc=$?

scenario_check "the redispatch exited 0" $([ "$redrc" -eq 0 ]; echo $?)
scenario_check "the replacement ran exactly once" \
  $([ "$(grep -c replacement "$SCRATCH/replacement.log" 2>/dev/null || echo 0)" -eq 1 ]; echo $?)
# THE assertion this scenario exists for.
scenario_check "no window in which both were alive: the orphan was gone before the replacement's first instruction" \
  $([ ! -s "$SCRATCH/overlap" ]; echo $?)
scenario_check "the orphan is confirmed gone afterwards too" \
  $([ -z "$(ps -p "${ORPHAN_PID:-0}" -o args= 2>/dev/null)" ]; echo $?)

# The board moves off orphan-running once the orphan really is dead, which is
# the independent confirmation that the kill was real rather than reported.
board2="$("$BATON_BIN" --pickup 2>/dev/null)"
scenario_check "the board no longer reads orphan-running" \
  $(! printf '%s' "$board2" | grep -q '"status": "orphan-running"'; echo $?)

# A redispatch of a unit with no receipt at all has no orphan to kill and
# says so by running the replacement rather than by claiming a kill it never
# performed.
"$BATON_BIN" --redispatch "no-such-unit-ever" -- sh -c "echo fresh >> '$SCRATCH/fresh.log'" >/dev/null 2>&1
scenario_check "a unit with no receipt redispatches cleanly" \
  $([ -e "$SCRATCH/fresh.log" ]; echo $?)

cleanup_root
scenario_end
