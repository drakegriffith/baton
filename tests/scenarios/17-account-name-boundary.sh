#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): an account NAME is an adversarial
# input at four boundaries (--probe, --dead, --revive, forced launch), and
# every one of them used to accept anything that happened to be a directory
# under the accounts root -- including `..` and baton's own private state
# dirs `.dead` / `.alive`, which the account enumeration (`"$ROOT"/*/`,
# which never matches a dotted name) deliberately excludes. Measured before
# the fix: `baton --probe ..` probed with CLAUDE_CONFIG_DIR pointing one
# level ABOVE the accounts root and printed `rm: "." and ".." may not be
# removed`; `baton --probe .alive` probed the alive-cache directory as if
# it were an account; and `baton --revive ../<x>` ran
# `rm -f "$ROOT/.dead/../<x>"`, i.e. deleted an arbitrary path outside the
# dead directory -- for `../a` that is the primary account's symlink.
# Every one must now fail into the existing "no account" contract.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "17-account-name-boundary"
fresh_root

refuses() { # $1 label, then the argv baton must refuse
  local label="$1"; shift
  local out rc
  out=$("$BATON_BIN" "$@" 2>&1); rc=$?
  scenario_check "$label exits nonzero" $([ "$rc" -ne 0 ]; echo $?)
  scenario_check "$label says so on stderr" $(printf '%s' "$out" | grep -qi "account"; echo $?)
}

refuses "--probe nosuch"   --probe nosuch
refuses "--probe .."       --probe ..
refuses "--probe .alive"   --probe .alive
refuses "--probe .dead"    --probe .dead
refuses "--dead .alive"    --dead .alive 90m
refuses "--revive ../a"    --revive ../a
refuses "--revive .alive"  --revive .alive

scenario_check "the primary account symlink survived --revive ../a" \
  $([ -L "$BATON_ACCOUNTS_ROOT/a" ]; echo $?)

sentinel="$BATON_ACCOUNTS_ROOT/keep-me"
: > "$sentinel"
"$BATON_BIN" --revive ../keep-me >/dev/null 2>&1
scenario_check "--revive cannot delete a path outside the dead dir" $([ -e "$sentinel" ]; echo $?)

# A name that is not an account is claude's argument, never a config dir:
# the state dirs must never appear as a CLAUDE_CONFIG_DIR in the log.
write_behavior a <<'EOF'
STEP_STDOUT=("ok")
EOF
"$BATON_BIN" .alive >/dev/null 2>&1
"$BATON_BIN" .. >/dev/null 2>&1
log="$(fake_log)"
scenario_check "no invocation ever ran with the .alive dir as its config dir" \
  $(! grep -q "config=$BATON_ACCOUNTS_ROOT/.alive " "$log"; echo $?)
scenario_check "no invocation ever ran above the accounts root" \
  $(! grep -q "config=$BATON_ACCOUNTS_ROOT/\.\. " "$log"; echo $?)
scenario_check "the alive dir is still a directory, not a probed account" \
  $([ -d "$BATON_ACCOUNTS_ROOT/.alive" ] && [ ! -e "$BATON_ACCOUNTS_ROOT/.alive/.fake-invocations" ]; echo $?)

cleanup_root
scenario_end
