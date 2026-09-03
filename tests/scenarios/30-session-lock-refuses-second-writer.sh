#!/usr/bin/env bash
# baton#2 acceptance 1: "A second resume of a locked session exits nonzero and
# names the holder PID. The check asserts it inspected > 0 lock subjects; an
# unreadable lock dir exits 2 (could-not-inspect), which is not a pass."
#
# Everything here is observed through the real `baton` subprocess and the
# files it leaves behind (QA-DOC section 1). Nothing sources a lib.
#
# Scenario numbering: 29 is taken by the open PR for root cause 2
# (fix/2-watcher-tty), so this branch starts at 30 rather than colliding.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "30-session-lock-refuses-second-writer"
fresh_root
# Every lock this scenario causes to be written is a self-test lock.
export BATON_LOCK_PROV=test

LOCKS="$(baton_lock_dir)"
SID="sess-2026-08-25-abc"

# --- the first writer ------------------------------------------------------
# A real baton process holding the session subject for as long as its guarded
# work runs. `--claim` requires a command for exactly this reason: a claim
# taken by a process that exits immediately is stale the instant it lands.
"$BATON_BIN" --claim "session:$SID" -- sleep 30 >"$SCRATCH/holder.out" 2>"$SCRATCH/holder.err" &
HOLDER=$!

waited=0
while [ ! -e "$LOCKS/session_$SID.lock/owner" ]; do
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -gt 100 ] && break
done
scenario_check "the first writer's owner record landed on disk" \
  $([ -e "$LOCKS/session_$SID.lock/owner" ]; echo $?)

# --- status: held, by a named pid, and it looked ---------------------------
status="$("$BATON_BIN" --lock-status "session:$SID" 2>&1)"; srsc=$?
scenario_check "--lock-status on a held subject exits 1" $([ "$srsc" -eq 1 ]; echo $?)
scenario_check "--lock-status reports state=held" \
  $(printf '%s' "$status" | grep -q 'state=held'; echo $?)
scenario_check "--lock-status names the holding pid" \
  $(printf '%s' "$status" | grep -q "holder_pid=$HOLDER"; echo $?)
# Silence is not evidence. A status that inspected zero subjects found nothing
# because it looked at nothing; the count is asserted, not assumed.
scenario_check "--lock-status asserts it inspected more than zero subjects" \
  $(printf '%s' "$status" | grep -qE 'inspected=[1-9][0-9]*'; echo $?)
scenario_check "the lock is stamped prov=test, never readable as a real holder" \
  $(printf '%s' "$status" | grep -q 'prov=test'; echo $?)

# --- the second writer is refused, and told who has it ---------------------
second_err="$("$BATON_BIN" --claim "session:$SID" -- sh -c "echo SECOND > '$SCRATCH/second'" 2>&1)"; secrc=$?
scenario_check "a second claim on the same session exits nonzero" $([ "$secrc" -ne 0 ]; echo $?)
scenario_check "the refusal names the holder pid" \
  $(printf '%s' "$second_err" | grep -q "$HOLDER"; echo $?)
# The load-bearing one: refusing has to mean the guarded work did NOT happen.
scenario_check "the second writer's guarded command never ran" \
  $([ ! -e "$SCRATCH/second" ]; echo $?)
# The refusal is an operator-facing line on a possibly shared stream, so it
# says what happened and names a knob, never a command to paste (root cause 2).
scenario_check "the refusal hands over no runnable baton command line" \
  $(! printf '%s' "$second_err" | grep -qE '(^|[^-])baton +[a-z-]'; echo $?)

# --- could-not-inspect is exit 2, and it is not a free lock ----------------
chmod 000 "$LOCKS"
sealed="$("$BATON_BIN" --lock-status "session:$SID" 2>&1)"; sealrc=$?
sealed_claim_err="$("$BATON_BIN" --claim "session:$SID" -- sh -c "echo THIRD > '$SCRATCH/third'" 2>&1)"; sealclaimrc=$?
chmod 755 "$LOCKS"

scenario_check "an unreadable lock dir exits 2 (could-not-inspect)" $([ "$sealrc" -eq 2 ]; echo $?)
scenario_check "an unreadable lock dir reports state=could-not-inspect" \
  $(printf '%s' "$sealed" | grep -q 'state=could-not-inspect'; echo $?)
scenario_check "an unreadable lock dir reports inspected=0, not a clean board" \
  $(printf '%s' "$sealed" | grep -q 'inspected=0'; echo $?)
scenario_check "a claim under an unreadable lock dir exits 2, never 0" \
  $([ "$sealclaimrc" -eq 2 ]; echo $?)
scenario_check "a claim under an unreadable lock dir ran no guarded command" \
  $([ ! -e "$SCRATCH/third" ]; echo $?)

# --- a dead owner does not deadlock the subject ----------------------------
# SIGKILL, so the holder never gets to release: this is the crash shape, and
# the only thing left behind is an owner record naming a pid that is gone.
kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
sleep 0.3

after="$("$BATON_BIN" --lock-status "session:$SID" 2>&1)"; afterrc=$?
scenario_check "a lock whose owner pid is confirmed gone exits 0 (reclaimable)" \
  $([ "$afterrc" -eq 0 ]; echo $?)
scenario_check "a dead owner reads state=stale-dead, not held" \
  $(printf '%s' "$after" | grep -q 'state=stale-dead'; echo $?)
scenario_check "a dead owner is still an inspected subject" \
  $(printf '%s' "$after" | grep -qE 'inspected=[1-9][0-9]*'; echo $?)

"$BATON_BIN" --claim "session:$SID" -- sh -c "echo RECLAIMED > '$SCRATCH/reclaimed'" >/dev/null 2>&1
scenario_check "the next writer reclaims the dead owner's lock and runs" \
  $([ -e "$SCRATCH/reclaimed" ]; echo $?)

# The live-pid-but-foreign-fingerprint reclaim (pid reuse after a reboot) is
# asserted at the module seam in tests/unit/lock_test.sh
# (reused-pid-state-is-stale-foreign / reused-pid-lock-is-reclaimable): it
# needs an owner record planted against a pid this process did not start,
# which is a fixture the CLI deliberately offers no way to write.

# --- the evidence layer never came to depend on the claim layer ------------
rm -rf "$LOCKS"
"$BATON_BIN" --pickup >/dev/null 2>&1; puprc=$?
scenario_check "--pickup still answers with no lock root present at all" \
  $([ "$puprc" -eq 0 ] || [ "$puprc" -eq 1 ] || [ "$puprc" -eq 2 ]; echo $?)
scenario_check "--pickup did not create a lock root as a side effect" \
  $([ ! -d "$LOCKS" ]; echo $?)

cleanup_root
scenario_end
