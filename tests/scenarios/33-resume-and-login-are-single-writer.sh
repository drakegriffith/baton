#!/usr/bin/env bash
# baton#2 root cause 1 (on the real resume path) and root cause 3 (serialize
# login flows), through the two entry points the 2026-08-25 incident actually
# used.
#
# Part A -- the --night handoff. All accounts share projects/ through the
# harness symlink, so one session id names ONE transcript that any account can
# reopen. That is what makes two simultaneous `--resume <id>` launches
# possible; one absorbs the session, the other clobbers the pointer state
# (account a's .claude.json came back a 423-byte stub). The watcher must
# refuse to be the second writer and must say who the first one is.
#
# Part B -- `baton <account>`. That is baton's login flow: it is verbatim the
# command the not-logged-in handoff tells the operator to run, and two of them
# at once is two OAuth refreshes rotating each other's token. The subject is
# GLOBAL (`login`), not per-account: the issue says "one at a time", and
# baton cannot see the `/login` typed inside the session it launches, so it
# treats every forced launch as one.
# It also proves the lock survives `exec`: the holder's command line becomes
# `claude ...`, and only pid+start-time identity still recognises it.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "33-resume-and-login-are-single-writer"
fresh_root
export BATON_LOCK_PROV=test

SID="sess-contested"

# --- Part A ----------------------------------------------------------------
# A live foreign process already holds the session the handoff is about to
# resume. Planted through the real CLI, so nothing here knows the lock's file
# format.
"$BATON_BIN" --claim "session:$SID" -- sleep 30 >/dev/null 2>&1 &
HOLDER=$!
waited=0
while [ ! -e "$BATON_ACCOUNTS_ROOT/.locks/session_$SID.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done
scenario_check "the contested session lock is held before --night starts" \
  $([ -e "$BATON_ACCOUNTS_ROOT/.locks/session_$SID.lock/owner" ]; echo $?)

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-contested")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(9)
STEP_STDOUT=("done from b")
EOF

start_night
f=$(wait_for_transcript a 10)
scenario_check "account a's transcript appeared" $([ -n "$f" ]; echo $?)
printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$f"

wait_for_night_exit 15
scenario_check "the --night run terminated rather than hanging" $?

err="$(night_stderr)"
scenario_check "the run exited nonzero rather than resuming as a second writer" \
  $([ "${NIGHT_EXIT:-0}" -ne 0 ]; echo $?)
scenario_check "stderr names the holding pid" \
  $(printf '%s' "$err" | grep -q "$HOLDER"; echo $?)
scenario_check "stderr names the contested session id" \
  $(printf '%s' "$err" | grep -q "$SID"; echo $?)
# The load-bearing consequence: the second writer never reached the CLI.
scenario_check "account b was never launched with --resume on the locked session" \
  $(! grep -q -- "--resume $SID" "$(fake_log)"; echo $?)

# The handoff up to that point still happened -- this refuses a resume, it
# does not disable failover.
scenario_check "account a was still marked dead for its limit" $(is_dead_marked a; echo $?)

kill -KILL "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
kill_fake_claude a
kill_fake_claude b

# Once the holder is gone the session is reclaimable: a refusal must not
# retire a session id permanently.
sleep 0.3
after="$("$BATON_BIN" --lock-status "session:$SID" 2>&1)"; afterrc=$?
scenario_check "the contested session is reclaimable once its holder dies" \
  $([ "$afterrc" -eq 0 ]; echo $?)
scenario_check "and it reports how many subjects it inspected" \
  $(printf '%s' "$after" | grep -qE 'inspected=[1-9][0-9]*'; echo $?)

cleanup_root

# --- Part B: the login flow ------------------------------------------------
fresh_root
export BATON_LOCK_PROV=test

write_behavior a <<'EOF'
STEP_BLOCK=(1 1)
STEP_STDOUT=("session one" "session two")
EOF

# `baton a` execs, so this pid IS the running claude session's pid.
"$BATON_BIN" a >"$SCRATCH/login1.out" 2>"$SCRATCH/login1.err" &
LOGIN1=$!
waited=0
while [ ! -e "$BATON_ACCOUNTS_ROOT/.locks/login.lock/owner" ]; do
  sleep 0.1; waited=$((waited + 1)); [ "$waited" -gt 100 ] && break
done
scenario_check "the first login flow took the global login lock" \
  $([ -e "$BATON_ACCOUNTS_ROOT/.locks/login.lock/owner" ]; echo $?)

# The exec has replaced baton's command line with claude's. Only pid + start
# time still identify the holder; a fingerprint match on the command line
# would read this as pid reuse and hand the lock away.
sleep 0.5
status="$("$BATON_BIN" --lock-status login 2>&1)"; strc=$?
scenario_check "the login lock survives the exec into claude (still held)" \
  $([ "$strc" -eq 1 ]; echo $?)
scenario_check "and it still names the same pid after the exec" \
  $(printf '%s' "$status" | grep -q "holder_pid=$LOGIN1"; echo $?)

before_invocations="$(invocation_count a)"
"$BATON_BIN" a >"$SCRATCH/login2.out" 2>"$SCRATCH/login2.err"
login2_rc=$?
scenario_check "a second concurrent login flow for the same account exits nonzero" \
  $([ "$login2_rc" -ne 0 ]; echo $?)
scenario_check "the second login flow names the holding pid" \
  $(grep -q "$LOGIN1" "$SCRATCH/login2.err"; echo $?)
scenario_check "the second login flow never launched a second claude" \
  $([ "$(invocation_count a)" -eq "$before_invocations" ]; echo $?)

# DELIBERATE INVERSION of what this row used to assert, driven by a design
# decision and disclosed as such rather than quietly adjusted. It read
# "another account's login subject is independent and free" (the per-account
# `login:<acct>` subject). The issue says serialize login flows "one at a
# time", and per-account let two DIFFERENT accounts log in concurrently, which
# is not what "one at a time" says and which nothing found is safe. The
# subject is now global, so this asserts the opposite -- and it asserts a
# REFUSAL, which is a positive event, where the old row asserted a free
# subject, which is an absence.
#
# The cost of the inversion is real and is recorded in the commit body: two
# forced launches on different accounts can no longer run at once.
before_b="$(invocation_count b)"
"$BATON_BIN" b >"$SCRATCH/loginb.out" 2>"$SCRATCH/loginb.err"
b_rc=$?
scenario_check "a DIFFERENT account's login flow is refused while one is in flight" \
  $([ "$b_rc" -ne 0 ]; echo $?)
scenario_check "that refusal names the holding pid too" \
  $(grep -q "$LOGIN1" "$SCRATCH/loginb.err"; echo $?)
scenario_check "and it launched no second claude under account b" \
  $([ "$(invocation_count b)" -eq "$before_b" ]; echo $?)
# The global subject is one name, so it reads held no matter which account is
# holding it.
b_status="$("$BATON_BIN" --lock-status login 2>&1)"; bs_rc=$?
scenario_check "the login subject is one global name, held by account a's pid" \
  $([ "$bs_rc" -eq 1 ] && printf '%s' "$b_status" | grep -q "holder_pid=$LOGIN1"; echo $?)

kill -KILL "$LOGIN1" 2>/dev/null
wait "$LOGIN1" 2>/dev/null
kill_fake_claude a
cleanup_root
scenario_end
