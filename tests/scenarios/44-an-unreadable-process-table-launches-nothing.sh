#!/usr/bin/env bash
# Round-3 delta finding 2. run_watched's start-up liveness check asks `ps`
# whether the child it just forked is still there. A `ps` that is denied,
# missing, or broken answers exactly like a `ps` reporting an absent pid:
# empty output, nonzero exit. The check then concluded "the child is gone",
# fell through to a blocking `wait`, and silently skipped transcript watching
# for the whole night -- so the limit line that is supposed to trigger a
# handoff would never be seen, and the run would look like a clean session.
#
# This is the absence-is-not-evidence rule applied to baton itself rather
# than to its tests: a probe that CANNOT ASK must report could-not-inspect,
# never report an empty board. lib/runs.sh has carried the positive control
# for this since baton#3 (`ps -p 1`, the one pid that exists on every machine
# this runs on); the watcher simply never called it.
#
# The contract asserted here: an unusable process table is exit 2, it is
# stated on stderr in a form automation can grep, and NOTHING IS LAUNCHED --
# the failure happens before the fork, not after it.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "44-an-unreadable-process-table-launches-nothing"
fresh_root

# A `ps` that fails the way a sandboxed or restricted one does: nonzero, no
# output. First on PATH, so baton's own `ps -p 1` control hits it too.
mkdir -p "$SCRATCH/shim"
cat > "$SCRATCH/shim/ps" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SCRATCH/shim/ps"
export PATH="$SCRATCH/shim:$PATH"

# Positive control for the shim itself: if `ps` still works here, every
# assertion below is about a condition that was never created.
if ps -p 1 -o args= >/dev/null 2>&1; then
  echo "44: COULD NOT INSPECT -- the ps shim did not take effect" >&2
  cleanup_root
  exit 2
fi

before=$(invocation_count a)
"$BATON_BIN" --night >"$SCRATCH/nops.out" 2>"$SCRATCH/nops.err"
rc=$?

scenario_check "an unusable process table exits 2, not 0 and not 1 (got $rc)" \
  $([ "$rc" -eq 2 ]; echo $?)
scenario_check "stderr carries a greppable could-not-inspect marker" \
  $(grep -q 'watch-result=could-not-inspect' "$SCRATCH/nops.err"; echo $?)
scenario_check "the marker says why" \
  $(grep -q 'reason=' "$SCRATCH/nops.err"; echo $?)

# The load-bearing claim: it refused BEFORE forking. A watcher that cannot
# watch must not start a child it would then lose track of.
scenario_check "no child was launched (invocations $before -> $(invocation_count a))" \
  $([ "$(invocation_count a)" -eq "$before" ]; echo $?)
scenario_check "no launch receipt was written" \
  $([ -z "$(ls "$BATON_ACCOUNTS_ROOT/.runs" 2>/dev/null)" ]; echo $?)
# `grep -c` PRINTS 0 and EXITS nonzero on no match, so a `|| echo 0` here
# emits a SECOND 0 and the -eq below dies on "0\n0" (tests/run.sh line 39
# documents the same trap; this row was written with the bug and caught by it).
launched_lines=$(grep -c 'LAUNCHED:' "$BATON_ACCOUNTS_ROOT/.handoff.log" 2>/dev/null)
scenario_check "no LAUNCHED line was written (got ${launched_lines:-0})" \
  $([ "${launched_lines:-0}" -eq 0 ]; echo $?)

# Exit 2 is a distinct answer, not a dressed-up success or a generic die.
scenario_check "stderr does not claim a clean session" \
  $(! grep -qi 'clean exit\|session ended normally' "$SCRATCH/nops.err"; echo $?)
scenario_check "stderr hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/nops.err")" -eq 0 ]; echo $?)
scenario_check "positive control: the predicate can see a leak" \
  $([ "$(predicate_positive_control "$SCRATCH/predicate-control.txt")" -eq 3 ]; echo $?)

cleanup_root
scenario_end
