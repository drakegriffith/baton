#!/usr/bin/env bash
# accounts -- per-account state (tally, dead/alive marks, weight) and the
# ranked-selection + probing policy baton's CLI dispatch drives. Depends on
# detect (classify_text, via probe() and mark_dead_for_class); never the
# reverse. Exposes the public surface `watch` is allowed to call: ranked(),
# is_dead(), mark_dead(), mark_dead_for_class(), probe(), pick_live(),
# set_envargs(), bump(), die_no_live_account(), is_uint(), is_unum(),
# is_account(), enumerate_accounts(), candidates_exist(), handoff_log(),
# handoff_log_quoted(). The last two are listed because watch.sh calls them
# and the list is the contract: night_mode records what it is about to try
# and run_watched records what actually launched, so the log is written from
# both files by design, not by accident. Everything else here (tally
# file format, dead-file format) is private and must stay that way --
# watch.sh never opens these files directly.
#
# ROOT honors BATON_ACCOUNTS_ROOT (default $HOME/.claude-accounts, unchanged)
# per D7 -- the one override point that keeps every test off the real
# accounts root.
#
# Input validation lives here too (is_account, is_uint, is_unum): every
# operator-supplied name or number in this program becomes a state file
# path, a CLAUDE_CONFIG_DIR, or an argument to `$(( ))`, and those three are
# where a typo stops being a typo. They are part of the public surface --
# watch.sh validates --night's env knobs with them, baton's dispatch checks
# account names with them.

ROOT="${BATON_ACCOUNTS_ROOT:-$HOME/.claude-accounts}"
TALLY="$ROOT/.tally"
LAST="$ROOT/.last"
DEADDIR="$ROOT/.dead"
ALIVEDIR="$ROOT/.alive"
PROBECWD="$ROOT/.probe"
HANDOFF_LOG="$ROOT/.handoff.log"
ALIVE_TTL=900
PROBE_TIMEOUT=90
DEFAULT_DEAD=5h

# --- the handoff log: the one channel allowed to carry a runnable command ---
#
# README has always promised "you read the handoff log in the morning" and
# nothing ever wrote one. It exists now because stdout and stderr are NOT
# that channel and cannot be made into it: under `baton --night` the watcher
# and its `claude` child share one terminal (run_watched backgrounds the
# child without redirecting it), so every warn() lands in the terminal a
# human is actively working in.
#
# Measured cost of ignoring that, 2026-08-25 (issue #2): pick_live()'s AUTH
# branch printed a COMPLETE, RUNNABLE command line -- "run: baton <name>
# then /login" -- once per account. Three accounts went AUTH inside 14
# minutes, so three runnable commands appeared at once in one terminal, two
# were run, and two processes attached to the same session through the shared
# projects/ symlink. One session was lost. Nothing was wrong with any single
# line; the bug is that a loop's fan-out multiplied an actionable line and
# the stream it went to was the operator's hands.
#
# The rule this establishes: anything a human could select and press enter on
# goes to the handoff log and NOWHERE else. A shared stream may say that
# something happened, and where to read about it, but never what to type.
#
# handoff_log MSG -- append one timestamped line to the handoff log.
#
# On SUCCESS it writes to no stream at all: not stdout, not stderr, not
# /dev/tty. That is the contract the rest of this file depends on.
#
# The braces are load-bearing, not style. `printf ... >> "$LOG" 2>/dev/null`
# binds the 2>/dev/null to PRINTF, but a `>>` that cannot be opened fails
# before printf is ever reached, and bash reports that failed redirection on
# the SHELL's stderr -- with an "accounts.sh: line N:" prefix. Measured: with
# the log path unwritable, an AUTH cascade emitted one
# "accounts.sh: line 63: ...: Is a directory" per account, straight into the
# terminal this function exists to keep clean, leaking an internal file:line
# on the way. `{ ...; } 2>/dev/null` puts the redirection INSIDE the scope
# being silenced and is genuinely quiet. Both "Is a directory" and
# "Permission denied" were reproduced and are covered by scenario 29.
#
# On FAILURE it is quiet but not silent, and the difference matters: a failed
# append means the operator's instruction is GONE. It is not on stderr (this
# whole change moved it off), and it is not in the log (the append failed),
# so silence would be data loss no one is told about. So exactly ONE
# plain-language notice is emitted per process, naming the path and what was
# lost. Once, not per call: the caller is a loop over accounts, and a
# per-iteration notice would rebuild the very cascade this change removed.
# The notice deliberately contains no command -- being unable to record an
# instruction is not a reason to start printing instructions.
#
# The notice says what it can actually support: THIS line is lost, and later
# lines may still land if the path is fixed. It used to say "this run's
# instructions were NOT recorded anywhere. Fix that path to get them back",
# which claims both more and less than is true -- earlier lines in the same
# process may well have landed, and fixing the path recovers nothing that was
# already dropped.
HANDOFF_LOG_BROKEN=""
HANDOFF_LOG_WHY=""

