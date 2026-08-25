#!/usr/bin/env bash
# Gherkin Scenario Outline: "Existing flags are unaffected by the --night
# addition". QA-DOC section 5 row 12: run each flag against the
# pre-failover baton and the current one from IDENTICAL fixtures, byte-diff
# stdout/stderr excluding timestamps.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "12-existing-flags-outline"

REPO_ROOT="$(dirname "$BATON_BIN")"
OLD_BATON="$(mktemp)"
git -C "$REPO_ROOT" show 173fd9e:baton > "$OLD_BATON"
chmod +x "$OLD_BATON"

# Strip wall-clock-dependent substrings (full `date` strings and `date -r
# ... '+%a %l:%M%p'` short forms) so two invocations run milliseconds apart
# don't spuriously differ.
normalize() {
  sed -E \
    -e 's/[A-Za-z]{3} [A-Za-z]{3} +[0-9]{1,2} [0-9:]{8} [A-Za-z]{2,5} [0-9]{4}/<DATE>/g' \
    -e 's/[A-Za-z]{3} +[0-9]{1,2}:[0-9]{2}(AM|PM)/<DATE>/g'
}

run_case() { # $1 = human label, remaining args = the flags to run
  local label="$1"; shift
  local old_out old_err old_code new_out new_err new_code

  fresh_root_hardcoded_default
  old_out=$("$OLD_BATON" "$@" 2>"$SCRATCH/old.err"); old_code=$?
  old_err=$(cat "$SCRATCH/old.err")
  cleanup_root

  fresh_root_hardcoded_default
  new_out=$("$BATON_BIN" "$@" 2>"$SCRATCH/new.err"); new_code=$?
  new_err=$(cat "$SCRATCH/new.err")
  cleanup_root

  local n_old_out n_new_out n_old_err n_new_err
  n_old_out=$(printf '%s' "$old_out" | normalize)
  n_new_out=$(printf '%s' "$new_out" | normalize)
  n_old_err=$(printf '%s' "$old_err" | normalize)
  n_new_err=$(printf '%s' "$new_err" | normalize)

  scenario_check "$label: stdout matches pre-failover baton" $([ "$n_old_out" = "$n_new_out" ]; echo $?)
  scenario_check "$label: stderr matches pre-failover baton" $([ "$n_old_err" = "$n_new_err" ]; echo $?)
  scenario_check "$label: exit code matches pre-failover baton" $([ "$old_code" = "$new_code" ]; echo $?)
}

run_case "--status" --status
run_case "--pick" --pick
run_case "--dead a 90m" --dead a 90m
run_case "--revive a" --revive a
run_case "--next" --next
run_case "--fast" --fast
run_case "forced account a" a

rm -f "$OLD_BATON"
scenario_end
