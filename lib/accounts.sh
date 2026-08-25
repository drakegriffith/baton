#!/usr/bin/env bash
# accounts -- per-account state (tally, dead/alive marks, weight) and the
# ranked-selection + probing policy baton's CLI dispatch drives. Depends on
# detect (classify_text, via probe() and mark_dead_for_class); never the
# reverse. Exposes the public surface `watch` is allowed to call: ranked(),
# is_dead(), mark_dead(), mark_dead_for_class(), probe(), pick_live(),
# set_envargs(), bump(), die_no_live_account(), is_uint(), is_unum(),
# is_account(), enumerate_accounts(), candidates_exist(). Everything else here (tally
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
# handoff_log MSG -- append one timestamped line. Writes to no stream, ever
# (not stdout, not stderr, not /dev/tty). A failed append is deliberately
# silent: a full or read-only disk must not turn an unattended overnight run
# into an error cascade at 3am, and every caller has already put the
# non-actionable half of its message on stderr.
handoff_log() {
  mkdir -p "$ROOT" 2>/dev/null
  printf '%s baton: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HANDOFF_LOG" 2>/dev/null || true
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
      UNKNOWN) warn "unrecognized probe result for '$a' (network?); launching anyway: ${PROBE_OUT:0:120}"
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
die_no_live_account() {
  die "no live account under $ROOT (BATON_ACCOUNTS_ROOT). baton --status to see dead marks; baton --revive <name> to override"
}

auto_launch() { # $1 = "probe"|"fast", rest = claude args
  local mode="$1"; shift
  pick_live "$mode" && launch "$PICKED" "$@"
  die_no_live_account
}