# _handoff_log_usable -- true when $HANDOFF_LOG is a path this program is
# willing to append to, creating it 0600 if it does not exist. Sets
# HANDOFF_LOG_WHY on refusal.
#
# `>>` follows symlinks and inherits the caller's umask, and both were
# measured (scenario 42) rather than argued:
#   - a link at .handoff.log pointing outside the accounts root took 424
#     bytes of account and session detail with it;
#   - a link to /dev/null lost every instruction of the night SILENTLY --
#     the append succeeds, so the failed-append notice above never fires,
#     which is the one failure shape a "did the write work?" check cannot
#     see and the reason this is a TYPE check and not an error check;
#   - a FIFO blocked baton for the full 20-second test alarm, because
#     opening one for write with no reader waits forever, and this call sits
#     in the watcher's failover path;
#   - the created file was 0644 under the common 022 umask, world-readable,
#     holding account names and session ids.
#
# The symlink test comes first because `-e` FOLLOWS the link: a link to a
# regular file passes a type check and is then written through, which is
# exactly the redirection half of the problem.
_handoff_log_usable() {
  if [ -L "$HANDOFF_LOG" ]; then
    # Wording note: not "and baton does not append through one". The
    # runnable-command predicate flags `baton <word>` anywhere on a shared
    # stream, and it is right to -- prose that opens a clause with the
    # program's name reads as a command line to a skimming eye, which is the
    # entire mechanism of root cause 2. Operator-facing text says "baton"
    # only as `baton:`, the message prefix.
    HANDOFF_LOG_WHY="that path is a symbolic link, which is never appended through"
    return 1
  fi
  if [ -e "$HANDOFF_LOG" ]; then
    [ -f "$HANDOFF_LOG" ] && return 0
    HANDOFF_LOG_WHY="that path exists but is not a regular file"
    return 1
  fi
  # Created with `>>`, not `:>`, so two nights racing to create the log
  # cannot truncate each other's. umask 077 in the subshell is what makes it
  # 0600, and it applies to the open the redirection performs.
  #
  # Only on creation. An existing log is left at whatever mode it has:
  # tightening a file the operator may have deliberately opened up is a
  # side effect, and the disclosure this closes is baton's own default.
  ( umask 077; : >> "$HANDOFF_LOG" ) 2>/dev/null && return 0
  HANDOFF_LOG_WHY="that path could not be created"
  return 1
}

# _handoff_log_ident -- the path's identity as LSTAT sees it (device:inode),
# empty when it cannot be read. BSD `stat` does not follow symlinks without
# -L, which is the semantics needed: a link must read as itself, not as its
# target. The value is handed to _handoff_append, which re-checks it against
# the file it actually opened.
_handoff_log_ident() { stat -f '%d:%i' "$HANDOFF_LOG" 2>/dev/null; }

