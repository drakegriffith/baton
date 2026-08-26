#!/usr/bin/env bash
# Unit tests for the handoff log's path guard in lib/accounts.sh.
#
# Sourcing rule (QA-DOC section 1 + the section 6 amendment): a module may be
# sourced directly when the functions under test depend on no OTHER baton
# module. These four do -- _handoff_log_ident, _handoff_log_same_file,
# _handoff_log_usable and handoff_log touch only $HANDOFF_LOG and `stat`.
# accounts.sh as a whole depends on detect.sh, but nothing on this path calls
# classify_text, and sourcing it executes only variable assignments.
#
# WHY THESE ARE UNIT ROWS AND NOT A SCENARIO. The swap they guard against is
# a RACE: a symlink dropped in between _handoff_log_usable's check and the
# `>>` that opens the path. Bash has no O_NOFOLLOW open, so that window
# cannot be closed from a shell -- only detected after the fact, by asking
# whether the path still names the file it named a moment ago. A race cannot
# be triggered on demand from outside the process, so a black-box scenario
# could only ever assert the detector's SILENCE, which is the thing
# absence-is-not-evidence forbids. These rows call the detector with a
# planted "before" value and require it to FIRE. Without them it is dead code
# that always answers "fine".
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITROOT="$(cd "$(mktemp -d)" && pwd -P)/accounts"
mkdir -p "$UNITROOT"
export BATON_ACCOUNTS_ROOT="$UNITROOT"
. "$HERE/../../lib/accounts.sh"
. "$HERE/../fixtures/lib.sh"

check() { # $1 name, $2 actual exit, $3 expected exit
  if [ "$2" = "$3" ]; then
    record_pass "unit:handoff_log:$1"
  else
    record_fail "unit:handoff_log:$1" "expected exit $3 got $2"
  fi
}

# --- the identity reader ---------------------------------------------------
: > "$HANDOFF_LOG"
IDENT_A=$(_handoff_log_ident)
check "ident-of-a-regular-file-is-readable" $([ -n "$IDENT_A" ]; echo $?) 0

# The unchanged path is the NEGATIVE control: if this row ever fails, every
# "fired" row below is firing for the wrong reason and the detector is simply
# broken rather than sensitive.
_handoff_log_same_file "$IDENT_A"
check "unchanged-path-is-the-same-file" $? 0

# --- the detector fires: swapped for a symlink -----------------------------
# The measured shape. The append has already gone through the link by the
# time this runs; detecting it is what turns silent misdirection into a
# reported failure.
rm -f "$HANDOFF_LOG"
ln -s "$UNITROOT/elsewhere.log" "$HANDOFF_LOG"
_handoff_log_same_file "$IDENT_A"
check "swapped-for-a-symlink-is-detected" $? 1
rm -f "$HANDOFF_LOG"

# --- the detector fires: swapped for a DIFFERENT regular file --------------
# A symlink is not the only swap. Replacing the file with another regular
# file passes every type check and changes nothing an `-f` test can see; only
# the inode says the line went somewhere else.
: > "$HANDOFF_LOG"
_handoff_log_same_file "$IDENT_A"
check "swapped-for-another-regular-file-is-detected" $? 1

# --- the detector fires: the path is gone ----------------------------------
rm -f "$HANDOFF_LOG"
_handoff_log_same_file "$IDENT_A"
check "a-vanished-path-is-detected" $? 1

# --- could-not-determine is not a pass -------------------------------------
# An empty "before" means the identity was never read. Answering "same file"
# to a question that was never asked is the exact shape 24-absence-is-not-
# evidence forbids: a check that inspected nothing must not report clean.
: > "$HANDOFF_LOG"
_handoff_log_same_file ""
check "an-unreadable-before-value-is-not-a-pass" $? 1

# --- end to end: a fresh log is created 0600 -------------------------------
rm -f "$HANDOFF_LOG"
handoff_log "unit row" >/dev/null 2>&1
check "handoff_log-creates-the-file" $([ -f "$HANDOFF_LOG" ]; echo $?) 0
check "handoff_log-creates-it-0600" $([ "$(stat -f %Lp "$HANDOFF_LOG")" = "600" ]; echo $?) 0

rm -rf "$(dirname "$UNITROOT")"
