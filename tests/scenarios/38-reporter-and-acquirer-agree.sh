#!/usr/bin/env bash
# `inspected` lied about what it had counted, and the reporter and the acquirer
# disagreed about the same lock root.
#
# LOCK_INSPECTED meant "I reached a determinate answer for the one subject you
# named", not "I found >= 1 lock subject on disk". So a lock root that cannot
# exist read back as `state=free inspected=1 EXIT=0` from `--lock-status`,
# while `--claim` on that identical root correctly returned 2. The reporter
# said the board was clean; the acquirer said it could not look. The reporter
# is the one that gets asserted on, which is how a check written against
# "silence is not evidence" ends up being vacuous itself: scenario 31's
# `inspected > 0` row passed with zero subjects and no lock root at all.
#
# Two changes are asserted here. `inspected` now counts owner records actually
# read (a never-locked subject honestly reports 0), and `--locks` enumerates,
# so a caller that wants "there are subjects on disk" can ask a question whose
# answer can come back zero.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "38-reporter-and-acquirer-agree"
fresh_root
export BATON_LOCK_PROV=test

# --- a lock root that cannot exist: BOTH must say could-not-inspect --------
# /dev/null is not a directory, so `.../nope` can never be created. The old
# probe skipped its root check entirely when the root did not exist yet and
# fell through to a determinate `free`.
IMPOSSIBLE=/dev/null/nope

st="$(BATON_LOCK_DIR="$IMPOSSIBLE" "$BATON_BIN" --lock-status unit:x 2>/dev/null)"
strc=$?
scenario_check "the reporter exits 2 on an impossible lock root" \
  $([ "$strc" -eq 2 ]; echo $?)
scenario_check "the reporter says could-not-inspect, not free" \
  $(printf '%s' "$st" | grep -q 'state=could-not-inspect'; echo $?)
scenario_check "the reporter counts zero subjects there" \
  $(printf '%s' "$st" | grep -q 'inspected=0'; echo $?)

BATON_LOCK_DIR="$IMPOSSIBLE" "$BATON_BIN" --claim unit:x \
  -- sh -c "echo RAN > '$SCRATCH/impossible'" >/dev/null 2>&1
clrc=$?
scenario_check "the acquirer exits 2 on the same root" $([ "$clrc" -eq 2 ]; echo $?)
scenario_check "and ran nothing" $([ ! -e "$SCRATCH/impossible" ]; echo $?)
scenario_check "REPORTER AND ACQUIRER AGREE on the impossible root" \
  $([ "$strc" -eq "$clrc" ]; echo $?)

BATON_LOCK_DIR="$IMPOSSIBLE" "$BATON_BIN" --locks >/dev/null 2>&1
lkrc=$?
scenario_check "--locks exits 2 on the impossible root too" $([ "$lkrc" -eq 2 ]; echo $?)

# --- an absent but CREATABLE root is a different answer, and stays one -----
# The fix must not collapse "not there yet" into "cannot look": a first-ever
# run has no lock root, and refusing to launch on that would be a guard that
# never lets anything start.
ABSENT="$SCRATCH/never-created-yet"
st2="$(BATON_LOCK_DIR="$ABSENT" "$BATON_BIN" --lock-status unit:x 2>/dev/null)"
strc2=$?
scenario_check "an absent but creatable root is determinate, exit 0" \
  $([ "$strc2" -eq 0 ]; echo $?)
scenario_check "and reads free" \
  $(printf '%s' "$st2" | grep -q 'state=free'; echo $?)
# The honest count: nothing was on disk, so nothing was inspected. This is the
# row that used to read inspected=1 for a subject that had never existed.
scenario_check "a never-locked subject honestly reports inspected=0" \
  $(printf '%s' "$st2" | grep -q 'inspected=0'; echo $?)

BATON_LOCK_DIR="$ABSENT" "$BATON_BIN" --claim unit:x \
  -- sh -c "echo RAN > '$SCRATCH/creatable'" >/dev/null 2>&1
clrc2=$?
scenario_check "the acquirer also succeeds on a creatable root" \
  $([ "$clrc2" -eq 0 ]; echo $?)
scenario_check "REPORTER AND ACQUIRER AGREE on the creatable root" \
  $([ "$strc2" -eq "$clrc2" ]; echo $?)
scenario_check "positive control: the guarded command really ran" \
  $([ -e "$SCRATCH/creatable" ]; echo $?)

# --- --locks enumerates, and its count can come back zero ------------------
EMPTY="$SCRATCH/empty-root"
mkdir -p "$EMPTY"
out="$(BATON_LOCK_DIR="$EMPTY" "$BATON_BIN" --locks 2>/dev/null)"; emptyrc=$?
scenario_check "--locks on a readable but empty root exits 1, not 0" \
  $([ "$emptyrc" -eq 1 ]; echo $?)
scenario_check "--locks says so in words: zero subjects" \
  $(printf '%s' "$out" | grep -q 'inspected 0 lock subject'; echo $?)

# Two real subjects, planted through the CLI so nothing here knows the on-disk
# format. Both are released by the time they are counted, which is the point:
# a released subject is still a subject that exists on disk.
"$BATON_BIN" --claim session:alpha -- true >/dev/null 2>&1
"$BATON_BIN" --claim unit:beta -- true >/dev/null 2>&1
out2="$("$BATON_BIN" --locks 2>/dev/null)"; lrc2=$?
scenario_check "--locks exits 0 once subjects exist" $([ "$lrc2" -eq 0 ]; echo $?)
scenario_check "--locks counts exactly the two subjects on disk" \
  $(printf '%s' "$out2" | grep -q 'inspected 2 lock subject'; echo $?)
scenario_check "--locks names the session subject it found" \
  $(printf '%s' "$out2" | grep -q 'session_alpha'; echo $?)
scenario_check "--locks names the unit subject it found" \
  $(printf '%s' "$out2" | grep -q 'unit_beta'; echo $?)

cleanup_root
scenario_end