# _handoff_append IDENT LINE -- append one line to $HANDOFF_LOG, or refuse.
#   0  written
#   3  refused: the path is not the regular file that was checked
#   2  could not open it at all
#
# WHY THIS IS PYTHON AND NOT `>>`. Every bash spelling of this has the same
# hole: the check and the open are two syscalls, and whatever is dropped into
# the gap between them is what gets written to. The previous round narrowed
# the gap by re-checking the path AFTER the append -- which a
# swap-append-restore sequence walks straight through, because by the time
# the second check runs the path looks exactly as it did before. Narrowing a
# race is not closing one.
#
# O_NOFOLLOW closes it, by moving the decision INTO the open: the kernel
# refuses to traverse a final-component symlink, so there is no longer a
# moment between deciding and writing. Bash cannot ask for that flag -- no
# redirection operator, no `exec` flag, no builtin -- and python3 is already
# a declared dependency (README "Requires", and detect.sh's
# parse_reset_epoch has always used it). fstat on the returned descriptor
# then confirms the file that was actually opened is regular and is the same
# inode the pre-check looked at, so a swap to a different regular file is
# refused too.
#
# O_NONBLOCK is there for FIFOs specifically: opening one for write with no
# reader blocks forever, and this call sits in the watcher's failover path.
# The flag turns that hang into ENXIO. The bash pre-check already rejects
# FIFOs; this is the copy that still holds when the FIFO arrives during the
# race window.
#
# Cost, accepted deliberately: one python3 process per logged line, roughly
# 30-50ms. A night writes a handful of lines, so this buys a closed race for
# a latency nobody is waiting on. If that ever stops being true the answer is
# a single long-lived writer, not a return to `>>`.
#
# stderr is discarded because a traceback on a shared stream is exactly what
# this whole file exists to prevent; the exit code carries the outcome.
_handoff_append() {
  BATON_HL_PATH="$HANDOFF_LOG" BATON_HL_IDENT="${1-}" BATON_HL_LINE="${2-}" python3 -c '
import errno, os, stat, sys
path = os.environ["BATON_HL_PATH"]
want = os.environ["BATON_HL_IDENT"]
line = os.environ["BATON_HL_LINE"]
try:
    fd = os.open(path,
                 os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                 0o600)
except OSError as e:
    # ELOOP: a symlink, refused by O_NOFOLLOW. ENXIO: a FIFO with no reader,
    # which O_NONBLOCK turned from a hang into an error. Both are "this is
    # not the file baton agreed to write to", not "the disk is full".
    sys.exit(3 if e.errno in (errno.ELOOP, errno.ENXIO) else 2)
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(3)
    if want and want != "%d:%d" % (st.st_dev, st.st_ino):
        sys.exit(3)
    os.write(fd, (line + "\n").encode("utf-8", "replace"))
finally:
    os.close(fd)
sys.exit(0)
' 2>/dev/null
}

handoff_log() {
  # Once refused, stay refused and stay quiet: the caller is a loop over
  # accounts, and re-testing (or re-reporting) per iteration would rebuild
  # the cascade this whole change removed.
  [ -n "$HANDOFF_LOG_BROKEN" ] && return 0
  # A root baton creates is 0700: it holds every account's config dir, and
  # the 0755 the common 022 umask gives lists them to anyone on the box.
  # Creation only -- an existing root's mode belongs to the operator.
  ( umask 077; mkdir -p "$ROOT" ) 2>/dev/null
  HANDOFF_LOG_WHY="that path could not be appended to"
  local ident_before rc
  if _handoff_log_usable; then
    ident_before=$(_handoff_log_ident)
    _handoff_append "$ident_before" "$(date '+%Y-%m-%d %H:%M:%S') baton: $*"; rc=$?
    case "$rc" in
      0) return 0 ;;
      3) HANDOFF_LOG_WHY="that path is no longer the regular file baton checked, so nothing was written to it" ;;
      *) HANDOFF_LOG_WHY="that path could not be opened for appending" ;;
    esac
  fi
  HANDOFF_LOG_BROKEN=1
  echo "baton: WARNING -- this line could not be written to the handoff log $HANDOFF_LOG ($HANDOFF_LOG_WHY), so this one line is lost. Later lines may still land there once that path is fixed. Check account status for the current state. (Shown once.)" >&2
  return 0
}

# handoff_log_quoted LABEL TEXT -- record text baton did not write itself
# (a probe's own output) in the handoff log, as QUOTED DATA.
#
# Three properties, each of which was a bug somewhere:
#   - every line is prefixed `| `, so no line of the log is a line someone
#     can select and run; the timestamp already prevents that, and this makes
#     it visible rather than incidental;
#   - the label says out loud that the quoted text is not an instruction,
#     because the reader of a handoff log at 8am is reading a file whose
#     entire purpose is to tell them what to type;
#   - it is BOUNDED. Probe output is whatever the CLI printed, which on a
#     captive-portal network is an HTML page. An unbounded quote would let a
#     foreign response set the size of baton's durable log.
HANDOFF_QUOTE_MAX_LINES=20
HANDOFF_QUOTE_MAX_COLS=500
handoff_log_quoted() {
  local label="$1" text="$2" line n=0
  handoff_log "$label. Its own output follows, quoted as data -- do not run it:"
  while IFS= read -r line; do
    n=$((n + 1))
    if [ "$n" -gt "$HANDOFF_QUOTE_MAX_LINES" ]; then
      handoff_log "  | ... truncated after $HANDOFF_QUOTE_MAX_LINES lines"
      break
    fi
    handoff_log "  | ${line:0:$HANDOFF_QUOTE_MAX_COLS}"
  done <<EOF
$text
EOF
}

