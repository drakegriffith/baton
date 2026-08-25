#!/usr/bin/env bash
# Issue #2 root cause 1: nothing stopped two processes from resuming the SAME
# session id under the shared projects/ tree. On 2026-08-25 two relaunch
# command lines landed in one terminal, both were run, one claude absorbed the
# session and the other died.
#
# This scenario drives the real `baton` CLI (never sources lib/lock.sh) and
# pins the whole contract of the single-writer lock:
#
#   * positive control -- a resume with nothing competing SUCCEEDS and leaves
#     exactly one lock subject behind. If the guard were never reached, the
#     lock root would hold zero subjects and `baton --locks` would exit 1
#     ("inspected 0"), so every refusal assertion below would be vacuous. This
#     is the case with the known outcome that fails loudly if the test never
#     touched the code under test.
#   * a second resume of a LIVE holder exits nonzero and NAMES the holder pid,
#     and never invokes claude at all.
#   * a DEAD holder is reclaimed, so a crash cannot wedge baton forever.
#   * PID REUSE is guarded: an owner record whose pid is alive but whose
#     recorded start time does not match that pid's current start time is
#     stale, not live. A `kill -0`-only implementation calls this live and
#     fails here.
#   * could-not-inspect is NOT a pass: a missing lock root and an unreadable
#     lock root both exit 2, and a readable-but-empty root exits 1. Three
#     distinguishable answers, so "no locks held" can never be read out of a
#     directory nobody could open.
#   * login flows serialize under the same lock root (root cause 3): two
#     overlapping /login flows rotate each other's OAuth refresh tokens, and
#     the CLI's own .oauth_refresh.lock is scoped per credentials store, so it
#     cannot see across two CLAUDE_CONFIG_DIRs.
#
# Every path here stays inside the scenario's temp BATON_ACCOUNTS_ROOT: the
# lock root is $BATON_ACCOUNTS_ROOT/.locks by construction, so this test can
# never touch a real ~/.claude-accounts.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "29-resume-single-writer"
fresh_root

LOCKROOT="$BATON_ACCOUNTS_ROOT/.locks"

# run_baton ARGS... -- every FOREGROUND baton call in this scenario goes
# through an alarm, using the same `perl -e 'alarm ...; exec'` idiom
# lib/accounts.sh already uses for its probe. Without it, a regression in the
# guard does not fail this scenario, it HANGS it -- and a hung scenario hangs
# `bash tests/run.sh` for everyone. Bounded failure beats a wedged suite.
# The exit-code assertions below are exact (3, 7, 5, 2, 1) rather than merely
# "nonzero" for the same reason: the alarm's own 142 must never be mistaken
# for the refusal this scenario is trying to observe.
run_baton() { perl -e 'alarm shift; exec @ARGV' 20 "$BATON_BIN" "$@"; }

# --- could-not-inspect, before anything has ever taken a lock --------------
# A missing lock root is NOT "no locks are held"; it is "I could not look".
run_baton --locks >"$SCRATCH/locks0.out" 2>&1
rc_missing=$?
scenario_check "missing lock root exits 2 (could-not-inspect, never a pass)" \
  $([ "$rc_missing" -eq 2 ]; echo $?)

mkdir -p "$LOCKROOT"
run_baton --locks >"$SCRATCH/locks1.out" 2>&1
rc_empty=$?
scenario_check "readable-but-empty lock root exits 1, distinct from 2" \
  $([ "$rc_empty" -eq 1 ]; echo $?)
scenario_check "the empty report states the subject count it inspected" \
  $(grep -q "inspected 0 lock subject" "$SCRATCH/locks1.out"; echo $?)

# Invocation plan for account "a" (the fake claude indexes STEP_* by
# invocation number, and a REFUSED launch must not consume one):
#   1 positive control     exit 0
#   2 live holder          blocks until SIGTERM/SIGKILL
#   3 reclaim of the dead holder     exit 7
#   4 reclaim after pid reuse        exit 5
#   5 login holder         blocks
write_behavior a <<'EOF'
STEP_EXIT=(0 143 7 5 143)
STEP_BLOCK=(0 1 0 0 1)
STEP_BLOCK_EXIT=(143 143 143 143 143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
EOF

# --- positive control ------------------------------------------------------
run_baton a --resume sess-pc >"$SCRATCH/pc.out" 2>"$SCRATCH/pc.err"
pc_rc=$?
scenario_check "POSITIVE CONTROL: an uncontended resume still launches (exit 0)" \
  $([ "$pc_rc" -eq 0 ]; echo $?)
scenario_check "POSITIVE CONTROL: claude really ran (invocation 1)" \
  $([ "$(invocation_count a)" -eq 1 ]; echo $?)
scenario_check "POSITIVE CONTROL: the guard was reached -- a lock subject exists" \
  $([ -d "$LOCKROOT/session-sess-pc" ]; echo $?)
run_baton --locks >"$SCRATCH/locks2.out" 2>&1
rc_pc_locks=$?
scenario_check "POSITIVE CONTROL: --locks now exits 0 having inspected > 0 subjects" \
  $([ "$rc_pc_locks" -eq 0 ]; echo $?)
scenario_check "POSITIVE CONTROL: the report names the count it inspected" \
  $(grep -qE "inspected [1-9][0-9]* lock subject" "$SCRATCH/locks2.out"; echo $?)

# --- a live holder refuses the second resume, by pid -----------------------
# NOT through run_baton: the holder must outlive the alarm, and backgrounding
# a shell FUNCTION would make $! the wrapper subshell's pid rather than
# baton's -- which is the very pid the refusal below has to name.
"$BATON_BIN" a --resume sess-live >"$SCRATCH/holder.out" 2>"$SCRATCH/holder.err" &
HOLDER=$!
waited=0
while [ ! -s "$LOCKROOT/session-sess-live/owner" ]; do
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -gt 100 ] && break
done
scenario_check "the live holder wrote an owner record" \
  $([ -s "$LOCKROOT/session-sess-live/owner" ]; echo $?)
