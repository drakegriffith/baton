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

# `tty` runs inside the same pty, before baton, so the capture file carries
# proof that a controlling terminal was actually allocated. The row this
# replaces was `[ -e pty1.log ]`, which `script` satisfies whether or not it
# ever got a terminal -- a positive control that could not fail is not one.
script -q "$SCRATCH/pty1.log" /bin/sh -c \
  "tty; '$BATON_BIN' --night >'$SCRATCH/night.out' 2>'$SCRATCH/night.err'" \
  </dev/null >/dev/null 2>&1

# POSITIVE CONTROL, first. "The terminal received nothing" is worthless
# unless baton actually ran and actually had something to say; without this
# row a scenario that silently failed to launch anything would read green.
scenario_check "positive control: baton ran and wrote to the redirected stderr" \
  $([ -s "$SCRATCH/night.err" ]; echo $?)
scenario_check "positive control: that output is baton's own announcement" \
  $(grep -q "night mode" "$SCRATCH/night.err"; echo $?)
scenario_check "positive control: a real controlling terminal was allocated" \
  $(pty_text "$SCRATCH/pty1.log" | grep -qE '/dev/(tty|pts)'; echo $?)

scenario_check "the controlling terminal received no baton output at all" \
  $(! pty_text "$SCRATCH/pty1.log" | grep -q 'baton'; echo $?)
scenario_check "the controlling terminal received no runnable command" \
  $(! pty_text "$SCRATCH/pty1.log" | grep -qE '(^|[^-])baton +[a-z-]|/login'; echo $?)

cleanup_root

# --- the AUTH cascade ------------------------------------------------------
# The mechanism this issue's root cause 2 actually names: `pick_live`'s AUTH
# branch warns ONCE PER RANKED ACCOUNT, so three not-logged-in accounts turn
# one actionable line into three, on a stream the operator is holding all
# night. Scenario 34 never exercised it, which is why it read green on a main
# that still emits a runnable `baton <name>` line per failing account.
#
# WHAT IS ASSERTED HERE, AND WHAT IS DELIBERATELY NOT. The tty rows below are
# criterion 2 as the issue words it, and they are exercised against the real
# cascade for the first time. The stronger row -- "night.err carries no
# runnable command line" -- is NOT added, and this is a disclosure, not an
# oversight: it fails on main today, its fix is PR #4 (`lib/accounts.sh:209`
# plus a durable handoff log), and that file is explicitly out of scope for
# this commit. Adding the row here would land a permanently red assertion for
# a defect this commit is forbidden to fix. The multiplication is instead
# asserted as a COUNT below, so the size of the thing PR #4 has to remove is
# recorded in the suite rather than in prose.
fresh_root
export BATON_LOCK_PROV=test
add_account c
# The .alive marks fresh_root plants are a 15-minute ALIVE cache: with them in
# place pick_live never probes, so the AUTH branch is never reached and the
# cascade this section exists to exercise never fires.
rm -f "$BATON_ACCOUNTS_ROOT/.alive"/*

for acct in a b c; do
  write_behavior "$acct" <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("Invalid API key . Please run /login" "Invalid API key . Please run /login")
EOF
done

script -q "$SCRATCH/pty3.log" /bin/sh -c \
  "tty; '$BATON_BIN' --night >'$SCRATCH/auth.out' 2>'$SCRATCH/auth.err'" \
  </dev/null >/dev/null 2>&1

scenario_check "positive control: a real controlling terminal was allocated" \
  $(pty_text "$SCRATCH/pty3.log" | grep -qE '/dev/(tty|pts)'; echo $?)
scenario_check "positive control: the AUTH cascade really fired" \
  $(grep -qi 'NOT LOGGED IN' "$SCRATCH/auth.err"; echo $?)
# The multiplication itself, as a count: more than one actionable line for one
# operator action. This is the defect PR #4 removes; recording the number is
# how a future green stays honest about which fix produced it.
scenario_check "positive control: the cascade multiplied across accounts (>1 line)" \
  $([ "$(grep -ci 'NOT LOGGED IN' "$SCRATCH/auth.err")" -gt 1 ]; echo $?)
scenario_check "the AUTH cascade reached no controlling terminal" \
  $(! pty_text "$SCRATCH/pty3.log" | grep -q 'baton'; echo $?)
scenario_check "the AUTH cascade put no runnable command on the terminal" \
  $(! pty_text "$SCRATCH/pty3.log" | grep -qE '(^|[^-])baton +[a-z-]|/login'; echo $?)

kill_fake_claude a
kill_fake_claude b
kill_fake_claude c
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
while [ ! -e "$(baton_lock_dir)/login.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done
scenario_check "a login lock is held before the refusal is provoked" \
  $([ -e "$(baton_lock_dir)/login.lock/owner" ]; echo $?)

script -q "$SCRATCH/pty2.log" /bin/sh -c \
  "tty; '$BATON_BIN' a >'$SCRATCH/refused.out' 2>'$SCRATCH/refused.err'" \
  </dev/null >/dev/null 2>&1

scenario_check "positive control: a real controlling terminal was allocated" \
  $(pty_text "$SCRATCH/pty2.log" | grep -qE '/dev/(tty|pts)'; echo $?)

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
