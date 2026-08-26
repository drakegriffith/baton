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

# --- claim 2: no runnable command line on stdout, stderr, or the terminal --
#
# This claim used to be spelled 'run: baton |baton [A-Za-z0-9_-]+ +then
# /login' -- the ONE sentence pick_live's AUTH branch printed. Measured
# against the three leak shapes that have actually mattered, it caught 1 of
# 3: it recognised "run:  baton a   then /login" but not `baton a --resume
# abc123` (the literal shape the 2026-08-25 incident put in Drake's
# terminal, which reached stderr through the UNKNOWN branch's verbatim probe
# relay) and not `baton --revive b`. A test named "no runnable command
# reaches the tty" that knows only one sentence is not testing its own name;
# it is pinning a string.
#
# The predicate now lives once, in tests/fixtures/lib.sh
# (RUNNABLE_BATON_RE + runnable_command_lines), whitespace-normalised
# because "baton   a" pastes exactly as well as "baton a". The two former
# "deliberate non-targets" are now targets, and that inversion is a decision,
# not drift: `baton --revive <name>` was excused as carrying a placeholder,
# but `baton --revive b` with the name filled in is what die_no_live_account
# actually printed; and `baton --status` was excused as read-only, which is
# an argument about consequences, not about whether an unbidden command line
# appeared in a terminal. Root cause 2 is the second thing.
#
# It is applied to all three captures per entry point -- stdout, stderr, and
# the pty typescript (the controlling terminal itself) -- so a future change
# that moves a leak from one stream to another cannot slip past.
pty_noise_stripped "$SCRATCH/night.pty" > "$SCRATCH/night.tty" 2>/dev/null || true
pty_noise_stripped "$SCRATCH/plain.pty" > "$SCRATCH/plain.tty" 2>/dev/null || true

# Positive control: the predicate can see a leak at all. Without this, every
# assertion in this section passes for a predicate that matches nothing.
control_hits=$(predicate_positive_control "$SCRATCH/predicate-control.txt")
scenario_check "positive control: the predicate matches all 3 known leak shapes (got $control_hits)" \
  $([ "$control_hits" -eq 3 ]; echo $?)

# Silence is not evidence, applied to the PREDICATE and not only to baton: a
# "no runnable command" result over zero lines found nothing because it read
# nothing. The number of lines the predicate was actually applied to is
# asserted before any of its negatives are believed.
predicate_scanned=0
for tag in night plain; do
  for stream in out err tty; do
    predicate_scanned=$((predicate_scanned + $(stream_lines "$SCRATCH/$tag.$stream")))
  done
done
if [ "$predicate_scanned" -eq 0 ]; then
  echo "29-instructions-off-the-tty: COULD NOT INSPECT -- the runnable-command predicate read 0 lines" >&2
  cleanup_root
  exit 2
fi
scenario_check "the runnable-command predicate read more than zero lines (got $predicate_scanned)" \
  $([ "$predicate_scanned" -gt 0 ]; echo $?)

for tag in night plain; do
  for stream in out err tty; do
    runnable=$(runnable_command_lines "$SCRATCH/$tag.$stream")
    scenario_check "$tag.$stream: no runnable baton command line (got $runnable)" \
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

# --- claim 5: an UNWRITABLE log fails quietly and audibly, not noisily -----
# The whole point of this change is that stderr is a stream the operator (and
# a full-screen TUI) share, so the code that moves text OFF it must not put
# raw shell diagnostics back ON it. `printf ... >> "$LOG" 2>/dev/null` does
# exactly that: the 2>/dev/null binds to printf, while bash reports a FAILED
# REDIRECTION on the shell's own stderr before printf ever runs -- one
# "accounts.sh: line N: ...: Is a directory" per account, per poll, all night.
# That is the same per-iteration shell-error cascade lib/watch.sh's night_knobs
# header documents as measured harm.
#
# But silence alone is the wrong contract: a failed append means the COMMAND
# IS LOST, and stderr no longer carries it either. So the requirement is
# three-part -- no raw shell error, no repetition, and exactly one plain-
# language notice that the instructions were not recorded.
rm -f "$BATON_ACCOUNTS_ROOT/.dead/a" "$BATON_ACCOUNTS_ROOT/.dead/b" "$BATON_ACCOUNTS_ROOT/.dead/d"
rm -f "$HANDOFF_LOG_PATH"
mkdir -p "$HANDOFF_LOG_PATH"   # a directory can never be appended to
"$BATON_BIN" --night >"$SCRATCH/broken.out" 2>"$SCRATCH/broken.err"

broken_subjects=$(count_matching '' "$SCRATCH/broken.err")
if [ "$broken_subjects" -eq 0 ]; then
  echo "29-instructions-off-the-tty: COULD NOT INSPECT -- unwritable-log run emitted 0 lines" >&2
  cleanup_root
  exit 2
fi
# Positive control for THIS section: the cascade must actually have run again.
reauth=0
for acct in a b d; do
  [ "$(dead_reason_of "$acct")" = auth ] && reauth=$((reauth + 1))
done
scenario_check "positive control: unwritable-log run still walked all 3 accounts (got $reauth)" \
  $([ "$reauth" -eq 3 ]; echo $?)

rawerr=$(count_matching 'accounts\.sh: line [0-9]|Is a directory|Permission denied' "$SCRATCH/broken.err")
scenario_check "unwritable log leaks no raw shell error to stderr (got $rawerr)" \
  $([ "$rawerr" -eq 0 ]; echo $?)

notice=$(count_matching 'could not be written' "$SCRATCH/broken.err")
scenario_check "operator is told once that instructions were not recorded (got $notice)" \
  $([ "$notice" -eq 1 ]; echo $?)

# The WORDING, not just the fact. This row used to match only "could not be
# written", which the old overclaiming notice ("this run's instructions were
# NOT recorded anywhere. Fix that path to get them back") also contained --
# so the test that is supposed to pin the corrected message would have passed
# the message it was correcting. A claim about wording has to assert the
# words that carry the claim: that ONE line is lost, and that later lines may
# still land. Both halves, so neither can be dropped.
scenario_check "the notice scopes the loss to this one line (got $(count_matching 'this one line is lost' "$SCRATCH/broken.err"))" \
  $([ "$(count_matching 'this one line is lost' "$SCRATCH/broken.err")" -eq 1 ]; echo $?)
scenario_check "the notice says later lines may still land (got $(count_matching 'Later lines may still land' "$SCRATCH/broken.err"))" \
  $([ "$(count_matching 'Later lines may still land' "$SCRATCH/broken.err")" -eq 1 ]; echo $?)
# And the retired overclaim never comes back.
scenario_check "the notice no longer claims nothing was recorded anywhere" \
  $([ "$(count_matching 'NOT recorded anywhere|to get them back' "$SCRATCH/broken.err")" -eq 0 ]; echo $?)

# The same broadened predicate, on the run where the durable channel is
# GONE. This is the case most likely to tempt a future maintainer into
# printing the instruction after all ("the log is broken, so where else
# would it go?"), which is why it is asserted separately from claim 2 rather
# than folded into it.
noticecmd=$(runnable_command_lines "$SCRATCH/broken.err")
scenario_check "the unwritable-log run is itself not pasteable (got $noticecmd)" \
  $([ "$noticecmd" -eq 0 ]; echo $?)
scenario_check "the unwritable-log run's stderr was more than zero lines (got $broken_subjects)" \
  $([ "$broken_subjects" -gt 0 ]; echo $?)

cleanup_root
scenario_end
