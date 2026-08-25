#!/usr/bin/env bash
# tests/fixtures/lib.sh -- shared scenario setup/teardown + result recording.
#
# Every scenario gets its own fresh temp HOME + BATON_ACCOUNTS_ROOT (never
# reused across scenarios, never the real $HOME/.claude-accounts -- see
# QA-DOC section 4 rule 6 and section 7). Assertions accumulate per scenario
# and collapse to exactly one PASS/FAIL line per scenario file, matching the
# 1:1 Gherkin-scenario-to-test mapping the coder assignment requires.

record_pass() { echo "PASS $1" >> "$RESULTS_FILE"; }
record_fail() { echo "FAIL $1 -- $2" >> "$RESULTS_FILE"; }

scenario_begin() { SCENARIO_NAME="$1"; SCENARIO_FAILURES=""; }

# scenario_check DESC COND_EXIT_STATUS -- record a sub-check under the
# current scenario without ending it. COND_EXIT_STATUS is 0 for pass.
scenario_check() {
  if [ "$2" -ne 0 ]; then
    SCENARIO_FAILURES="${SCENARIO_FAILURES}[$1] "
  fi
}

scenario_end() {
  if [ -z "$SCENARIO_FAILURES" ]; then
    record_pass "$SCENARIO_NAME"
  else
    record_fail "$SCENARIO_NAME" "$SCENARIO_FAILURES"
  fi
}

# fresh_root -- isolated HOME + BATON_ACCOUNTS_ROOT + PATH (fake claude
# first) for one scenario. Creates account "a" (primary, symlinked so its
# dir resolves to $HOME/.claude per the Background) and "b" (non-primary),
# both pre-marked alive-and-undead so plain baton's own alive-cache behavior
# is reused unmodified for the initial pick in --night mode too (D1: "the
# same way plain baton does").
#
# $1, if "hardcoded", points BATON_ACCOUNTS_ROOT at $HOME/.claude-accounts
# instead of a scratch subdir -- for the regression scenario (QA-DOC section
# 5 row 12) that must exercise BATON_ACCOUNTS_ROOT UNSET so the pre-failover
# baton (which hardcodes $HOME/.claude-accounts and has never heard of
# BATON_ACCOUNTS_ROOT) and the current baton (whose default is that exact
# same path per D7) read the identical directory. Exporting the var to that
# literal value rather than truly leaving it unset is equivalent from both
# scripts' point of view (old ignores it; new's default already resolves
# there) and keeps every other fixture helper in this file working unchanged.
fresh_root() {
  # Defensive: this repo's own dev environment runs under a real baton
  # account (CLAUDE_CONFIG_DIR pointing at a real ~/.claude-accounts/<name>).
  # Every scenario must start from a clean slate regardless of what invoked
  # the test suite.
  unset CLAUDE_CONFIG_DIR
  # Resolve through macOS's /var -> /private/var symlink up front: baton's
  # own primary-account check (set_envargs) compares `cd ... && pwd -P`
  # against the literal $HOME/.claude string, so an unresolved mktemp HOME
  # would make account "a" misdetect as non-primary purely as a test-harness
  # artifact, not a real behavior difference.
  SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
  export HOME="$SCRATCH/home"
  mkdir -p "$HOME"
  if [ "${1:-}" = hardcoded ]; then
    export BATON_ACCOUNTS_ROOT="$HOME/.claude-accounts"
  else
    export BATON_ACCOUNTS_ROOT="$SCRATCH/accounts"
  fi
  mkdir -p "$BATON_ACCOUNTS_ROOT"
  export PATH="$FIXTURES_DIR/bin:$PATH"
  export BATON_WATCH_INTERVAL="0.2"

  mkdir -p "$HOME/.claude"
  ln -s "$HOME/.claude" "$BATON_ACCOUNTS_ROOT/a"
  mkdir -p "$BATON_ACCOUNTS_ROOT/b"
  mkdir -p "$BATON_ACCOUNTS_ROOT/.alive"
  touch "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b"
}

fresh_root_hardcoded_default() { fresh_root hardcoded; }

add_account() { # $1 name -- a third (or later) non-primary account, alive+undead
  mkdir -p "$BATON_ACCOUNTS_ROOT/$1"
  mkdir -p "$BATON_ACCOUNTS_ROOT/.alive"
  touch "$BATON_ACCOUNTS_ROOT/.alive/$1"
}

cleanup_root() {
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
}