# is_uint / is_unum -- the numeric SHAPE predicates. is_uint is a whole
# number (durations, handoff counts); is_unum also allows one decimal point
# (second counts like 0.2). Both refuse the empty string, a leading -, and
# anything longer than 10 digits, because the two things bash does with a
# bad number are both silent: `$(( ))` wraps on overflow (a 20-digit
# duration produced an unprintable dead-until epoch) and `[ x -gt y ]`
# prints a raw shell error and then answers "false" (a non-numeric handoff
# cap stopped capping).
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 10 ]; }
is_unum() {
  case "${1:-}" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  case "$1" in *[0-9]*) [ "${#1}" -le 10 ] ;; *) return 1 ;; esac
}

# enumerate_accounts -- fill the `accounts` array from "$ROOT"/*/. This glob
# IS the definition of "an account", so it lives here, next to the two
# readers of that array (is_account, ranked), rather than in baton's startup
# code: a caller that had to populate the array itself would be a caller that
# could get the definition wrong (a plain `ls "$ROOT"` would enrol .dead,
# .alive and .probe as accounts). baton calls this once at startup, before
# any dispatch; nothing else writes `accounts`.
enumerate_accounts() {
  local d
  accounts=()
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    accounts+=("$(basename "$d")")
  done
}

# is_account NAME -- true only for a name the account enumeration produced.
# That enumeration (enumerate_accounts' `"$ROOT"/*/`) is the DEFINITION of an
# account and never matches a dotted name, so baton's own state dirs (.dead,
# .alive, .probe) and `..` are not accounts. Every dispatch path that turns a name
# into a state file or a CLAUDE_CONFIG_DIR goes through here, because the
# `[ -d "$ROOT/$name" ]` test it replaces accepted all of them: `--probe ..`
# probed with a config dir ABOVE the accounts root, `--probe .alive` probed
# the alive-cache directory, and `--revive` (which had no test at all) ran
# `rm -f "$DEADDIR/$2"`, so `--revive ../a` deleted the primary account's
# symlink.
is_account() {
  local a
  for a in ${accounts[@]+"${accounts[@]}"}; do
    [ "$a" = "$1" ] && return 0
  done
  return 1
}

count_of() { grep "^$1 " "$TALLY" 2>/dev/null | awk '{print $2}' | head -1; }
weight_of() { cat "$ROOT/$1/.weight" 2>/dev/null || echo 1; }

bump() {
  local c
  touch "$TALLY"
  c=$(count_of "$1"); c=${c:-0}
  { grep -v "^$1 " "$TALLY" 2>/dev/null; echo "$1 $((c+1))"; } > "$TALLY.tmp" && mv "$TALLY.tmp" "$TALLY"
  echo "$1" > "$LAST"
}

dead_until() { awk '{print $1}' "$DEADDIR/$1" 2>/dev/null; }
is_dead() { local u; u=$(dead_until "$1"); [ -n "$u" ] && [ "$u" -gt "$(now)" ]; }
mark_dead() { mkdir -p "$DEADDIR"; echo "$2 ${3:-manual}" > "$DEADDIR/$1"; rm -f "$ALIVEDIR/$1"; }

parse_duration() { # 90m / 5h / 3d / raw seconds -> seconds
  local n="$1" mult=1
  case "$1" in
    *d) n="${1%d}"; mult=86400 ;;
    *h) n="${1%h}"; mult=3600 ;;
    *m) n="${1%m}"; mult=60 ;;
  esac
  # The magnitude is validated for every form, not just the bare-seconds
  # one: `-5h` used to parse fine and mark an account "dead until" a time
  # in the past (exit 0, mark inert), and `1e3m` reached `$(( ))` and
  # leaked a raw shell error at the operator.
  is_uint "$n" || die "bad duration '$1' (use 90m / 5h / 3d)"
  echo $(( n * mult ))
}

