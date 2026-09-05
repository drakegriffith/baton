#!/usr/bin/env bash
# Gherkin Scenario Outline: "The same shared classification function backs
# both detection paths". QA-DOC section 5 row 10 + section 6: drive both
# call sites through the CLI (never call classify_text() directly here --
# that's what tests/unit/detect_test.sh is for) and assert they agree.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "10-classification-contract-outline"

check_row() { # $1 text, $2 expected class (LIMIT|AUTH|UNKNOWN)
  local text="$1" expected="$2"

  # -- call site 1: probe() via `baton --probe a` -----------------------
  fresh_root
  write_behavior a <<EOF
STEP_STDOUT=("$text")
EOF
  local probe_out probe_class
  probe_out="$("$BATON_BIN" --probe a 2>/dev/null)"
  probe_class=$(printf '%s' "$probe_out" | head -1 | awk '{print $2}')
  scenario_check "probe class for [$text] is $expected" $([ "$probe_class" = "$expected" ]; echo $?)
  cleanup_root

  # -- call site 2: the --night transcript watcher -----------------------
  fresh_root
  # Transcript AUTH now needs the current account's fresh probe to agree.
  write_behavior a <<EOF
STEP_STDOUT=("ok" "$text")
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-outline")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
  start_night
  local f; f=$(wait_for_transcript a 5)
  printf '%s\n' "$text" >> "$f"
  sleep 1

  local observed=UNKNOWN
  [ -s "$(signals_log_of a)" ] && observed=ACTIONABLE
  case "$expected" in
    UNKNOWN) scenario_check "watcher took no action for [$text]" $([ "$observed" = UNKNOWN ]; echo $?) ;;
    *)       scenario_check "watcher acted (killed the child) for [$text]" $([ "$observed" = ACTIONABLE ]; echo $?) ;;
  esac

  kill_fake_claude a
  stop_night
  cleanup_root
}

check_row "You've hit your usage limit. resets 2:30pm (America/New_York)" LIMIT
check_row "usage limit reached for this account" LIMIT
check_row "Not logged in. Please run /login" AUTH
check_row "Invalid API key" AUTH
check_row "Here is the code you asked for..." UNKNOWN
check_row "" UNKNOWN

scenario_end
