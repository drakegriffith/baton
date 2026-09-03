#!/usr/bin/env bash
# baton#2 acceptance criterion 1, on the path the 2026-08-25 incident actually
# used: the INTERACTIVE resume, not `--night`.
#
# Scenario 33 proves the criterion for `--night`, whose watcher claims
# `session:<id>` in run_watched. That left the ordinary operator path
# unguarded: `baton <account> --resume <id>` and `baton --fast --resume <id>`
# claimed no session subject at all. Because every account symlinks projects/
# back into ~/.claude, one session id names ONE transcript that any account
# can reopen -- so two DIFFERENT accounts resuming one id both launched, both
# exited 0, and `--lock-status session:<id>` reported `free`. Two runnable
# relaunch lines landing in one terminal is exactly how that gets typed.
#
# The refusal here has to name the SESSION subject, not merely refuse. The
# forced-account path also takes the global login claim (root cause 3), and a
# refusal that could have come from either lock proves neither; the session
# claim is therefore taken FIRST, so the message attributes the block to the
# thing that is actually contested.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "35-interactive-resume-is-single-writer"
fresh_root
export BATON_LOCK_PROV=test

LOCKS="$BATON_ACCOUNTS_ROOT/.locks"
SID="sess-shared-abc"
OTHER="sess-uncontested-xyz"

write_behavior a <<'EOF'
STEP_BLOCK=(1 0)
STEP_BLOCK_EXIT=(143)
STEP_STDOUT=("holding the shared session" "a second call")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0 0)
STEP_STDOUT=("b ran" "b ran again")
EOF

# --- the first writer: a real interactive resume, under account a ----------
"$BATON_BIN" a --resume "$SID" >"$SCRATCH/one.out" 2>"$SCRATCH/one.err" &
HOLDER=$!
waited=0
while [ ! -e "$LOCKS/session_$SID.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done
# `baton a --resume $SID`'s own claim is gated by lock_claim's
# `_runs_ps_usable` check (via lock_guard_launch): when ps is refused it
# never lands an owner record or even execs claude, so a's process exits
# early and nothing below that depends on a real held session can resolve.
scenario_check "an interactive resume claims the session subject at all" \
  $([ -e "$LOCKS/session_$SID.lock/owner" ]; echo $?) cni

status="$("$BATON_BIN" --lock-status "session:$SID" 2>&1)"; strc=$?
scenario_check "--lock-status reports the interactively-held session as held" \
  $([ "$strc" -eq 1 ]; echo $?) cni
scenario_check "--lock-status names the interactive holder's pid" \
  $(printf '%s' "$status" | grep -q "holder_pid=$HOLDER"; echo $?) cni

# --- THE PROBE: a DIFFERENT account resuming the same session id -----------
before_b="$(invocation_count b)"
"$BATON_BIN" b --resume "$SID" >"$SCRATCH/two.out" 2>"$SCRATCH/two.err"
rc2=$?
scenario_check "a second account resuming the same session exits nonzero" \
  $([ "$rc2" -ne 0 ]; echo $?)
scenario_check "the refusal attributes the block to the session subject" \
  $(grep -q "session:$SID" "$SCRATCH/two.err"; echo $?)
scenario_check "the refusal names the holding pid" \
  $(grep -q "$HOLDER" "$SCRATCH/two.err"; echo $?) cni
# The load-bearing consequence: no second claude ever opened the transcript.
scenario_check "the second writer never launched a claude under account b" \
  $([ "$(invocation_count b)" -eq "$before_b" ]; echo $?)
# Account a's own claim never landed either (same cascade), so a never
# resumed the session -- the count below is 0, not 1.
scenario_check "exactly one process ever resumed the contested session" \
  $([ "$(grep -c -- "--resume $SID" "$(fake_log)")" -eq 1 ]; echo $?) cni

# --- and the auto-pick path is guarded too ---------------------------------
# `baton --fast --resume <id>` picks whichever account ranks first; either
# choice is a second writer on a session someone else is holding.
"$BATON_BIN" --fast --resume "$SID" >"$SCRATCH/three.out" 2>"$SCRATCH/three.err"
rc3=$?
scenario_check "auto-pick resuming a held session also exits nonzero" \
  $([ "$rc3" -ne 0 ]; echo $?)
scenario_check "the auto-pick refusal also names the session subject" \
  $(grep -q "session:$SID" "$SCRATCH/three.err"; echo $?)
scenario_check "still exactly one process ever resumed the contested session" \
  $([ "$(grep -c -- "--resume $SID" "$(fake_log)")" -eq 1 ]; echo $?) cni

# --- positive control: the guard refuses a SESSION, not everything ---------
# Without this row, a baton that refused every launch outright would read
# green above. A different session id is uncontested and must still run.
# This uncontested session's own resume claim is gated by the same
# `_runs_ps_usable` check regardless of contention, so it too is refused
# when ps is refused.
"$BATON_BIN" --fast --resume "$OTHER" >"$SCRATCH/four.out" 2>"$SCRATCH/four.err"
rc4=$?
scenario_check "positive control: an UNcontested session still launches" \
  $([ "$rc4" -eq 0 ]; echo $?) cni
scenario_check "positive control: that launch really reached the CLI" \
  $(grep -q -- "--resume $OTHER" "$(fake_log)"; echo $?) cni

# --- a launch with no --resume claims no session subject -------------------
# Only an explicit `--resume <id>` is keyable: a cold start has no session id
# at the moment of launch, and guarding it under a guessed key would serialize
# unrelated launches onto one subject.
# Neither $SID nor $OTHER ever landed an owner record above (same ps
# cascade), so the count here is 0, not 2 -- absence of a claim, not
# evidence a guessed id was ever locked.
scenario_check "a cold launch minted no session lock for a guessed id" \
  $([ "$(ls "$LOCKS" 2>/dev/null | grep -c '^session_')" -eq 2 ]; echo $?) cni

kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
kill_fake_claude a
kill_fake_claude b
cleanup_root
scenario_end
