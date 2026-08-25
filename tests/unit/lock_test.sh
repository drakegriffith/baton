#!/usr/bin/env bash
# Unit tests for lib/lock.sh -- the ONE lock root, exercised through two
# different subjects (a session id and a run unit) to prove the subject is a
# parameter rather than two mechanisms wearing one name.
#
# Sourcing rule (QA-DOC section 1 + the amendment in section 6): a module may
# be sourced directly only when it depends on no OTHER baton module beyond
# ones already cleared for it. lock.sh depends on runs.sh and nothing else,
# and runs.sh is already sourced directly by tests/unit/runs_test.sh under
# the same reasoning. Nothing here sources `baton`, `accounts` or `watch`.
#
# Every lock this file writes is stamped prov=test, so a self-test lock can
# never be read back as a real holder.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/runs.sh"
. "$HERE/../../lib/lock.sh"
. "$HERE/../fixtures/lib.sh"

export BATON_LOCK_PROV=test

SCRATCH_LOCKS="$(mktemp -d)"
SCRATCH_RUNS="$(mktemp -d)"
STUBBIN="$(mktemp -d)"
export BATON_LOCK_DIR="$SCRATCH_LOCKS"
export BATON_RUNS_DIR="$SCRATCH_RUNS"
cleanup() {
  chmod 755 "$SCRATCH_LOCKS" 2>/dev/null || true
  rm -rf "$SCRATCH_LOCKS" "$SCRATCH_RUNS" "$STUBBIN"
  [ -n "${HELPER_PID:-}" ] && kill -KILL "$HELPER_PID" 2>/dev/null
  [ -n "${VICTIM_PID:-}" ] && kill -KILL "$VICTIM_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

ok()   { if [ "$2" -eq 0 ]; then record_pass "unit:lock:$1"; else record_fail "unit:lock:$1" "${3:-failed}"; fi; }
eq()   { if [ "$2" = "$3" ]; then record_pass "unit:lock:$1"; else record_fail "unit:lock:$1" "expected [$3] got [$2]"; fi; }

# _lock_plant SUBJECT PID FINGERPRINT -- install a PRE-EXISTING owner record
# for a process this shell did not start. It bypasses the generation gate on
# purpose: the point is to reproduce the state a crashed or foreign holder
# leaves behind, which is exactly an owner record with no live claimer of
# ours. Every planted record is stamped prov=test by the export above.
_lock_plant() { _lock_write_owner "$1" "$2" "$3"; }

# A live process that is NOT this shell, used as a foreign lock holder.
sleep 300 & HELPER_PID=$!
HELPER_FP="$(runs_fingerprint "$HELPER_PID")"

# ---------------------------------------------------------------------------
# Subject handling: the parameter that makes this one lock root, not two.
# ---------------------------------------------------------------------------
# An empty subject is refused, not silently mapped to a shared global lock --
# that would serialize every unrelated caller onto one file.
lock_claim "" >/dev/null 2>&1; eq "empty-subject-is-could-not-inspect" "$?" "2"

# A subject is arbitrary operator/session text and becomes a path. It must not
# be able to name a directory outside the lock root.
lock_claim "../../etc/passwd" >/dev/null 2>&1
ok "traversal-subject-stays-inside-lock-root" \
  "$([ -z "$(find "$SCRATCH_LOCKS/.." -maxdepth 1 -name 'passwd*' 2>/dev/null)" ]; echo $?)"

# ---------------------------------------------------------------------------
# Claim / probe / refuse
# ---------------------------------------------------------------------------
lock_claim "session:abc-123" >/dev/null 2>&1; eq "claim-free-subject-exits-0" "$?" "0"
eq "claim-records-our-pid" "$LOCK_HOLDER_PID" "$$"

lock_probe "session:abc-123" >/dev/null 2>&1; probe_rc=$?
eq "probe-held-exits-1" "$probe_rc" "1"
eq "probe-state-is-held" "$LOCK_STATE" "held"
eq "probe-names-the-holder-pid" "$LOCK_HOLDER_PID" "$$"
# Silence is not evidence: a probe that inspected nothing must not read as a
# free lock. Every determinate answer states how many subjects it inspected.
eq "probe-asserts-it-inspected-one-subject" "$LOCK_INSPECTED" "1"
eq "lock-is-stamped-test-provenance" "$LOCK_HOLDER_PROV" "test"

# The same process re-entering its own lock is not a second writer.
lock_claim "session:abc-123" >/dev/null 2>&1; eq "self-reclaim-is-not-a-refusal" "$?" "0"

# A DIFFERENT subject is independent -- one root, many subjects.
lock_claim "unit:night-20260825T000000Z-1-a" >/dev/null 2>&1
eq "second-subject-is-independent" "$?" "0"

# ---------------------------------------------------------------------------
# A live foreign holder is refused, and the refusal NAMES the holding pid.
# ---------------------------------------------------------------------------
_lock_plant "session:foreign" "$HELPER_PID" "$HELPER_FP"
msg="$(lock_claim "session:foreign" 2>&1)"; rc=$?
eq "live-foreign-holder-refused-nonzero" "$rc" "1"
ok "refusal-message-names-the-holder-pid" \
  "$(printf '%s' "$msg" | grep -q "$HELPER_PID"; echo $?)" "message was: $msg"
# The refusal must not hand the operator a runnable command line (issue #2
# root cause 2's rule: a shared stream may say what happened, never what to
# type).
ok "refusal-message-carries-no-runnable-baton-command" \
  "$(! printf '%s' "$msg" | grep -qE '(^|[^-])baton +[a-z-]'; echo $?)" "message was: $msg"

# ---------------------------------------------------------------------------
# Staleness: the two ways an owner stops being an owner.
# ---------------------------------------------------------------------------
# (a) the owner pid is CONFIRMED gone.
DEAD_PID="$( (exec sh -c 'echo $$') )"
sleep 0.1
_lock_plant "session:dead-owner" "$DEAD_PID" "whatever it was 1999"
lock_probe "session:dead-owner" >/dev/null 2>&1
eq "dead-owner-probe-exits-0" "$?" "0"
eq "dead-owner-state-is-stale-dead" "$LOCK_STATE" "stale-dead"
lock_claim "session:dead-owner" >/dev/null 2>&1
eq "dead-owner-lock-is-reclaimable" "$?" "0"
eq "reclaim-installs-us-as-owner" "$LOCK_HOLDER_PID" "$$"

# (b) the owner pid is LIVE but carries a foreign fingerprint. This is pid
# reuse across a reboot: the number is busy, but not with our process. A bare
# pid in a lockfile would deadlock this subject forever.
_lock_plant "session:reused-pid" "$HELPER_PID" "Mon Jan  1 00:00:00 1999 sleep 99999"
lock_probe "session:reused-pid" >/dev/null 2>&1
eq "reused-pid-probe-exits-0" "$?" "0"
eq "reused-pid-state-is-stale-foreign" "$LOCK_STATE" "stale-foreign"
lock_claim "session:reused-pid" >/dev/null 2>&1
eq "reused-pid-lock-is-reclaimable" "$?" "0"

# A released lock is free again, and its release is recorded rather than the
# record being deleted (an absent record and an unreadable one must not look
# alike).
lock_release "session:abc-123" >/dev/null 2>&1; eq "release-exits-0" "$?" "0"
lock_probe "session:abc-123" >/dev/null 2>&1
eq "released-lock-probe-exits-0" "$?" "0"
eq "released-lock-state-is-free" "$LOCK_STATE" "free"
eq "released-lock-still-inspected-one-subject" "$LOCK_INSPECTED" "1"
lock_claim "session:abc-123" >/dev/null 2>&1; eq "released-lock-is-reclaimable" "$?" "0"

# We never release someone else's live lock.
lock_release "session:foreign" >/dev/null 2>&1; rc=$?
eq "release-of-a-foreign-live-lock-refuses" "$rc" "1"
lock_probe "session:foreign" >/dev/null 2>&1
eq "foreign-live-lock-survives-our-release" "$LOCK_STATE" "held"

# ---------------------------------------------------------------------------
# COULD NOT INSPECT is a real third answer. Exit 2 is not a pass and not a
# free lock.
# ---------------------------------------------------------------------------
# (a) the process table cannot be reached: a live holder would otherwise read
# as dead and get its lock stolen.
cat > "$STUBBIN/ps" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STUBBIN/ps"
( PATH="$STUBBIN:$PATH"; lock_probe "session:foreign" >/dev/null 2>&1; echo "$? $LOCK_STATE" ) > "$SCRATCH_RUNS/noprobe"
eq "no-ps-probe-exits-2" "$(awk '{print $1}' "$SCRATCH_RUNS/noprobe")" "2"
eq "no-ps-state-is-could-not-inspect" "$(awk '{print $2}' "$SCRATCH_RUNS/noprobe")" "could-not-inspect"
( PATH="$STUBBIN:$PATH"; lock_claim "session:foreign" >/dev/null 2>&1; echo "$?" ) > "$SCRATCH_RUNS/noclaim"
eq "no-ps-claim-exits-2-not-0" "$(cat "$SCRATCH_RUNS/noclaim")" "2"
# and the foreign holder's record was NOT overwritten by that attempt.
lock_probe "session:foreign" >/dev/null 2>&1
eq "could-not-inspect-never-steals-the-lock" "$LOCK_HOLDER_PID" "$HELPER_PID"

# (b) the lock directory itself is unreadable.
UNREADABLE="$SCRATCH_LOCKS/sealed"
mkdir -p "$UNREADABLE"
chmod 000 "$UNREADABLE"
( export BATON_LOCK_DIR="$UNREADABLE"; lock_probe "session:x" >/dev/null 2>&1; echo "$? $LOCK_STATE $LOCK_INSPECTED" ) > "$SCRATCH_RUNS/sealed"
chmod 755 "$UNREADABLE"
eq "unreadable-lock-dir-probe-exits-2" "$(awk '{print $1}' "$SCRATCH_RUNS/sealed")" "2"
eq "unreadable-lock-dir-state-is-could-not-inspect" "$(awk '{print $2}' "$SCRATCH_RUNS/sealed")" "could-not-inspect"
eq "unreadable-lock-dir-inspected-zero-subjects" "$(awk '{print $3}' "$SCRATCH_RUNS/sealed")" "0"

# ---------------------------------------------------------------------------
# lock_hold: the claim and the work it guards are one statement, so a claim
# can never outlive or undershoot the thing it was taken for.
# ---------------------------------------------------------------------------
lock_hold "unit:held-work" -- sh -c 'exit 3' >/dev/null 2>&1
eq "lock_hold-propagates-the-child-exit-code" "$?" "3"
lock_probe "unit:held-work" >/dev/null 2>&1
eq "lock_hold-released-the-lock-afterwards" "$LOCK_STATE" "free"

_lock_plant "unit:busy-work" "$HELPER_PID" "$HELPER_FP"
out="$(lock_hold "unit:busy-work" -- sh -c 'echo RAN' 2>&1)"; rc=$?
eq "lock_hold-refuses-when-held" "$rc" "1"
ok "lock_hold-did-not-run-the-guarded-command" \
  "$(! printf '%s' "$out" | grep -q RAN; echo $?)" "output was: $out"

# ---------------------------------------------------------------------------
# lock_kill_orphan: the orphan-kill rule. A reconcile that redoes a unit kills
# the matched orphan and CONFIRMS its death by re-probing, never by assuming
# the signal landed.
# ---------------------------------------------------------------------------
sleep 300 & VICTIM_PID=$!
# Off the job table: this process is killed on purpose mid-script, and bash's
# async "Terminated" notice on stderr would otherwise read like a test error.
disown "$VICTIM_PID" 2>/dev/null || true
VICTIM_FP="$(runs_fingerprint "$VICTIM_PID")"
runs_record_start "orphan-unit" "$VICTIM_PID" "$VICTIM_FP" "sleep 300"
lock_kill_orphan "orphan-unit" >/dev/null 2>&1
eq "kill_orphan-confirms-the-death-exits-0" "$?" "0"
eq "kill_orphan-reports-that-it-killed" "$LOCK_KILLED" "yes"
eq "kill_orphan-re-probe-says-gone" "$(runs_alive "$VICTIM_PID" "$VICTIM_FP")" "no"

# An already-dead unit is confirmed gone without a signal being sent.
lock_kill_orphan "orphan-unit" >/dev/null 2>&1
eq "kill_orphan-on-a-corpse-exits-0" "$?" "0"
eq "kill_orphan-on-a-corpse-sends-no-signal" "$LOCK_KILLED" "no"

# A unit whose recorded pid is now held by a STRANGER must never be signalled.
# The fingerprint is the only thing standing between a reconcile and killing
# an unrelated process that inherited the number.
runs_record_start "stranger-unit" "$HELPER_PID" "Mon Jan  1 00:00:00 1999 sleep 99999" "sleep 300"
lock_kill_orphan "stranger-unit" >/dev/null 2>&1
eq "kill_orphan-does-not-signal-a-pid-reuse-stranger" "$LOCK_KILLED" "no"
ok "the-stranger-process-is-still-alive" "$(kill -0 "$HELPER_PID" 2>/dev/null; echo $?)"

# A unit with no start receipt has no process of ours to kill, and says so
# rather than reporting a kill it never performed.
lock_kill_orphan "no-such-unit" >/dev/null 2>&1
eq "kill_orphan-with-no-receipt-exits-0" "$?" "0"
eq "kill_orphan-with-no-receipt-killed-nothing" "$LOCK_KILLED" "no"

# Could-not-confirm is exit 2, never a green light to launch a replacement.
runs_record_start "unprobeable-unit" "$HELPER_PID" "$HELPER_FP" "sleep 300"
( PATH="$STUBBIN:$PATH"; lock_kill_orphan "unprobeable-unit" >/dev/null 2>&1; echo "$? $LOCK_KILLED" ) > "$SCRATCH_RUNS/unconfirmed"
eq "kill_orphan-cannot-confirm-exits-2" "$(awk '{print $1}' "$SCRATCH_RUNS/unconfirmed")" "2"
eq "kill_orphan-cannot-confirm-killed-nothing" "$(awk '{print $2}' "$SCRATCH_RUNS/unconfirmed")" "no"

# ---------------------------------------------------------------------------
# The reporter and the acquirer read one lock root by ONE rule.
#
# They used to disagree: a root that cannot exist made lock_probe skip its
# check entirely (the `[ -e ]` guard was false) and fall through to a
# determinate `free`, while lock_claim's `mkdir -p` correctly refused it. The
# reporter is the one that gets asserted on, so the disagreement made every
# "nothing is locked" row vacuous.
# ---------------------------------------------------------------------------
( export BATON_LOCK_DIR=/dev/null/nope; lock_probe "session:x" >/dev/null 2>&1; echo "$? $LOCK_STATE $LOCK_INSPECTED" ) > "$SCRATCH_RUNS/impossible"
eq "impossible-lock-root-probe-exits-2" "$(awk '{print $1}' "$SCRATCH_RUNS/impossible")" "2"
eq "impossible-lock-root-is-could-not-inspect" "$(awk '{print $2}' "$SCRATCH_RUNS/impossible")" "could-not-inspect"
( export BATON_LOCK_DIR=/dev/null/nope; lock_claim "session:x" >/dev/null 2>&1; echo "$?" ) > "$SCRATCH_RUNS/impossible-claim"
eq "impossible-lock-root-claim-exits-2" "$(cat "$SCRATCH_RUNS/impossible-claim")" "2"

# ...and "not there yet" stays a determinate answer, or a first-ever run could
# never launch anything.
( export BATON_LOCK_DIR="$SCRATCH_RUNS/never-made"; lock_probe "session:x" >/dev/null 2>&1; echo "$? $LOCK_STATE" ) > "$SCRATCH_RUNS/absent"
eq "absent-but-creatable-root-is-determinate" "$(awk '{print $1}' "$SCRATCH_RUNS/absent")" "0"
eq "absent-but-creatable-root-reads-free" "$(awk '{print $2}' "$SCRATCH_RUNS/absent")" "free"

# LOCK_INSPECTED counts owner records actually read. A subject that has never
# been locked has no record, so the honest count is zero -- it used to report
# 1, which is what made "it inspected more than zero subjects" provable about
# a subject that had never existed.
lock_probe "session:never-locked-at-all" >/dev/null 2>&1
eq "never-locked-subject-inspected-zero" "$LOCK_INSPECTED" "0"
eq "never-locked-subject-still-reads-free" "$LOCK_STATE" "free"

# ---------------------------------------------------------------------------
# The escape hatch is loud. BATON_LOCK_DISABLE=1 used to set a state nobody
# read and return in silence.
# ---------------------------------------------------------------------------
msg="$( BATON_LOCK_DISABLE=1 lock_claim "unit:unguarded" 2>&1 )"
ok "bypassed-claim-warns-on-stderr" $([ -n "$msg" ]; echo $?) "the bypass said nothing"
ok "bypassed-claim-names-the-knob" $(printf '%s' "$msg" | grep -q BATON_LOCK_DISABLE; echo $?)
( export BATON_LOCK_DISABLE=1; lock_probe "unit:unguarded" >/dev/null 2>&1; echo "$LOCK_STATE" ) > "$SCRATCH_RUNS/bypassed"
eq "bypassed-probe-reports-bypassed-not-free" "$(cat "$SCRATCH_RUNS/bypassed")" "bypassed"

# ---------------------------------------------------------------------------
# lock_subject_for_argv: only an EXPLICIT --resume <id> is keyable. A guessed
# key would serialize unrelated launches onto one subject, which is worse than
# leaving a cold start unguarded.
# ---------------------------------------------------------------------------
eq "argv-subject-from-separate-resume-arg" "$(lock_subject_for_argv --resume abc123)" "session:abc123"
eq "argv-subject-from-equals-form" "$(lock_subject_for_argv --resume=abc123)" "session:abc123"
eq "argv-subject-found-after-other-args" "$(lock_subject_for_argv --model x --resume abc123 -c)" "session:abc123"
lock_subject_for_argv -c >/dev/null 2>&1
ok "argv-with-no-resume-implies-no-subject" $([ "$?" -ne 0 ]; echo $?)
lock_subject_for_argv --resume >/dev/null 2>&1
ok "dangling-resume-implies-no-subject" $([ "$?" -ne 0 ]; echo $?)
lock_subject_for_argv --resume "" >/dev/null 2>&1
ok "empty-resume-id-implies-no-subject" $([ "$?" -ne 0 ]; echo $?)

# ---------------------------------------------------------------------------
# lock_report: the enumerating reporter, whose count can come back ZERO. That
# is the whole point -- `--lock-status <subject>` can only ever answer 0 or 1
# about the one name it was handed, so it can never be evidence about a board.
# ---------------------------------------------------------------------------
EMPTY_ROOT="$SCRATCH_RUNS/empty-lock-root"
mkdir -p "$EMPTY_ROOT"
( export BATON_LOCK_DIR="$EMPTY_ROOT"; lock_report >/dev/null 2>&1; echo "$?" ) > "$SCRATCH_RUNS/report-empty"
eq "report-on-an-empty-root-exits-1-not-0" "$(cat "$SCRATCH_RUNS/report-empty")" "1"
( export BATON_LOCK_DIR=/dev/null/nope; lock_report >/dev/null 2>&1; echo "$?" ) > "$SCRATCH_RUNS/report-impossible"
eq "report-on-an-unusable-root-exits-2" "$(cat "$SCRATCH_RUNS/report-impossible")" "2"
lock_report >/dev/null 2>&1
ok "report-on-a-populated-root-exits-0" $?
eq "report-counts-every-subject-on-disk" \
  "$(lock_report 2>/dev/null | sed -n 's/^baton: inspected \([0-9]*\) lock subject.*/\1/p')" \
  "$(ls -d "$SCRATCH_LOCKS"/*.lock 2>/dev/null | wc -l | tr -d ' ')"
