#!/usr/bin/env bash
# Gherkin: "Tests never touch the real accounts root" (@dependency). QA-DOC
# section 4 rule 6 + section 5 row 14: the forbidden dependency here is
# "code path falls back to the hardcoded default instead of honoring
# BATON_ACCOUNTS_ROOT". Unlike every other scenario, this one deliberately
# does NOT override $HOME -- it runs against the REAL $HOME, with only
# BATON_ACCOUNTS_ROOT pointed at a temp dir, and then proves the real
# ~/.claude-accounts (if it exists) is untouched. If baton ever regressed to
# reading/writing the hardcoded root even with the override set, this test
# would catch a new/changed file there.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "14-real-accounts-root-untouched"

REAL_HOME="$HOME"
REAL_ROOT="$REAL_HOME/.claude-accounts"
real_root_existed=0
[ -d "$REAL_ROOT" ] && real_root_existed=1

marker="$(mktemp)"  # anything with an mtime older than "now" works as a -newer reference
sleep 1.1            # ensure strict mtime ordering vs. anything the run might touch

unset CLAUDE_CONFIG_DIR
SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
# Deliberately NOT overriding HOME here -- that's the point of this scenario.
export BATON_ACCOUNTS_ROOT="$SCRATCH/accounts"
mkdir -p "$BATON_ACCOUNTS_ROOT"
export PATH="$FIXTURES_DIR/bin:$PATH"
export BATON_WATCH_INTERVAL="0.2"
mkdir -p "$SCRATCH/fake_a_home/.claude"
ln -s "$SCRATCH/fake_a_home/.claude" "$BATON_ACCOUNTS_ROOT/a"
mkdir -p "$BATON_ACCOUNTS_ROOT/b" "$BATON_ACCOUNTS_ROOT/.alive"
touch "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b"

# Run a representative slice of the suite's own behavior against this setup:
# a plain status call plus a full --night handoff, both of which are exactly
# the code paths that touch ROOT.
"$BATON_BIN" --status >/dev/null 2>&1

write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
"$BATON_BIN" --night >/dev/null 2>&1

if [ "$real_root_existed" -eq 1 ]; then
  changed=$(find "$REAL_ROOT" -newer "$marker" 2>/dev/null)
  scenario_check "real accounts root has no file newer than the pre-run marker" $([ -z "$changed" ]; echo $?)
else
  scenario_check "real accounts root still does not exist" $([ ! -d "$REAL_ROOT" ]; echo $?)
fi

# The real ~/.claude is the OTHER ambient directory this scenario can leak
# into, and it did: the fixtures used to assume account "a" always means
# $HOME/.claude, so write_behavior dropped a .fake-* file straight into the
# operator's live config dir. Only fixture-shaped names are checked, because
# ~/.claude is a live directory whose real contents change constantly for
# reasons that have nothing to do with this suite.
fakes=$(find "$REAL_HOME/.claude" -maxdepth 1 -name '.fake-*' -newer "$marker" 2>/dev/null)
scenario_check "real ~/.claude gained no fake-fixture files" $([ -z "$fakes" ]; echo $?)

rm -f "$marker"
rm -rf "$SCRATCH"
scenario_end
