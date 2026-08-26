#!/usr/bin/env bash
# Round-3 delta finding 1. The previous round split "did it launch?" on the
# child's EXIT CODE -- 126/127 meant the exec failed, anything else meant it
# ran. That premise is false, and this repo's own fixture is the
# counterexample: tests/fixtures/bin/claude executes perfectly well and then
# returns 127 because a behavior file told it to. A real `claude` may do the
# same. An exit code is application status; it cannot answer a question about
# whether the application ever started.
#
# The question has to be asked BEFORE the fork, where it is still answerable:
# does the executable resolve, and is it executable? After a successful exec
# there is no longer any such thing as "it did not launch" -- there is only a
# program that ran and exited with some number.
#
# So this scenario has two parts, and the second is the one that would have
# passed under the old rule while being wrong.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "43-a-child-that-never-ran-is-not-a-launch"

count_log() { local n; n=$(grep -cE -- "$1" "$HANDOFF_LOG_PATH" 2>/dev/null); printf '%s' "${n:-0}"; }

# --- part A: the executable does not resolve -> no fork at all -------------
fresh_root
HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"

# A PATH with the system utilities baton needs and no `claude` anywhere on
# it. Deliberately NOT "strip the fixtures dir from $PATH": the operator of
# this repo has a real claude installed, and stripping one entry would find
# it and launch the actual CLI.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# Positive control for the setup itself. If a claude IS reachable here, this
# scenario is testing nothing and must say so rather than pass.
if command -v claude >/dev/null 2>&1; then
  echo "43: COULD NOT INSPECT -- a claude is reachable on the reduced PATH" >&2
  cleanup_root
  exit 2
fi

# The alive marks are fresh, so pick_live takes account a without probing --
# which matters, because probing would also need the missing executable and
# the failure under test would be reached by the wrong route.
"$BATON_BIN" --night >"$SCRATCH/nobin.out" 2>"$SCRATCH/nobin.err"
nobin_rc=$?

scenario_check "an unresolvable executable exits nonzero" $([ "$nobin_rc" -ne 0 ]; echo $?)
scenario_check "the handoff log exists" $([ -f "$HANDOFF_LOG_PATH" ]; echo $?)
scenario_check "positive control: the attempt was still recorded (got $(count_log "ATTEMPT:.*'a'"))" \
  $([ "$(count_log "ATTEMPT:.*'a'")" -ge 1 ]; echo $?)
scenario_check "an unresolvable executable leaves NO launch record (got $(count_log 'LAUNCHED:'))" \
  $([ "$(count_log 'LAUNCHED:')" -eq 0 ]; echo $?)
scenario_check "the failure is recorded and names the executable (got $(count_log 'LAUNCH FAILED.*claude'))" \
  $([ "$(count_log 'LAUNCH FAILED.*claude')" -ge 1 ]; echo $?)
# The load-bearing one: not "the child failed" but "there was no child".
scenario_check "no receipt was written, because nothing was forked" \
  $([ -z "$(ls "$BATON_ACCOUNTS_ROOT/.runs" 2>/dev/null)" ]; echo $?)
scenario_check "stderr hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/nobin.err")" -eq 0 ]; echo $?)
cleanup_root

# --- part B: it DID exec, and then exited 127 ------------------------------
# Under the old exit-code rule this logged LAUNCH FAILED / "no session
# started", which is false: the fixture ran, wrote its invocation record, and
# chose its exit status. A launch that happened is a launch.
fresh_root
HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"
write_behavior a <<'EOF'
STEP_EXIT=(127 127)
STEP_STDOUT=("" "")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(127 127)
STEP_STDOUT=("" "")
EOF
start_night
wait_for_night_exit 15
scenario_check "the night run terminated rather than hanging" $?

# Positive control: the child really did run. Without this, "it launched" is
# a claim about a process nobody saw.
scenario_check "positive control: the child actually executed (invocations $(invocation_count a))" \
  $([ "$(invocation_count a)" -ge 1 ]; echo $?)
scenario_check "a child that exec'd and exited 127 IS a launch (got $(count_log 'LAUNCHED:'))" \
  $([ "$(count_log 'LAUNCHED:')" -ge 1 ]; echo $?)
scenario_check "and the log carries the status it exited with (got $(count_log 'already exited 127'))" \
  $([ "$(count_log 'already exited 127')" -ge 1 ]; echo $?)
scenario_check "it is NOT reported as a failed launch (got $(count_log 'LAUNCH FAILED'))" \
  $([ "$(count_log 'LAUNCH FAILED')" -eq 0 ]; echo $?)
scenario_check "positive control: the predicate can see a leak" \
  $([ "$(predicate_positive_control "$SCRATCH/predicate-control.txt")" -eq 3 ]; echo $?)

kill_fake_claude a
kill_fake_claude b
cleanup_root
scenario_end