# mark_dead_for_class -- the ONE place that turns a LIMIT/AUTH classification
# plus its raw source text into a dead-until mark. Shared by probe() (text =
# probe reply) and the --night watcher (text = the matched transcript line),
# so the two call sites can never drift on WHAT a mark means, only on WHERE
# the text came from (D3/D5). A class other than LIMIT/AUTH is a no-op --
# UNKNOWN is never actionable.
mark_dead_for_class() {
  local name="$1" class="$2" text="$3" reset
  case "$class" in
    LIMIT)
      reset=$(printf '%s' "$text" | parse_reset_epoch)
      [ "$reset" -gt "$(now)" ] 2>/dev/null || reset=$(( $(now) + $(parse_duration "$DEFAULT_DEAD") ))
      mark_dead "$name" "$reset" limit
      ;;
    AUTH)
      mark_dead "$name" "$(( $(now) + 3600 ))" auth
      ;;
  esac
}

# Measured 2026-08-21: setting CLAUDE_CONFIG_DIR at all -- even to the literal
# default ~/.claude -- makes the CLI read a DIFFERENT credential slot than a
# login done with the var unset. Both spellings of the primary dir probed
# "Not logged in" while a bare `claude -p` answered. So the primary account
# (whose dir physically IS ~/.claude) must launch with the var unset.
# Sets both ENVARGS (to prefix a claude invocation) and CONFIG_DIR (the
# resolved directory that invocation will use) -- CONFIG_DIR is watch.sh's
# only way to find an account's transcript dir, so this stays the single
# source of truth for "which physical dir does account X's CLI read".
set_envargs() { # $1 account -> sets ENVARGS array + CONFIG_DIR
  if [ "$(cd "$ROOT/$1" 2>/dev/null && pwd -P)" = "$HOME/.claude" ]; then
    ENVARGS=(env -u CLAUDE_CONFIG_DIR)
    CONFIG_DIR="$HOME/.claude"
  else
    ENVARGS=(env "CLAUDE_CONFIG_DIR=$ROOT/$1")
    CONFIG_DIR="$ROOT/$1"
  fi
}

alive_fresh() {
  local m
  m=$(stat -f %m "$ALIVEDIR/$1" 2>/dev/null) || return 1
  [ $(( $(now) - m )) -lt "$ALIVE_TTL" ]
}

probe() { # $1 name -> sets PROBE_CLASS + PROBE_OUT; applies dead/alive marks
  local name="$1" out
  mkdir -p "$PROBECWD" "$ALIVEDIR"
  set_envargs "$name"
  out=$(cd "$PROBECWD" && perl -e 'alarm shift; exec @ARGV' "$PROBE_TIMEOUT" \
        "${ENVARGS[@]}" claude -p "reply with exactly: ok" 2>&1)
  PROBE_OUT="$out"
  PROBE_CLASS=$(classify_text "$out")
  case "$PROBE_CLASS" in
    LIMIT|AUTH)
      mark_dead_for_class "$name" "$PROBE_CLASS" "$out"
      ;;
    UNKNOWN)
      if printf '%s' "$out" | grep -qi "ok"; then
        PROBE_CLASS=ALIVE
        touch "$ALIVEDIR/$name"
        rm -f "$DEADDIR/$name"
      fi
      ;;
  esac
}

ranked() { # live accounts, lowest count/weight first; $1 optionally excluded
  local exclude="${1:-}" a c w
  for a in "${accounts[@]}"; do
    [ "$a" = "$exclude" ] && continue
    is_dead "$a" && continue
    c=$(count_of "$a"); c=${c:-0}
    w=$(weight_of "$a")
    awk -v c="$c" -v w="$w" -v a="$a" 'BEGIN{printf "%.6f %s\n", c/w, a}'
  done | sort -n | awk '{print $2}'
}