# config_dir_of NAME -- where that account's CLAUDE_CONFIG_DIR resolves to,
# by the exact rule baton itself uses (primary == $HOME/.claude).
config_dir_of() {
  if [ "$1" = a ]; then echo "$HOME/.claude"; else echo "$BATON_ACCOUNTS_ROOT/$1"; fi
}

# cwd_slug -- the same absolute-cwd/-/. -> - rule DOC.md gives the real CLI,
# computed independently of baton's implementation so fixtures and assertions
# don't accidentally depend on baton's own slugify function being correct.
cwd_slug() { printf '%s' "$PWD" | sed 's/[./]/-/g'; }

# write_behavior NAME -- writes a .fake-behavior file for that account's
# config dir from stdin (the shell array-assignment lines the fake claude
# executable sources; see tests/fixtures/bin/claude and QA-DOC section 2).
write_behavior() {
  local dir; dir="$(config_dir_of "$1")"
  mkdir -p "$dir"
  cat > "$dir/.fake-behavior"
}

fake_log() { echo "$BATON_ACCOUNTS_ROOT/.fake-claude.log"; }
signals_log_of() { echo "$(config_dir_of "$1")/.fake-signals.log"; }
invocation_count_file_of() { echo "$(config_dir_of "$1")/.fake-invocations"; }

# invocation_count NAME -- how many times the fake claude has run under that
# account's config dir so far.
invocation_count() {
  cat "$(invocation_count_file_of "$1")" 2>/dev/null || echo 0
}

transcript_file_of() { # $1 account -> path of its (single) transcript file, if any
  local dir="$(config_dir_of "$1")/projects/$(cwd_slug)"
  ls "$dir"/*.jsonl 2>/dev/null | head -1
}

# start_night ARGS... -- launches `baton --night ARGS...` in the background,
# capturing stdout/stderr to $SCRATCH/night.out / night.err. Sets NIGHT_PID.
start_night() {
  "$BATON_BIN" --night "$@" >"$SCRATCH/night.out" 2>"$SCRATCH/night.err" &
  NIGHT_PID=$!
}

# wait_for_night_exit TIMEOUT -- waits for the backgrounded --night process
# to finish; sets NIGHT_EXIT. Returns 1 (NIGHT_EXIT unset) on timeout, in
# which case the process is left running for the caller to deal with.
wait_for_night_exit() {
  local timeout="$1" waited=0
  while kill -0 "$NIGHT_PID" 2>/dev/null; do
    sleep 0.1
    waited=$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.1}')
    if awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w>=t)}'; then
      kill -0 "$NIGHT_PID" 2>/dev/null && return 1
      break
    fi
  done
  wait "$NIGHT_PID"
  NIGHT_EXIT=$?
  return 0
}

night_stderr() { cat "$SCRATCH/night.err" 2>/dev/null; }

# wait_for_transcript NAME TIMEOUT -- blocks until account NAME's transcript
# file exists; echoes its path. Empty output + return 1 on timeout.
wait_for_transcript() {
  local name="$1" timeout="$2" waited=0 f
  while :; do
    f=$(transcript_file_of "$name")
    [ -n "$f" ] && { echo "$f"; return 0; }
    sleep 0.1
    waited=$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.1}')
    awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w>=t)}' && return 1
  done
}

# kill_fake_claude NAME -- force-kill the actual fake-claude process running
# under that account's config dir, if any (used to tear down a still-blocked
# fixture the test itself decided to abandon, e.g. after the classification-
# contract outline observes a poll cycle and moves to the next example row).
kill_fake_claude() {
  local f="$(config_dir_of "$1")/.fake-pid-ppid"
  [ -f "$f" ] || return 0
  local pid; pid=$(awk '{print $1}' "$f")
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
}

# stop_night -- forcibly stop a still-running --night process (used after a
# scenario has already recorded what it needed and just wants to clean up).
stop_night() {
  kill -KILL "$NIGHT_PID" 2>/dev/null
  wait "$NIGHT_PID" 2>/dev/null
}

is_dead_marked() { [ -f "$BATON_ACCOUNTS_ROOT/.dead/$1" ]; }
dead_epoch_of() { awk '{print $1}' "$BATON_ACCOUNTS_ROOT/.dead/$1" 2>/dev/null; }
dead_reason_of() { awk '{print $2}' "$BATON_ACCOUNTS_ROOT/.dead/$1" 2>/dev/null; }
