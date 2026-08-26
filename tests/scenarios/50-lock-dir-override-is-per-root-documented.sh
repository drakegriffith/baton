#!/usr/bin/env bash
# baton#12 gap 2, the half that stays open BY DESIGN: BATON_LOCK_DIR is an
# explicit operator override, so two shells that set DIFFERENT lock dirs over
# one $HOME/.claude get two lock roots and two concurrent `baton a --resume
# <id>` both launch. lib/lock.sh documents the override as deliberate. This
# scenario records the DOCUMENTED count (2) so the exposure is measured, not
# silent; verify-lock2 (2026-08-26) measured 3/3 double launches with no test
# saying so. If BATON_LOCK_DIR ever gains a warning or a machine-wide fence,
# flip this assertion on purpose, in the same commit.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "50-lock-dir-override-is-per-root-documented"
fresh_root
export BATON_LOCK_PROV=test

SID="shared-sess-001"
ROOT1="$SCRATCH/accounts1"
ROOT2="$ROOT1"
LOCKDIR1="$SCRATCH/locks1"
LOCKDIR2="$SCRATCH/locks2"
mkdir -p "$ROOT1" "$ROOT1/.alive"
ln -s "$HOME/.claude" "$ROOT1/a"
touch "$ROOT1/.alive/a"

write_behavior a <<'EOF'
STEP_BLOCK=(1 1)
STEP_STDOUT=("first" "second")
EOF

GO="$SCRATCH/go"
rm -f "$GO"

spawn_racer() {
  local lockdir="$1" out="$2" err="$3" ready="$4"
  (
    export BATON_ACCOUNTS_ROOT="$ROOT1" BATON_LOCK_DIR="$lockdir"
    # Register readiness, then busy-wait on the GO file so both racers are
    # pre-spawned before either runs baton.
    echo "$$" > "$ready"
    while [ ! -e "$GO" ]; do sleep 0.01; done
    "$BATON_BIN" a --resume "$SID"
  ) >"$out" 2>"$err" &
}

spawn_racer "$LOCKDIR1" "$SCRATCH/r1.out" "$SCRATCH/r1.err" "$SCRATCH/ready1"
P1=$!
spawn_racer "$LOCKDIR2" "$SCRATCH/r2.out" "$SCRATCH/r2.err" "$SCRATCH/ready2"
P2=$!

# Wait until both racers have registered their ready markers.
waited=0
while [ ! -s "$SCRATCH/ready1" ] || [ ! -s "$SCRATCH/ready2" ]; do
  sleep 0.05
  waited=$((waited + 1))
  [ "$waited" -gt 200 ] && break
done
scenario_check "both racers reached the barrier" \
  $([ -s "$SCRATCH/ready1" ] && [ -s "$SCRATCH/ready2" ]; echo $?)

# Release the barrier.
: > "$GO"

# Both racers are expected to launch and block in fake claude; give them time
# to reach the CLI rather than waiting for either to exit.
sleep 1

# The winner is still launching fake claude; give it a moment to reach the CLI
# before counting log lines. Poll the shared config dir's pid file as evidence
# the fake claude has started.
waited=0
while [ ! -f "$HOME/.claude/.fake-pid-ppid" ] && [ "$waited" -lt 100 ]; do
  sleep 0.05
  waited=$((waited + 1))
done

# With two lock roots there is nothing to arbitrate: the documented count is
# two launches into one primary config directory.
total_launches=$(grep -c '^inv=' "$ROOT1/.fake-claude.log" 2>/dev/null || echo 0)
scenario_check "launch count was actually taken" \
  $([ -n "$total_launches" ]; echo $?)
scenario_check "documented exposure: two BATON_LOCK_DIRs let both --resume launches reach the CLI" \
  $([ "$total_launches" -eq 2 ]; echo $?)
scenario_check "each override root minted its own session lock" \
  $([ -d "$LOCKDIR1/session_$SID.lock" ] && [ -d "$LOCKDIR2/session_$SID.lock" ]; echo $?)

# Cleanup: kill BOTH racers and every fake claude under this scratch, then
# wait. kill_fake_claude reads one pid file that holds only the LAST fake
# claude, so when the fix is absent and both racers launched, one survived
# and the bare wait hung the whole suite instead of failing this scenario
# (verify-lock2 ablation, 2026-08-26). A regression test must fail, not hang.
kill -KILL "$P1" "$P2" 2>/dev/null || true
pkill -KILL -f "$SCRATCH" 2>/dev/null || true
kill_fake_claude a 2>/dev/null || true
wait "$P1" 2>/dev/null || true
wait "$P2" 2>/dev/null || true
cleanup_root
scenario_end
