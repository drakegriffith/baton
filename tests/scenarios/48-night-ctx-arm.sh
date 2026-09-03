#!/usr/bin/env bash
# The night-mode orchestrator context arm (features/failover.feature D8).
#
# `--night` runs unmonitored, so its child is armed to park and compact well
# before the context window ends rather than at the last possible moment.
# The arm is scoped to --night ONLY: a plain `baton` is an argv and env
# passthrough (scenario 19) and must stay one, and an operator who has
# already made either decision keeps it. All four are separately falsifiable,
# so all four are separate phases here.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "48-night-ctx-arm"

# launch_line ACCOUNT ARGV_SUBSTRING -- the fake-claude log line for the
# launch that carried ARGV_SUBSTRING (a probe and a launch both write lines
# under the same config dir, so the join is on argv, never on "the last
# line").
launch_line() {
  grep "config=$(config_dir_of "$1") " "$(fake_log)" 2>/dev/null | grep -F -- "$2" | tail -1
}
# ctx_of ACCOUNT ARGV_SUBSTRING -- the CLAUDE_CTX_* environment that exact
# invocation was handed, joined by invocation number.
ctx_of() {
  local line inv
  line="$(launch_line "$1" "$2")"
  inv=$(printf '%s' "$line" | sed -n 's/^inv=\([0-9]*\) .*/\1/p')
  [ -n "$inv" ] || return 0
  grep "^inv=$inv " "$(config_dir_of "$1")/.fake-env" 2>/dev/null | tail -1
}

# --- 1. plain baton arms nothing ------------------------------------------
fresh_root
write_behavior a <<'EOF'
STEP_STDOUT=("plain run")
EOF
"$BATON_BIN" --print plainarg >/dev/null 2>&1
plain_line="$(launch_line a plainarg)"
plain_ctx="$(ctx_of a plainarg)"
scenario_check "1: the plain launch was found in the log" \
  $([ -n "$plain_line" ]; echo $?)
scenario_check "1: the plain launch's env was recorded (subject exists)" \
  $([ -n "$plain_ctx" ]; echo $?)
scenario_check "1: plain baton set no CLAUDE_CTX_ variable" \
  $(! printf '%s' "$plain_ctx" | grep -q 'CLAUDE_CTX_'; echo $?)
scenario_check "1: plain baton appended no --autocompact" \
  $(! printf '%s' "$plain_line" | grep -q -- '--autocompact'; echo $?)
cleanup_root

# --- 2. --night arms all four vars and the autocompact flag ---------------
fresh_root
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("night run")
EOF
start_night --print nightarg
wait_for_night_exit 15
scenario_check "2: the night run finished" $?
night_line="$(launch_line a nightarg)"
night_ctx="$(ctx_of a nightarg)"
scenario_check "2: the night launch was found in the log" \
  $([ -n "$night_line" ]; echo $?)
scenario_check "2: the night launch's env was recorded (subject exists)" \
  $([ -n "$night_ctx" ]; echo $?)
scenario_check "2: CLAUDE_CTX_ENFORCE=1" \
  $(printf '%s' "$night_ctx" | grep -q 'CLAUDE_CTX_ENFORCE=1'; echo $?)
scenario_check "2: CLAUDE_CTX_PARK=95000" \
  $(printf '%s' "$night_ctx" | grep -q 'CLAUDE_CTX_PARK=95000'; echo $?)
scenario_check "2: CLAUDE_CTX_CAP=100000" \
  $(printf '%s' "$night_ctx" | grep -q 'CLAUDE_CTX_CAP=100000'; echo $?)
scenario_check "2: CLAUDE_CTX_ORCHESTRATOR=1" \
  $(printf '%s' "$night_ctx" | grep -q 'CLAUDE_CTX_ORCHESTRATOR=1'; echo $?)
scenario_check "2: the child argv carries --autocompact 100k" \
  $(printf '%s' "$night_line" | grep -q -- '--autocompact 100k'; echo $?)
scenario_check "2: the operator's own args survived the arm" \
  $(printf '%s' "$night_line" | grep -q -- 'nightarg'; echo $?)
cleanup_root

# --- 3. BATON_NIGHT_CTX_ARM=0 turns both halves off -----------------------
fresh_root
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("unarmed night run")
EOF
export BATON_NIGHT_CTX_ARM=0
start_night --print unarmedarg
wait_for_night_exit 15
scenario_check "3: the unarmed night run finished" $?
unarmed_line="$(launch_line a unarmedarg)"
unarmed_ctx="$(ctx_of a unarmedarg)"
scenario_check "3: the unarmed launch's env was recorded (subject exists)" \
  $([ -n "$unarmed_ctx" ]; echo $?)
scenario_check "3: no CLAUDE_CTX_ variable was set" \
  $(! printf '%s' "$unarmed_ctx" | grep -q 'CLAUDE_CTX_'; echo $?)
scenario_check "3: no --autocompact was appended" \
  $(! printf '%s' "$unarmed_line" | grep -q -- '--autocompact'; echo $?)
unset BATON_NIGHT_CTX_ARM
cleanup_root

# --- 4. the operator's own choices are never overridden -------------------
fresh_root
write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("operator run")
EOF
export CLAUDE_CTX_ENFORCE=0
start_night --print operatorarg --autocompact 200k
wait_for_night_exit 15
scenario_check "4: the operator night run finished" $?
op_line="$(launch_line a operatorarg)"
op_ctx="$(ctx_of a operatorarg)"
scenario_check "4: the operator launch's env was recorded (subject exists)" \
  $([ -n "$op_ctx" ]; echo $?)
scenario_check "4: an operator-set CLAUDE_CTX_ENFORCE=0 is left alone" \
  $(printf '%s' "$op_ctx" | grep -q 'CLAUDE_CTX_ENFORCE=0'; echo $?)
scenario_check "4: the arm did not fire at all when the operator had decided" \
  $(! printf '%s' "$op_ctx" | grep -q 'CLAUDE_CTX_PARK='; echo $?)
n_autocompact=$(printf '%s' "$op_line" | grep -o -- '--autocompact' | grep -c .)
scenario_check "4: --autocompact appears exactly once (got $n_autocompact)" \
  $([ "$n_autocompact" -eq 1 ]; echo $?)
scenario_check "4: the operator's own 200k value survived" \
  $(printf '%s' "$op_line" | grep -q -- '--autocompact 200k'; echo $?)
unset CLAUDE_CTX_ENFORCE
cleanup_root

scenario_end
