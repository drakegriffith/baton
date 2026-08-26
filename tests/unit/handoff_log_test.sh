#!/usr/bin/env bash
# Unit tests for the handoff log's append, in lib/accounts.sh.
#
# Sourcing rule (QA-DOC section 1 + the section 6 amendment): a module may be
# sourced directly when the functions under test depend on no OTHER baton
# module. These do -- they touch only $HANDOFF_LOG, `stat`, and python3.
# accounts.sh as a whole depends on detect.sh, but nothing on this path calls
# classify_text, and sourcing it executes only variable assignments.
#
# WHY UNIT ROWS. The hole these close is a RACE: a symlink dropped in between
# the bash pre-check and the open. It cannot be triggered on demand from
# outside the process, so a black-box scenario could only assert the guard's
# SILENCE -- the thing absence-is-not-evidence forbids. These rows call the
# appender directly against a hostile path and require it to REFUSE. Without
# them the guard is code that always answers "fine".
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITROOT="$(cd "$(mktemp -d)" && pwd -P)/accounts"
mkdir -p "$UNITROOT"
export BATON_ACCOUNTS_ROOT="$UNITROOT"
. "$HERE/../../lib/accounts.sh"
. "$HERE/../fixtures/lib.sh"

check() { # $1 name, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then
    record_pass "unit:handoff_log:$1"
  else
    record_fail "unit:handoff_log:$1" "expected [$3] got [$2]"
  fi
}

# --- the honest path, as the negative control ------------------------------
# Every refusal row below is only meaningful if the appender WRITES when the
# path is fine. If this row fails, the guard is not strict, it is broken.
rm -f "$HANDOFF_LOG"
: > "$HANDOFF_LOG"
IDENT=$(_handoff_log_ident)
_handoff_append "$IDENT" "hello"; rc=$?
check "regular-file-append-succeeds" "$rc" 0
check "regular-file-append-lands" "$(cat "$HANDOFF_LOG")" "hello"

# --- the identity guard: a swapped file is refused -------------------------
# Same type, same permissions, different file. Only the inode says the line
# would go somewhere other than the file that was checked.
rm -f "$HANDOFF_LOG"
: > "$HANDOFF_LOG"
_handoff_append "$IDENT" "should not land"; rc=$?
check "a-different-inode-is-refused" "$rc" 3
check "and-nothing-was-written" "$(cat "$HANDOFF_LOG")" ""

# --- O_NOFOLLOW: the open itself refuses a symlink -------------------------
# This is the round-3 fix. The previous guard checked the path, appended, then
# re-checked -- which a swap-append-restore sequence walks straight through,
# because the path looks identical by the time the second check runs. Refusing
# in the OPEN removes the window instead of narrowing it: there is no longer a
# moment between the decision and the write.
rm -f "$HANDOFF_LOG"
TARGET="$UNITROOT/elsewhere.log"
: > "$TARGET"
ln -s "$TARGET" "$HANDOFF_LOG"
_handoff_append "$IDENT" "must not follow"; rc=$?
check "a-symlink-is-refused-by-the-open" "$rc" 3
check "and-the-symlink-target-gained-nothing" "$(wc -c < "$TARGET" | tr -d ' ')" 0
rm -f "$HANDOFF_LOG"

# --- a FIFO must not hang --------------------------------------------------
# Opening a FIFO for write with no reader blocks forever, and this call sits
# in the watcher's failover path. O_NONBLOCK turns that hang into ENXIO. The
# alarm is the assertion: if the guard ever regresses, this row fails by
# TIMING OUT rather than by hanging the whole suite.
mkfifo "$HANDOFF_LOG"
perl -e 'alarm shift; exec @ARGV' 10 bash -c '. "$0"; _handoff_append "x" "y"' "$HERE/../../lib/accounts.sh" >/dev/null 2>&1
rc=$?
check "a-fifo-does-not-hang-the-appender" $([ "$rc" -ne 142 ]; echo $?) 0
check "a-fifo-is-refused" $([ "$rc" -eq 3 ] || [ "$rc" -eq 2 ]; echo $?) 0
rm -f "$HANDOFF_LOG"

# --- a directory is refused ------------------------------------------------
mkdir -p "$HANDOFF_LOG"
_handoff_append "$IDENT" "nope"; rc=$?
check "a-directory-is-refused" $([ "$rc" -eq 3 ] || [ "$rc" -eq 2 ]; echo $?) 0
rmdir "$HANDOFF_LOG"

# --- end to end: handoff_log creates the file 0600 -------------------------
rm -f "$HANDOFF_LOG"
handoff_log "unit row" >/dev/null 2>&1
check "handoff_log-creates-the-file" $([ -f "$HANDOFF_LOG" ]; echo $?) 0
check "handoff_log-creates-it-0600" "$(stat -f %Lp "$HANDOFF_LOG")" "600"
check "handoff_log-writes-the-line" $(grep -q 'unit row' "$HANDOFF_LOG"; echo $?) 0

rm -rf "$(dirname "$UNITROOT")"
