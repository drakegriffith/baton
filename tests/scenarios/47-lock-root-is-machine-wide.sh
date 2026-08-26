#!/usr/bin/env bash
# baton#12 gap 2: the lock root must be keyed to the resolved config directory
# the launch writes to, not to BATON_ACCOUNTS_ROOT. Two different accounts
# roots that both symlink their primary account to the same $HOME/.claude must
# share one lock root; otherwise two concurrent `baton a --resume <id>` both
# write the primary directory and the single-writer guard is silently bypassed.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "47-lock-root-is-machine-wide"
fresh_root
export BATON_LOCK_PROV=test

SID="shared-sess-001"
ROOT1="$SCRATCH/accounts1"
ROOT2="$SCRATCH/accounts2"
mkdir -p "$ROOT1" "$ROOT2"
ln -s "$HOME/.claude" "$ROOT1/a"
ln -s "$HOME/.claude" "$ROOT2/a"
mkdir -p "$ROOT1/.alive" "$ROOT2/.alive"
touch "$ROOT1/.alive/a" "$ROOT2/.alive/a"

write_behavior a <<'EOF'
STEP_BLOCK=(1 1)
STEP_STDOUT=("first" "second")
EOF

GO="$SCRATCH/go"
rm -f "$GO"

spawn_racer() {
  local root="$1" out="$2" err="$3" ready="$4"
  (
    export BATON_ACCOUNTS_ROOT="$root"
    # Register readiness, then busy-wait on the GO file so both racers are
    # pre-spawned before either runs baton.
    echo "$$" > "$ready"
    while [ ! -e "$GO" ]; do sleep 0.01; done
    "$BATON_BIN" a --resume "$SID"
  ) >"$out" 2>"$err" &
}

spawn_racer "$ROOT1" "$SCRATCH/r1.out" "$SCRATCH/r1.err" "$SCRATCH/ready1"
P1=$!
spawn_racer "$ROOT2" "$SCRATCH/r2.out" "$SCRATCH/r2.err" "$SCRATCH/ready2"
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

# Wait for the loser to finish (fast); the winner stays blocked in fake claude.
waited=0
while kill -0 "$P1" 2>/dev/null && kill -0 "$P2" 2>/dev/null; do
  sleep 0.05
  waited=$((waited + 1))
  [ "$waited" -gt 200 ] && break
done

# The winner is still launching fake claude; give it a moment to reach the CLI
# before counting log lines. Poll the shared config dir's pid file as evidence
# the fake claude has started.
waited=0
while [ ! -f "$HOME/.claude/.fake-pid-ppid" ] && [ "$waited" -lt 100 ]; do
  sleep 0.05
  waited=$((waited + 1))
done

# Both account roots keep their own fake-claude log; the total argv= count is
# what matters, because only one launch should have reached the CLI.
total_launches=$(grep -c '^inv=' "$ROOT1/.fake-claude.log" "$ROOT2/.fake-claude.log" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
scenario_check "exactly one launch reached the fake claude CLI" \
  $([ "$total_launches" -eq 1 ]; echo $?)
scenario_check "exactly one --resume argv was logged" \
  $([ "$(grep -c -- "--resume $SID" "$ROOT1/.fake-claude.log" "$ROOT2/.fake-claude.log" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" -eq 1 ]; echo $?)

# Identify winner and loser by who is still running. The winner's baton process
# has exec'd into the long-lived fake claude; the loser exited (refused or CNI).
if kill -0 "$P1" 2>/dev/null; then
  winner_pid="$P1"; loser_pid="$P2"
else
  winner_pid="$P2"; loser_pid="$P1"
fi
scenario_check "exactly one racer is still running (the winner)" \
  $([ -n "$winner_pid" ] && kill -0 "$winner_pid" 2>/dev/null && ! kill -0 "$loser_pid" 2>/dev/null; echo $?)

# Positive control: the winner's process is still the session holder. The
# holder pid is the baton/claude pid (after exec), which the fake claude wrote
# to its config dir; it is not the subshell pid that spawned baton.
status="$(BATON_ACCOUNTS_ROOT="$ROOT1" "$BATON_BIN" --lock-status "session:$SID" 2>&1)"; strc=$?
scenario_check "the winner holds the session lock" \
  $([ "$strc" -eq 1 ]; echo $?)
holder_pid=$(printf '%s' "$status" | sed -n 's/.*holder_pid=\([0-9]*\).*/\1/p')
claude_pid=$(awk '{print $1}' "$HOME/.claude/.fake-pid-ppid" 2>/dev/null)
scenario_check "the lock status names the fake claude pid" \
  $([ "$holder_pid" = "$claude_pid" ]; echo $?)

# Cleanup any still-blocking fake claude and its parent racer subshells.
kill_fake_claude a
wait "$P1" 2>/dev/null || true
wait "$P2" 2>/dev/null || true
cleanup_root
scenario_end
