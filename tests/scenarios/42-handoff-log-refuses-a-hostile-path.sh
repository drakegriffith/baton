#!/usr/bin/env bash
# Review finding (major): handoff_log appended with a plain `>>` redirection,
# which follows symlinks and inherits the caller's umask.
#
# Two consequences, both about a file that exists specifically to be the ONE
# durable place baton's instructions live:
#
#   Redirection. `>>` through a symlink writes to the LINK'S TARGET. A link
#   at .handoff.log pointing at /dev/null makes every instruction vanish
#   silently -- the append SUCCEEDS, so not even the failed-append notice
#   fires -- and a link pointing anywhere else writes baton's account and
#   session details into a file outside the accounts root. A FIFO is worse
#   than either: opening one for write with no reader BLOCKS, and this call
#   sits in the watcher's failover path, so a night would hang instead of
#   handing off.
#
#   Mode. Under the common 022 umask the log is created 0644 -- world
#   readable -- and it names accounts and session ids by design.
#
# The rule: the log path must be a regular file or nothing at all. Anything
# else is refused through the existing once-per-process notice rather than
# written to, and a log baton creates itself is 0600.
#
# What is deliberately NOT done, so it is a decision and not an oversight:
# the accounts ROOT's mode is left alone. Codex's finding asked for 0700
# there too, but baton did not create that directory in the general case and
# re-permissioning a directory the operator owns is a side effect a tool
# reaching for a log file has no business having. Scenario 14 proves the real
# root is untouched; this scenario asserts the root's mode survives a run.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "42-handoff-log-refuses-a-hostile-path"

HOSTILE_TIMEOUT=20

# run_auth_cascade -- a plain `baton` run in which every account probes AUTH,
# so handoff_log is called several times in one process and then once more by
# die_no_live_account. Bounded by a hard alarm: the FIFO case below fails by
# HANGING, and a scenario that hangs reports nothing at all (tests/run.sh
# would record it as "died before scenario_end", which is right but tells
# nobody why).
run_auth_cascade() { # $1 tag
  local tag="$1"
  perl -e 'alarm shift; exec @ARGV' "$HOSTILE_TIMEOUT" \
    "$BATON_BIN" some-arg >"$SCRATCH/$tag.out" 2>"$SCRATCH/$tag.err"
  echo $? > "$SCRATCH/$tag.rc"
}

setup_cascade() {
  for acct in a b; do
    write_behavior "$acct" <<'EOF'
DEFAULT_STDOUT="Not logged in. Please run /login"
EOF
  done
  rm -f "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b"
}

notice_count() { # $1 file
  local n
  [ -f "$1" ] || { printf '0'; return 0; }
  n=$(grep -c 'could not be written' "$1" 2>/dev/null)
  printf '%s' "${n:-0}"
}
raw_shell_errors() { # $1 file
  local n
  [ -f "$1" ] || { printf '0'; return 0; }
  n=$(grep -cE 'accounts\.sh: line [0-9]|Is a directory|Permission denied|Interrupted' "$1" 2>/dev/null)
  printf '%s' "${n:-0}"
}

# --- case 0: the honest path, as a positive control ------------------------
# Every refusal below is an absence ("the target did not gain bytes"). None
# of them means anything unless this case proves baton writes the log at all
# when the path is a plain file.
fresh_root
setup_cascade
LOG="$BATON_ACCOUNTS_ROOT/.handoff.log"
ROOT_MODE_BEFORE=$(stat -f %Lp "$BATON_ACCOUNTS_ROOT")
run_auth_cascade honest
scenario_check "positive control: a plain path gets a handoff log" $([ -f "$LOG" ]; echo $?)
scenario_check "positive control: it holds more than zero lines (got $(stream_lines "$LOG"))" \
  $([ "$(stream_lines "$LOG")" -gt 0 ]; echo $?)
scenario_check "positive control: nothing complained about the honest path" \
  $([ "$(notice_count "$SCRATCH/honest.err")" -eq 0 ]; echo $?)

# --- claim 1: a log baton creates is 0600 ----------------------------------
# The suite runs under whatever umask the operator has; 0644 under the common
# 022 is exactly the finding.
scenario_check "a handoff log baton created is mode 600 (got $(stat -f %Lp "$LOG"))" \
  $([ "$(stat -f %Lp "$LOG")" = "600" ]; echo $?)

# --- claim 2: the accounts root's mode is NOT changed as a side effect -----
scenario_check "the accounts root's mode is untouched by the run (was $ROOT_MODE_BEFORE, now $(stat -f %Lp "$BATON_ACCOUNTS_ROOT"))" \
  $([ "$(stat -f %Lp "$BATON_ACCOUNTS_ROOT")" = "$ROOT_MODE_BEFORE" ]; echo $?)
cleanup_root

# --- claim 3: a symlink out of the accounts root is refused, not followed --
fresh_root
setup_cascade
OUTSIDE="$SCRATCH/outside.log"
: > "$OUTSIDE"
ln -s "$OUTSIDE" "$BATON_ACCOUNTS_ROOT/.handoff.log"
run_auth_cascade symlink
scenario_check "a symlinked log target gained no bytes (got $(wc -c < "$OUTSIDE" | tr -d ' '))" \
  $([ "$(wc -c < "$OUTSIDE" | tr -d ' ')" -eq 0 ]; echo $?)
scenario_check "the symlink itself was not replaced by a regular file" \
  $([ -L "$BATON_ACCOUNTS_ROOT/.handoff.log" ]; echo $?)
scenario_check "the operator is told exactly once (got $(notice_count "$SCRATCH/symlink.err"))" \
  $([ "$(notice_count "$SCRATCH/symlink.err")" -eq 1 ]; echo $?)
scenario_check "the refusal leaks no raw shell error" \
  $([ "$(raw_shell_errors "$SCRATCH/symlink.err")" -eq 0 ]; echo $?)
scenario_check "the refusal hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/symlink.err")" -eq 0 ]; echo $?)
cleanup_root

# --- claim 4: a symlink to /dev/null is the SILENT loss, and is refused ----
# This is the case a naive "did the append succeed?" check cannot catch: the
# write to /dev/null succeeds, so without a type check baton reports nothing
# wrong while every instruction of the night disappears.
fresh_root
setup_cascade
ln -s /dev/null "$BATON_ACCOUNTS_ROOT/.handoff.log"
run_auth_cascade devnull
scenario_check "a log symlinked to /dev/null is refused out loud, not written silently (got $(notice_count "$SCRATCH/devnull.err"))" \
  $([ "$(notice_count "$SCRATCH/devnull.err")" -eq 1 ]; echo $?)
scenario_check "/dev/null was not replaced or unlinked" $([ -c /dev/null ]; echo $?)
cleanup_root

# --- claim 5: a FIFO does not hang the watcher's failover path -------------
fresh_root
setup_cascade
mkfifo "$BATON_ACCOUNTS_ROOT/.handoff.log"
run_auth_cascade fifo
fifo_rc=$(cat "$SCRATCH/fifo.rc" 2>/dev/null || echo 999)
# perl's alarm kills with SIGALRM -> 142. Anything else means baton returned
# on its own, which is the whole claim.
scenario_check "a FIFO log path did not block baton (rc $fifo_rc, not 142)" \
  $([ "$fifo_rc" -ne 142 ]; echo $?)
scenario_check "and the operator is told once (got $(notice_count "$SCRATCH/fifo.err"))" \
  $([ "$(notice_count "$SCRATCH/fifo.err")" -eq 1 ]; echo $?)
rm -f "$BATON_ACCOUNTS_ROOT/.handoff.log"
cleanup_root

scenario_end
