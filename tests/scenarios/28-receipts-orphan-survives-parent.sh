#!/usr/bin/env bash
# The incident this whole mechanism exists for, reproduced end to end.
#
# baton is killed while its watched child is still working -- the shape a
# dropped API connection or a closed terminal takes. The child is a separate
# process group, so it is reparented and keeps running, and nothing ever
# reattaches to it. Before receipts, the only trace was an absence, and an
# absence reads identically to "never started": re-dispatching on it launches
# a second copy on top of the first.
#
# What must hold: a start receipt survives the parent, no completion receipt
# is invented, and pickup reports the survivor as orphan-running with action
# `monitor` -- never `dispatch`.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "28-receipts-orphan-survives-parent"
fresh_root

# STEP_BLOCK holds the child open, so it is still running when the parent is
# killed underneath it.
write_behavior a <<'EOF'
STEP_BLOCK=(1)
STEP_TRANSCRIPT=("sess-orphan")
STEP_STDOUT=("working on it")
EOF

start_night
# Wait for the transcript, which is proof the child actually launched: killing
# the parent before that would test the launcher-start gap instead.
transcript="$(wait_for_transcript a 10)"
scenario_check "child launched (transcript exists)" $([ -n "$transcript" ]; echo $?)

# Kill the PARENT, not the child. This is the dropped-connection shape.
stop_night

RUNS="$BATON_ACCOUNTS_ROOT/.runs"
start_receipt="$(ls -1 "$RUNS"/*.start 2>/dev/null | head -1)"
scenario_check "start receipt survived the parent's death" $([ -n "$start_receipt" ]; echo $?)
scenario_check "no completion receipt was invented" \
  $([ -z "$(ls -1 "$RUNS"/*.complete 2>/dev/null)" ]; echo $?)

# --pickup's classification of a live pid as orphan-running requires a
# working process table (runs_project -> runs_alive -> ps -p 1 positive
# control). When ps is refused these correctly fall back to `unknown`
# rather than a wrong guess -- see the same-bucket needs-reconcile/exit-1/
# forensics checks below, which stay green either way.
out="$("$BATON_BIN" --pickup 2>/dev/null)"; rc=$?
scenario_check "pickup classified the survivor orphan-running" \
  $(printf '%s' "$out" | grep -q '"status": "orphan-running"'; echo $?) cni
# The load-bearing assertion: an orphan is adopted, never relaunched. A
# `dispatch` here would double-run the work.
scenario_check "pickup action is monitor, not dispatch" \
  $(printf '%s' "$out" | grep -q '"status": "orphan-running", "action": "monitor"'; echo $?) cni
scenario_check "pickup exits 1 (needs a decision)" $([ "$rc" -eq 1 ]; echo $?)
scenario_check "pickup verdict is needs-reconcile" \
  $(printf '%s' "$out" | grep -q '"verdict": "needs-reconcile"'; echo $?)
scenario_check "board is not silently empty" \
  $(printf '%s' "$out" | grep -q '"inspected": 1'; echo $?)

# Now the orphan really dies, the way it would if it finished or was reaped.
# The SAME receipts must now read dead-partial rather than orphan-running:
# the probe is re-derived at read time, never cached from the last answer.
kill_fake_claude a
sleep 0.3
out2="$("$BATON_BIN" --pickup 2>/dev/null)"; rc2=$?
scenario_check "after the orphan dies it reads dead-partial" \
  $(printf '%s' "$out2" | grep -q '"status": "dead-partial"'; echo $?) cni
scenario_check "dead-partial still exits 1" $([ "$rc2" -eq 1 ]; echo $?)
scenario_check "dead-partial is routed to forensics" \
  $(printf '%s' "$out2" | grep -q 'needs_forensics'; echo $?)

cleanup_root
scenario_end
