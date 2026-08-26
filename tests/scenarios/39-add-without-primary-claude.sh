#!/usr/bin/env bash
# seat kimi-install hardening test: `baton --add <name>` used to create an
# empty account directory and exit 0 when ~/.claude did not exist, because the
# loop that symlinks harness pieces simply saw no source files and the mkdir
# had already happened. enumerate_accounts then counted the empty dir as an
# account. With no primary config to symlink from, --add must refuse before it
# creates anything.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "39-add-without-primary-claude"
fresh_root

# Simulate a fresh machine: the primary ~/.claude is absent and the accounts
# root is empty. fresh_root() already gave us the isolated HOME and PATH.
rm -rf "$HOME/.claude"
find "$BATON_ACCOUNTS_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

out=$("$BATON_BIN" --add work 2>&1); rc=$?

scenario_check "--add exits nonzero when ~/.claude is missing" \
  $([ "$rc" -ne 0 ]; echo $?)

scenario_check "stderr names ~/.claude" \
  $(printf '%s' "$out" | grep -q '~/.claude'; echo $?)

scenario_check "stderr tells the user what to do" \
  $(printf '%s' "$out" | grep -qi 'run claude once\|mkdir -p ~/.claude'; echo $?)

# Count entries under the accounts root; must be 0, and the count must have
# actually happened (not a hardcoded assertion).
account_entries=$(find "$BATON_ACCOUNTS_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
scenario_check "account count was actually taken" \
  $([ -n "$account_entries" ]; echo $?)
scenario_check "no account directory was created" \
  $([ "$account_entries" -eq 0 ]; echo $?)

cleanup_root
scenario_end
