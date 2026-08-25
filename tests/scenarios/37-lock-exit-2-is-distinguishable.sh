#!/usr/bin/env bash
# `--claim` conflated its own could-not-inspect with the guarded command's exit
# code. Both of these returned 2:
#
#   baton --claim unit:ok -- sh -c 'exit 2'        it ran, and it exited 2
#   baton --claim unit:ok -- ... (sealed lock root) nothing ran at all
#
# Automation wrapping `--claim` therefore could not tell "the work happened and
# reported a failure" from "the guard could not look, so nothing happened" --
# which defeats the entire point of having a could-not-inspect code. Same hole
# in `--redispatch`.
#
# The chosen encoding is a MARKER ON STDERR, not a reserved exit code. The
# tradeoff: a reserved code (125, say) would be unambiguous, but exit 2 for an
# unreadable lock root is written into this issue's acceptance criteria and
# asserted by scenarios 30 and 31, so moving it would mean rewriting the
# criterion to make the implementation convenient. The marker adds a channel
# instead of redefining one, and it fixes a second defect for free: the sealed-
# root arm used to emit ZERO bytes, so the failure was not merely ambiguous, it
# was silent.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "37-lock-exit-2-is-distinguishable"
fresh_root
export BATON_LOCK_PROV=test

MARKER='lock-result=could-not-inspect'
LOCKS="$BATON_ACCOUNTS_ROOT/.locks"

# --- arm 1: the guarded command ran and exited 2 ---------------------------
"$BATON_BIN" --claim unit:ok -- sh -c "echo RAN > '$SCRATCH/ran1'; exit 2" \
  >"$SCRATCH/a1.out" 2>"$SCRATCH/a1.err"
rc1=$?
scenario_check "a guarded command's exit 2 propagates as 2" $([ "$rc1" -eq 2 ]; echo $?)
scenario_check "positive control: the guarded command really did run" \
  $([ -e "$SCRATCH/ran1" ]; echo $?)
scenario_check "a guarded command's exit 2 carries NO lock-layer marker" \
  $(! grep -q "$MARKER" "$SCRATCH/a1.err"; echo $?)

# --- arm 2: the lock layer could not inspect, so nothing ran ---------------
chmod 000 "$LOCKS"
"$BATON_BIN" --claim unit:ok -- sh -c "echo RAN > '$SCRATCH/ran2'" \
  >"$SCRATCH/a2.out" 2>"$SCRATCH/a2.err"
rc2=$?
chmod 755 "$LOCKS"
scenario_check "a could-not-inspect claim still exits 2 (criterion unchanged)" \
  $([ "$rc2" -eq 2 ]; echo $?)
scenario_check "and nothing ran under it" $([ ! -e "$SCRATCH/ran2" ]; echo $?)
scenario_check "a could-not-inspect claim IS marked on stderr" \
  $(grep -q "$MARKER" "$SCRATCH/a2.err"; echo $?)
scenario_check "the marker names the subject it could not inspect" \
  $(grep -q 'unit:ok' "$SCRATCH/a2.err"; echo $?)
# The marker is operator-facing text on a possibly shared stream, so it says
# what happened and never what to type (root cause 2).
scenario_check "the marker hands over no runnable baton command line" \
  $(! grep -qE '(^|[^-])baton +[a-z-]' "$SCRATCH/a2.err"; echo $?)

# The two arms differ. Stated as a comparison rather than as two separate
# rows, because "distinguishable" is a property of the PAIR.
scenario_check "the two exit-2 arms are distinguishable from each other" \
  $([ "$(grep -c "$MARKER" "$SCRATCH/a1.err")" -ne "$(grep -c "$MARKER" "$SCRATCH/a2.err")" ]; echo $?)

# --- the same two arms through --redispatch --------------------------------
"$BATON_BIN" --redispatch never-started-unit -- sh -c "echo RAN > '$SCRATCH/ran3'; exit 2" \
  >"$SCRATCH/b1.out" 2>"$SCRATCH/b1.err"
rc3=$?
scenario_check "--redispatch propagates the replacement's exit 2 as 2" \
  $([ "$rc3" -eq 2 ]; echo $?)
scenario_check "positive control: the replacement really did run" \
  $([ -e "$SCRATCH/ran3" ]; echo $?)
scenario_check "--redispatch does NOT mark a replacement's own exit 2" \
  $(! grep -q "$MARKER" "$SCRATCH/b1.err"; echo $?)

chmod 000 "$LOCKS"
"$BATON_BIN" --redispatch never-started-unit -- sh -c "echo RAN > '$SCRATCH/ran4'" \
  >"$SCRATCH/b2.out" 2>"$SCRATCH/b2.err"
rc4=$?
chmod 755 "$LOCKS"
scenario_check "--redispatch under an unusable lock root exits 2" \
  $([ "$rc4" -eq 2 ]; echo $?)
scenario_check "and launched no replacement" $([ ! -e "$SCRATCH/ran4" ]; echo $?)
scenario_check "--redispatch marks its OWN could-not-inspect on stderr" \
  $(grep -q "$MARKER" "$SCRATCH/b2.err"; echo $?)

cleanup_root
scenario_end
