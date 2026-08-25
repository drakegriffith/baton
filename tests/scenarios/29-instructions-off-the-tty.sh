#!/usr/bin/env bash
# Issue #2 root cause 2: "Watcher output lands in a tty it does not own."
#
# What actually happened on 2026-08-25 (see the PR body): during the auth
# cascade pick_live() walked three accounts, every one of them classified
# AUTH, and its AUTH branch printed a COMPLETE, RUNNABLE command line
# ("run: baton <name>  then /login") once per account onto stderr -- which in
# an interactive `baton` / `baton --night` is the operator's own terminal,
# the same one the `claude` child is drawing in. Three runnable commands
# appeared at once; two were run; two processes attached to the same shared
# projects/ tree and one session was lost.
#
# So there are two distinct claims to prove, and this scenario proves both:
#   (1) nothing baton emits reaches the CONTROLLING TERMINAL when stdout and
#       stderr are redirected -- i.e. no /dev/tty write anywhere; and
#   (2) no runnable command line reaches stdout or stderr at all, because a
#       redirect is the operator's choice and the interactive case (no
#       redirect) is exactly the case that burned. Instructions live in the
#       handoff log; the streams get a non-runnable pointer to it.
#
# Absence-is-not-evidence discipline: "the terminal received nothing" is only
# meaningful if the harness could have SEEN something. Two positive controls
# guard that -- a deliberate /dev/tty write through the same pty harness
# (proves the capture works) and a count of baton output lines actually
# inspected (proves the code under test ran and spoke). Zero inspected
# subjects exits 2 = could-not-inspect, which is NOT a pass.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "29-instructions-off-the-tty"
fresh_root
add_account d

# Every account answers "Not logged in" so pick_live() walks all three and
# the AUTH branch fires three times in ONE process -- the cascade shape from
# the incident, reproduced without needing two processes.
for acct in a b d; do
  write_behavior "$acct" <<'EOF'
DEFAULT_STDOUT="Not logged in. Please run /login"
EOF
done
# Clear the alive cache or pick_live short-circuits and never probes.
rm -f "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b" "$BATON_ACCOUNTS_ROOT/.alive/d"

HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"

# --- the pty harness -------------------------------------------------------
# run_under_pty NAME ARGS... -- run `baton ARGS...` inside a real pseudo
# terminal, with baton's own stdout and stderr redirected to files. Anything
# that shows up in the typescript therefore did NOT come through stdout or
# stderr: it was written straight to the controlling terminal.
run_under_pty() {
  local tag="$1"; shift
  local runner="$SCRATCH/run-$tag.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf '"%s" %s >"%s" 2>"%s"\n' "$BATON_BIN" "$*" "$SCRATCH/$tag.out" "$SCRATCH/$tag.err"
    printf 'echo "$?" > "%s"\n' "$SCRATCH/$tag.exit"
  } > "$runner"
  script -q "$SCRATCH/$tag.pty" bash "$runner" >/dev/null 2>&1 </dev/null
}

# pty_noise_stripped FILE -- the typescript minus the end-of-session marker
# `script` itself writes when the pty closes. On macOS that marker is the
# LITERAL two characters "^D" (caret, capital D -- not byte 0x04) followed by
# backspaces, which is why a byte-level `tr -d '\004'` does not remove it and
# a printable-character filter alone does not either. Strip that marker and
# any control bytes, then keep only lines that still hold something a human
# could read: "the terminal received nothing" is a claim about readable text.
#
# Over-stripping here would silently make every assertion below vacuous, so
# positive control 1 pushes a known string through this same filter and
# requires it to survive.
pty_noise_stripped() {
  LC_ALL=C sed -e 's/\^D//g' -e 's/[[:cntrl:]]//g' "$1" 2>/dev/null \
    | LC_ALL=C grep -a '[[:print:]]'
}

# count_matching PATTERN FILE -- matching lines in FILE, 0 for a missing one.
# `grep -c` already PRINTS 0 when it matches nothing; it just exits nonzero
# doing it, so chaining `|| echo 0` would emit a second 0 and every later
# `[ "$n" -eq 0 ]` would die on "0\n0" (tests/run.sh line 39 documents the
# same trap).
count_matching() {
  local n
  [ -f "$2" ] || { printf '0'; return 0; }
  n=$(grep -cE "$1" "$2" 2>/dev/null)
  printf '%s' "${n:-0}"
}

