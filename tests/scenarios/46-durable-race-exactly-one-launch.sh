#!/usr/bin/env bash
# baton#12 durable race regression: two `baton a --resume <id>` processes are
# pre-spawned, synchronized by a file barrier, and released together. In 20
# reps exactly one must reach the CLI and the other must refuse, naming the
# holder pid. A negative control with BATON_LOCK_DISABLE=1 must produce two
# launches per rep; if it cannot observe the failure, the scenario fails.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "46-durable-race-exactly-one-launch"
fresh_root
export BATON_LOCK_PROV=test

SID="race-sess-001"
N=20
NEG_REPS=3

# Fake claude blocks briefly so the race window is real and observable.
write_behavior a <<'EOF'
STEP_BLOCK=(1 1)
STEP_BLOCK_TICKS=(10 10)
STEP_STDOUT=("holding" "holding")
EOF

run_rep() {
  local disable="${1:-0}"
  local rep="$2"
  local go="$SCRATCH/go-$rep"
  local ready1="$SCRATCH/ready-$rep-1"
  local ready2="$SCRATCH/ready-$rep-2"
  rm -f "$go" "$ready1" "$ready2"

  (
    echo "$$" > "$ready1"
    while [ ! -e "$go" ]; do sleep 0.01; done
    if [ "$disable" -eq 1 ]; then
      BATON_LOCK_DISABLE=1 exec "$BATON_BIN" a --resume "$SID"
    else
      exec "$BATON_BIN" a --resume "$SID"
    fi
  ) >"$SCRATCH/r$rep-1.out" 2>"$SCRATCH/r$rep-1.err" &
  local p1=$!

  (
    echo "$$" > "$ready2"
    while [ ! -e "$go" ]; do sleep 0.01; done
    if [ "$disable" -eq 1 ]; then
      BATON_LOCK_DISABLE=1 exec "$BATON_BIN" a --resume "$SID"
    else
      exec "$BATON_BIN" a --resume "$SID"
    fi
  ) >"$SCRATCH/r$rep-2.out" 2>"$SCRATCH/r$rep-2.err" &
  local p2=$!

  # Wait for both ready markers.
  local waited=0
  while [ ! -s "$ready1" ] || [ ! -s "$ready2" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -gt 200 ] && break
  done

  # Release.
  : > "$go"

  # Wait for both to finish (fake claude blocks ~1s then exits).
  wait "$p1" 2>/dev/null || true
  wait "$p2" 2>/dev/null || true

  # Count launches in the fake claude log for this rep.
  local before="$3"
  local after; after=$(grep -c '^inv=' "$(fake_log)" 2>/dev/null || echo 0)
  echo "$((after - before))"
}

log_before=$(grep -c '^inv=' "$(fake_log)" 2>/dev/null || echo 0)
single_writer_passes=0
single_writer_failures=""

for i in $(seq 1 "$N"); do
  before=$(grep -c '^inv=' "$(fake_log)" 2>/dev/null || echo 0)
  launches=$(run_rep 0 "$i" "$before")
  if [ "$launches" -eq 1 ]; then
    single_writer_passes=$((single_writer_passes + 1))
  else
    single_writer_failures="$single_writer_failures $i($launches)"
  fi
done

scenario_check "race produced exactly one launch in all $N reps" \
  $([ "$single_writer_passes" -eq "$N" ]; echo $?)

# Negative control: the harness must be able to observe the failure mode.
neg_control_passes=0
neg_control_failures=""
for i in $(seq 1 "$NEG_REPS"); do
  before=$(grep -c '^inv=' "$(fake_log)" 2>/dev/null || echo 0)
  launches=$(run_rep 1 "neg-$i" "$before")
  if [ "$launches" -eq 2 ]; then
    neg_control_passes=$((neg_control_passes + 1))
  else
    neg_control_failures="$neg_control_failures $i($launches)"
  fi
done

# A race test that cannot observe the failure is a green check that inspected
# nothing. The negative control MUST fire; if it does not, this scenario fails.
scenario_check "negative control produced two launches in all $NEG_REPS reps" \
  $([ "$neg_control_passes" -eq "$NEG_REPS" ]; echo $?)

# At least one refusal must name the holder pid across all positive reps.
named_holder=0
for f in "$SCRATCH"/r*-1.err "$SCRATCH"/r*-2.err; do
  [ -f "$f" ] || continue
  if grep -qE 'locked by live pid [0-9]+' "$f" 2>/dev/null; then
    named_holder=$((named_holder + 1))
  fi
done
scenario_check "at least one refusal named the holding pid" \
  $([ "$named_holder" -gt 0 ]; echo $?)

cleanup_root
scenario_end
