#!/usr/bin/env bash
# baton#2 acceptance 2: "The watcher never writes to a tty other than its own
# child's; assert by running it with stdout/stderr redirected and confirming
# the controlling terminal receives nothing."
#
# The run happens inside a REAL pseudo-terminal (`script`), because the claim
# is about a controlling terminal and a pipe cannot falsify it: with no tty
# attached, "nothing reached the tty" is true of every program ever written.
# `script`'s capture file is what the terminal received.
#
# This scenario covers the same criterion the open branch for root cause 2
# (fix/2-watcher-tty, scenario 29) covers for the AUTH cascade, and extends it
# to the code THIS branch adds: a lock refusal is also an operator-facing line
# emitted while a full-screen TUI may own the terminal, so it lives under the
# same rule -- a shared stream may say what happened, never what to type.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "34-nothing-reaches-a-foreign-tty"
fresh_root
export BATON_LOCK_PROV=test

# `script -q` writes exactly what the pty received. The only bytes that are
# not the program's are the terminal's own echo of EOF, so control characters
# are stripped before anything is asserted.
pty_text() { tr -d '\000-\010\013\014\016-\037' < "$1" 2>/dev/null; }

# --- the watcher -----------------------------------------------------------
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("all good")
EOF

script -q "$SCRATCH/pty1.log" /bin/sh -c \
  "'$BATON_BIN' --night >'$SCRATCH/night.out' 2>'$SCRATCH/night.err'" \
  </dev/null >/dev/null 2>&1

# POSITIVE CONTROL, first. "The terminal received nothing" is worthless
# unless baton actually ran and actually had something to say; without this
# row a scenario that silently failed to launch anything would read green.
scenario_check "positive control: baton ran and wrote to the redirected stderr" \
  $([ -s "$SCRATCH/night.err" ]; echo $?)
scenario_check "positive control: that output is baton's own announcement" \
  $(grep -q "night mode" "$SCRATCH/night.err"; echo $?)
scenario_check "positive control: the child really had a controlling terminal" \
  $([ -e "$SCRATCH/pty1.log" ]; echo $?)

scenario_check "the controlling terminal received no baton output at all" \
  $(! pty_text "$SCRATCH/pty1.log" | grep -q 'baton'; echo $?)
scenario_check "the controlling terminal received no runnable command" \
  $(! pty_text "$SCRATCH/pty1.log" | grep -qE '(^|[^-])baton +[a-z-]|/login'; echo $?)

cleanup_root

# --- the lock refusal ------------------------------------------------------
fresh_root
export BATON_LOCK_PROV=test

write_behavior a <<'EOF'
STEP_BLOCK=(1 1)
STEP_STDOUT=("holding" "second")
EOF

"$BATON_BIN" a >/dev/null 2>&1 &
HOLDER=$!
waited=0
while [ ! -e "$BATON_ACCOUNTS_ROOT/.locks/login_a.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done
scenario_check "a login lock is held before the refusal is provoked" \
  $([ -e "$BATON_ACCOUNTS_ROOT/.locks/login_a.lock/owner" ]; echo $?)

script -q "$SCRATCH/pty2.log" /bin/sh -c \
  "'$BATON_BIN' a >'$SCRATCH/refused.out' 2>'$SCRATCH/refused.err'" \
  </dev/null >/dev/null 2>&1

scenario_check "positive control: the refusal really was emitted (to the redirect)" \
  $([ -s "$SCRATCH/refused.err" ]; echo $?)
scenario_check "positive control: the refusal names the holder pid" \
  $(grep -q "$HOLDER" "$SCRATCH/refused.err"; echo $?)
scenario_check "the refusal did not reach the controlling terminal" \
  $(! pty_text "$SCRATCH/pty2.log" | grep -q 'baton'; echo $?)
scenario_check "the refusal put no runnable command on the terminal either" \
  $(! pty_text "$SCRATCH/pty2.log" | grep -qE '(^|[^-])baton +[a-z-]|/login'; echo $?)
# ...and it carries no runnable command on ANY stream, shared or not: it names
# a knob, which is a thing to know, not a line to paste.
scenario_check "the refusal text itself is not a runnable command line" \
  $(! grep -qE '(^|[^-])baton +[a-z-]' "$SCRATCH/refused.err"; echo $?)

kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
kill_fake_claude a
cleanup_root
scenario_end
