#!/usr/bin/env bash
# BATON_LOCK_DISABLE=1 is the single-writer guard's escape hatch, and it was a
# SILENT one: LOCK_STATE=disabled was assigned and read by zero consumers, no
# receipt recorded it, `--lock-status` still answered `free`, and the lock root
# was never even created, so nothing on disk showed afterwards that the guard
# had been off. Two concurrent dispatches of one unit and 0 bytes on stderr.
#
# The hatch stays -- a guard that can strand an operator with no way through is
# a worse failure than the one it prevents -- but "the guard was off" is a fact
# about a run, and a fact about a run has to be recoverable from the run. So:
# loud on EVERY claim, stamped on every receipt written under it, named by the
# reporter, and left on disk.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "36-lock-bypass-leaves-evidence"
fresh_root
export BATON_LOCK_PROV=test

LOCKS="$(baton_lock_dir)"
UNIT="night-20260825T193000Z-9999-a"
DISPATCH_LOG="$SCRATCH/dispatches.log"
: > "$DISPATCH_LOG"

# --- the hatch still works: it really does let both through ----------------
# Asserted first and as a COUNT, because everything below is about evidence,
# and evidence of a bypass that never happened proves nothing.
BATON_LOCK_DISABLE=1 "$BATON_BIN" --claim "unit:$UNIT" \
  -- sh -c "echo dispatched >> '$DISPATCH_LOG'; sleep 1" \
  >"$SCRATCH/one.out" 2>"$SCRATCH/one.err" &
P1=$!
BATON_LOCK_DISABLE=1 "$BATON_BIN" --claim "unit:$UNIT" \
  -- sh -c "echo dispatched >> '$DISPATCH_LOG'; sleep 1" \
  >"$SCRATCH/two.out" 2>"$SCRATCH/two.err" &
P2=$!
wait "$P1"; wait "$P2"

scenario_check "the escape hatch still lets both writers through" \
  $([ "$(grep -c dispatched "$DISPATCH_LOG")" -eq 2 ]; echo $?)

# --- ...and it is no longer silent -----------------------------------------
scenario_check "the first bypassed claim warned on stderr" \
  $([ -s "$SCRATCH/one.err" ]; echo $?)
scenario_check "the second bypassed claim warned on stderr too" \
  $([ -s "$SCRATCH/two.err" ]; echo $?)
scenario_check "the warning names the knob that caused it" \
  $(grep -q 'BATON_LOCK_DISABLE' "$SCRATCH/one.err"; echo $?)
scenario_check "the warning says the guard was bypassed" \
  $(grep -qi 'bypass' "$SCRATCH/one.err"; echo $?)
scenario_check "the warning names the subject that went unguarded" \
  $(grep -q "unit:$UNIT" "$SCRATCH/one.err"; echo $?)

# EVERY claim, not once per process. `baton <account> --resume <id>` takes two
# claims in one process (the session, then the login flow), so a once-per-run
# warning would show up here as one line instead of two.
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("ran unguarded")
EOF
BATON_LOCK_DISABLE=1 "$BATON_BIN" a --resume sess-bypassed \
  >"$SCRATCH/three.out" 2>"$SCRATCH/three.err"
scenario_check "positive control: the bypassed launch really reached the CLI" \
  $(grep -q -- '--resume sess-bypassed' "$(fake_log)"; echo $?)
scenario_check "every bypassed claim warns, not just the first one per process" \
  $([ "$(grep -ci 'bypass' "$SCRATCH/three.err")" -ge 2 ]; echo $?)

# --- the reporter says bypassed, never free --------------------------------
# `free` under the knob is the specific lie: it is the answer an automated
# caller would read as "safe to launch", on a run where nothing is arbitrating.
st="$(BATON_LOCK_DISABLE=1 "$BATON_BIN" --lock-status "unit:$UNIT" 2>/dev/null)"
scenario_check "--lock-status under the knob reports state=bypassed" \
  $(printf '%s' "$st" | grep -q 'state=bypassed'; echo $?)
scenario_check "--lock-status under the knob does NOT report state=free" \
  $(! printf '%s' "$st" | grep -q 'state=free'; echo $?)

# --- a durable trace outlives the shell that set the knob ------------------
# BATON_LOCK_DISABLE is an exported env var: once set it persists for the
# shell and every child for an entire night. The env is gone by the time
# anyone investigates; the lock root is not.
scenario_check "the bypass left a durable trace under the lock root" \
  $([ -s "$LOCKS/bypass.log" ]; echo $?)
scenario_check "the trace names the subject that went unguarded" \
  $(grep -q "unit:$UNIT" "$LOCKS/bypass.log" 2>/dev/null; echo $?)

cleanup_root

# --- receipts written under the knob say so --------------------------------
fresh_root
export BATON_LOCK_PROV=test
export BATON_RUNS_PROV=test

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("clean")
EOF
BATON_LOCK_DISABLE=1 "$BATON_BIN" --night >"$SCRATCH/n1.out" 2>"$SCRATCH/n1.err"
start1="$(ls "$BATON_ACCOUNTS_ROOT/.runs"/*.start 2>/dev/null | head -1)"
scenario_check "positive control: the bypassed night run wrote a start receipt" \
  $([ -n "$start1" ]; echo $?)
scenario_check "a receipt written under the knob carries bypassed=yes" \
  $(grep -q '^bypassed=yes' "$start1" 2>/dev/null; echo $?)
complete1="$(ls "$BATON_ACCOUNTS_ROOT/.runs"/*.complete 2>/dev/null | head -1)"
scenario_check "so does the completion receipt" \
  $(grep -q '^bypassed=yes' "$complete1" 2>/dev/null; echo $?)

cleanup_root

# The negative half of the same field: without the knob it must say no, or
# `bypassed=yes` would be unfalsifiable and prove nothing when it appears.
fresh_root
export BATON_LOCK_PROV=test
export BATON_RUNS_PROV=test
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("clean")
EOF
"$BATON_BIN" --night >"$SCRATCH/n2.out" 2>"$SCRATCH/n2.err"
start2="$(ls "$BATON_ACCOUNTS_ROOT/.runs"/*.start 2>/dev/null | head -1)"
scenario_check "a receipt written with the guard ON carries bypassed=no" \
  $(grep -q '^bypassed=no' "$start2" 2>/dev/null; echo $?)
scenario_check "a guarded run left no bypass trace on disk" \
  $([ ! -e "$(baton_lock_dir)/bypass.log" ]; echo $?)

cleanup_root
scenario_end