# pick_live -- walk ranked() trying account after account with the same
# probe-or-trust-cache policy plain baton has always used ($1 = "probe" or
# "fast"; "fast" trusts ranked() + alive_fresh without ever calling probe()).
# Sets PICKED and returns 0 on success; returns 1 (PICKED unset) once every
# ranked account has come back LIMIT/AUTH. This is the one function
# auto_launch() (exec path) and night_mode() (background+watch path) both
# call for "which account starts next" -- D1 requires --night pick the same
# way plain baton does, and duplicating this loop would be exactly the kind
# of drift DOC.md warns about for the classification regexes.
pick_live() {
  local mode="$1" a
  for a in $(ranked "${BATON_EXCLUDE:-}"); do
    if [ "$mode" = fast ] || alive_fresh "$a"; then
      PICKED="$a"; return 0
    fi
    warn "probing '$a'..."
    probe "$a"
    case "$PROBE_CLASS" in
      ALIVE)   PICKED="$a"; return 0 ;;
      LIMIT)   warn "'$a' is at its limit (dead until $(date -r "$(dead_until "$a")" '+%a %l:%M%p' 2>/dev/null)); trying next" ;;
      # The command to fix this goes to the handoff log, not to stderr. This
      # loop runs once per ranked account, so on an auth cascade stderr would
      # otherwise receive one runnable `baton <name>` per dead account -- and
      # a human who is shown the same shape of command twice runs it twice
      # (issue #2). stderr keeps the fact and the pointer; the log keeps the
      # command.
      AUTH)    warn "'$a' is NOT LOGGED IN; skipping 1h. How to fix it: $HANDOFF_LOG"
               handoff_log "account '$a' is not logged in. To fix it, run:  baton $a   then /login" ;;
      # The probe's own words never reach a shared stream. This branch used to
      # `warn` the first 120 characters of $PROBE_OUT verbatim, which is a
      # strictly worse version of the AUTH bug above: baton's own strings are
      # a closed set a reviewer can read end to end, and probe output is an
      # OPEN set -- proxy error pages, shell fragments, and (reproduced in
      # scenario 40) a complete `baton <account> --resume <id>` line. Text
      # that came from somewhere else is DATA; relaying it into the terminal
      # a human is working in is what turns data into an instruction, and
      # that is the whole of issue #2 root cause 2.
      #
      # stderr gets fixed wording and a pointer. The log gets the words,
      # quoted, so a network diagnosis is still possible in the morning.
      UNKNOWN) warn "unrecognized probe result for '$a' (network?); launching anyway. The probe's own words are in $HANDOFF_LOG, not here."
               handoff_log_quoted "unrecognized probe result for '$a'; launched it anyway" "$PROBE_OUT"
               PICKED="$a"; return 0 ;;
    esac
  done
  return 1
}

# candidates_exist -- true when ranked() would still offer pick_live at least
# one account (dead marks and BATON_EXCLUDE applied; nothing is probed, no
# token is spent). night_mode uses it to tell "every account is exhausted"
# apart from "the handoff cap stopped us" WITHOUT probing the account the cap
# is about to refuse -- failover.feature's cap scenario requires that the
# third account is never probed and never launched.
candidates_exist() { [ -n "$(ranked "${BATON_EXCLUDE:-}")" ]; }

launch() {
  local acct="$1"; shift
  bump "$acct"
  echo "baton: launching as account '$acct'" >&2
  set_envargs "$acct"
  exec "${ENVARGS[@]}" claude "$@"
}

# die_no_live_account -- the one place that spells the operator-facing
# message for "pick_live ran out of accounts". Called from auto_launch()
# (exec path) and night_mode()'s two exhaustion checks (initial pick +
# post-rotation) so the wording can't drift between them.
#
# It names $ROOT because the message is read hours later, out of an
# unattended log, by someone who cannot see the environment the run had:
# "no live account" with no root named is equally consistent with "the plan
# really is exhausted" and with "BATON_ACCOUNTS_ROOT pointed at an empty
# temp dir and baton never saw your accounts at all". failover.feature's
# exhaustion scenario requires the message name BATON_ACCOUNTS_ROOT.
#
# It names the two recovery moves as NOUNS and one as a FLAG, never as two
# pasteable command lines. It used to end "baton --status to see dead marks;
# baton --revive <name> to override", which is two runnable commands on
# stderr -- the last command-shaped output left outside the documented
# `--add` exception, and reached on exactly the path the 2026-08-25 cascade
# ended on. The same rule lock.sh's refusal message already follows: name
# the knob, never the line. The exact commands go to the log, which is the
# one channel allowed to carry them.
die_no_live_account() {
  handoff_log "no live account under $ROOT. To see the dead marks, run:  baton --status   To override one dead mark, run:  baton --revive <name>"
  die "no live account under $ROOT (BATON_ACCOUNTS_ROOT): every account is dead-marked or excluded. Check account status, and revive an account with the --revive flag if you know one is back. The exact commands are in $HANDOFF_LOG"
}

auto_launch() { # $1 = "probe"|"fast", rest = claude args
  local mode="$1"; shift
  pick_live "$mode" && launch "$PICKED" "$@"
  die_no_live_account
}