# baton execs claude, so the process holding the lock keeps baton's own pid
# (scenario 11 pins that exec, not fork). The owner pid must be that pid.
owner_pid=$(awk '$1=="pid"{print $2; exit}' "$LOCKROOT/session-sess-live/owner" 2>/dev/null)
scenario_check "the owner pid is the live process, not some other number" \
  $([ "$owner_pid" = "$HOLDER" ]; echo $?)

run_baton a --resume sess-live >"$SCRATCH/second.out" 2>"$SCRATCH/second.err"
second_rc=$?
scenario_check "the second resume of a live session exits nonzero" \
  $([ "$second_rc" -ne 0 ]; echo $?)
scenario_check "it exits 3 specifically (refused), not 142 (the alarm) or 2" \
  $([ "$second_rc" -eq 3 ]; echo $?)
scenario_check "the refusal NAMES the holder pid" \
  $(grep -q "$HOLDER" "$SCRATCH/second.err"; echo $?)
scenario_check "the refused launch never invoked claude" \
  $([ "$(invocation_count a)" -eq 2 ]; echo $?)

run_baton --locks >"$SCRATCH/locks3.out" 2>&1
scenario_check "--locks reports the held session as live and names its pid" \
  $(grep "session-sess-live" "$SCRATCH/locks3.out" | grep -q "live" \
    && grep "session-sess-live" "$SCRATCH/locks3.out" | grep -q "$HOLDER"; echo $?)

# --- an unreadable lock root is could-not-inspect, not "all clear" ---------
chmod 000 "$LOCKROOT"
run_baton --locks >"$SCRATCH/locks4.out" 2>&1
rc_unreadable=$?
scenario_check "unreadable lock root exits 2, with a lock demonstrably held" \
  $([ "$rc_unreadable" -eq 2 ]; echo $?)
chmod 755 "$LOCKROOT"

# --- a dead holder is reclaimed -------------------------------------------
kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
scenario_check "the dead holder's lock dir is still on disk (nothing cleaned up for us)" \
  $([ -d "$LOCKROOT/session-sess-live" ]; echo $?)
run_baton --locks >"$SCRATCH/locks5.out" 2>&1
scenario_check "--locks now reports that subject stale" \
  $(grep "session-sess-live" "$SCRATCH/locks5.out" | grep -q "stale"; echo $?)

run_baton a --resume sess-live >"$SCRATCH/reclaim.out" 2>"$SCRATCH/reclaim.err"
reclaim_rc=$?
scenario_check "resuming after the holder died succeeds (stale lock reclaimed)" \
  $([ "$reclaim_rc" -eq 7 ]; echo $?)
scenario_check "the reclaiming launch actually reached claude (invocation 3)" \
  $([ "$(invocation_count a)" -eq 3 ]; echo $?)

# --- pid reuse: alive pid + wrong start time == stale ----------------------
# This test script is unquestionably alive, so a `kill -0`-only liveness test
# calls this lock live and refuses. The start-time witness is what tells a
# recycled pid from the original holder.
mkdir -p "$LOCKROOT/session-sess-reuse"
{
  printf 'pid %s\n' "$$"
  printf 'start %s\n' 'Thu Jan  1 00:00:00 1970'
  printf 'what %s\n' 'forged owner with a recycled pid'
  printf 'since %s\n' "$(date +%s)"
} > "$LOCKROOT/session-sess-reuse/owner"

run_baton --locks >"$SCRATCH/locks6.out" 2>&1
scenario_check "a live pid with a mismatched start time reads stale, not live" \
  $(grep "session-sess-reuse" "$SCRATCH/locks6.out" | grep -q "stale"; echo $?)
run_baton a --resume sess-reuse >"$SCRATCH/reuse.out" 2>"$SCRATCH/reuse.err"
reuse_rc=$?
scenario_check "a recycled-pid lock is reclaimed rather than wedging baton" \
  $([ "$reuse_rc" -eq 5 ]; echo $?)

# --- login flows serialize under the same lock root ------------------------
"$BATON_BIN" --login a >"$SCRATCH/login1.out" 2>"$SCRATCH/login1.err" &
LOGIN_HOLDER=$!
waited=0
while [ ! -s "$LOCKROOT/login/owner" ]; do
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -gt 100 ] && break
done
scenario_check "the first login flow took the shared login lock" \
  $([ -s "$LOCKROOT/login/owner" ]; echo $?)

run_baton --login b >"$SCRATCH/login2.out" 2>"$SCRATCH/login2.err"
login2_rc=$?
scenario_check "a second login flow for a DIFFERENT account is refused" \
  $([ "$login2_rc" -eq 3 ]; echo $?)
scenario_check "the login refusal names the holding pid" \
  $(grep -q "$LOGIN_HOLDER" "$SCRATCH/login2.err"; echo $?)
scenario_check "the refused login never invoked claude under b" \
  $([ "$(invocation_count b)" -eq 0 ]; echo $?)

kill -KILL "$LOGIN_HOLDER" 2>/dev/null
wait "$LOGIN_HOLDER" 2>/dev/null

cleanup_root
scenario_end