# --- positive control 1: the harness can see a controlling-terminal write ---
# If this fails, every "the terminal received nothing" assertion below is
# vacuous and the scenario is measuring its own blindness.
cat > "$SCRATCH/control.sh" <<EOF
#!/usr/bin/env bash
{ echo "CONTROL-STDOUT"; echo "CONTROL-STDERR" >&2; } >"$SCRATCH/control.out" 2>"$SCRATCH/control.err"
echo "CONTROL-STRAIGHT-TO-TTY" > /dev/tty 2>/dev/null
EOF
script -q "$SCRATCH/control.pty" bash "$SCRATCH/control.sh" >/dev/null 2>&1 </dev/null
control_saw_tty=$(pty_noise_stripped "$SCRATCH/control.pty" | grep -c 'CONTROL-STRAIGHT-TO-TTY')
scenario_check "positive control: the pty harness captures a /dev/tty write" \
  $([ "$control_saw_tty" -ge 1 ]; echo $?)

# --- the subjects ----------------------------------------------------------
# Both entry points that reach pick_live()'s AUTH branch: the watcher
# (--night, the path issue #2 names) and plain baton (same shared emitter).
run_under_pty night --night
# The --night run just marked all three dead, and a dead account is never
# probed -- so without clearing the marks the plain run would die on the
# first line and never reach the AUTH branch at all. Reset so both entry
# points genuinely walk the same cascade.
rm -f "$BATON_ACCOUNTS_ROOT/.dead/a" "$BATON_ACCOUNTS_ROOT/.dead/b" "$BATON_ACCOUNTS_ROOT/.dead/d"
run_under_pty plain

subjects=0
for tag in night plain; do
  for stream in out err; do
    n=$(count_matching '' "$SCRATCH/$tag.$stream")
    subjects=$((subjects + n))
  done
done

# Silence is not evidence. If baton emitted nothing at all, this scenario
# never reached the code it claims to test, and "no command on the tty" is
# true for the wrong reason.
if [ "$subjects" -eq 0 ]; then
  echo "29-instructions-off-the-tty: COULD NOT INSPECT -- baton produced 0 output lines" >&2
  cleanup_root
  exit 2
fi
scenario_check "inspected more than zero baton output subjects (got $subjects)" \
  $([ "$subjects" -gt 0 ]; echo $?)

# --- positive control 2: the AUTH cascade actually ran ---------------------
# Three accounts must each have been probed and marked dead "auth". Without
# this, a baton that simply died early would pass every assertion below.
auth_marks=0
for acct in a b d; do
  [ "$(dead_reason_of "$acct")" = auth ] && auth_marks=$((auth_marks + 1))
done
scenario_check "positive control: all 3 accounts were probed and marked dead 'auth' (got $auth_marks)" \
  $([ "$auth_marks" -eq 3 ]; echo $?)

# --- claim 1: the controlling terminal received nothing --------------------
for tag in night plain; do
  leaked=$(pty_noise_stripped "$SCRATCH/$tag.pty" | grep -c .)
  scenario_check "$tag: controlling terminal received nothing (got $leaked line(s))" \
    $([ "$leaked" -eq 0 ]; echo $?)
done

# --- claim 2: no runnable command line on stdout or stderr -----------------
# "Runnable" here means specifically: a complete command that would ATTACH A
# PROCESS TO A SESSION -- `baton <account>` with the name already filled in.
# Two deliberate non-targets, so a future reader knows they were weighed
# rather than missed: `baton --revive <name>` carries a placeholder and
# cannot be run as-is, and `baton --status` is read-only, so running it twice
# costs nothing. Neither can clobber session state. `baton a` can, and did.
for tag in night plain; do
  for stream in out err; do
    runnable=$(count_matching 'run: baton |baton [A-Za-z0-9_-]+ +then /login' "$SCRATCH/$tag.$stream")
    scenario_check "$tag.$stream: no runnable relaunch/login command (got $runnable)" \
      $([ "$runnable" -eq 0 ]; echo $?)
  done
done

# --- claim 3: the instruction is not LOST, it is durable -------------------
scenario_check "handoff log exists" $([ -f "$HANDOFF_LOG_PATH" ]; echo $?)
logged=$(count_matching '/login' "$HANDOFF_LOG_PATH")
scenario_check "handoff log carries a /login instruction per AUTH account (got $logged)" \
  $([ "$logged" -ge 3 ]; echo $?)
for acct in a b d; do
  scenario_check "handoff log names account '$acct'" \
    $(grep -q "baton $acct" "$HANDOFF_LOG_PATH" 2>/dev/null; echo $?)
done

# --- claim 4: the streams still point the operator at the log --------------
# Moving the text must not make it invisible: someone watching the terminal
# has to learn that there is something to read, without being handed a
# command to run.
pointed=$(count_matching 'handoff\.log' "$SCRATCH/night.err")
scenario_check "stderr points at the handoff log without printing a command (got $pointed)" \
  $([ "$pointed" -ge 1 ]; echo $?)

cleanup_root
scenario_end
