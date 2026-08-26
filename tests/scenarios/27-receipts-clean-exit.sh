#!/usr/bin/env bash
# A watched child that exits cleanly leaves both receipts behind, and the
# board it leaves reads `resolved`. This is the control for scenario 25: if
# this one fails, the receipts never got written at all and 25's "no
# completion receipt" would prove nothing.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "27-receipts-clean-exit"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("all good")
EOF

start_night
wait_for_night_exit 10
scenario_check "night process exited" $?

RUNS="$BATON_ACCOUNTS_ROOT/.runs"
start_receipt="$(ls -1 "$RUNS"/*.start 2>/dev/null | head -1)"
complete_receipt="$(ls -1 "$RUNS"/*.complete 2>/dev/null | head -1)"

scenario_check "a start receipt was written" $([ -n "$start_receipt" ]; echo $?)
scenario_check "a completion receipt was written" $([ -n "$complete_receipt" ]; echo $?)

# The pid recorded at launch is the whole basis of the liveness probe. A
# receipt without one cannot tell an orphan from a corpse.
scenario_check "start receipt carries a numeric pid" \
  $(grep -qE '^pid=[0-9]+$' "$start_receipt" 2>/dev/null; echo $?)
# The fingerprint is what defeats pid reuse; empty means the guard is off.
# `runs_record_start` fills it from `runs_fingerprint`, which needs a working
# process table (lib/runs.sh's `ps -p 1` positive control); when ps is
# refused the fingerprint field is legitimately empty, not a receipts defect.
scenario_check "start receipt carries a non-empty fingerprint" \
  $(grep -qE '^fingerprint=.+$' "$start_receipt" 2>/dev/null; echo $?) cni
scenario_check "completion receipt carries exit 0" \
  $(grep -qx 'exit=0' "$complete_receipt" 2>/dev/null; echo $?)

# The board a restarted orchestrator would read: nothing in flight, nothing
# to reconcile, exit 0.
out="$("$BATON_BIN" --pickup 2>/dev/null)"; rc=$?
scenario_check "pickup exits 0 on a resolved board" $([ "$rc" -eq 0 ]; echo $?)
scenario_check "pickup verdict is resolved" \
  $(printf '%s' "$out" | grep -q '"verdict": "resolved"'; echo $?)
scenario_check "pickup classified the unit done" \
  $(printf '%s' "$out" | grep -q '"status": "done"'; echo $?)
# Receipts written by a real run are live rows, not self-test rows.
scenario_check "pickup board is stamped live" \
  $(printf '%s' "$out" | grep -q '"prov": "live"'; echo $?)

cleanup_root
scenario_end
