#!/usr/bin/env bash
# Tool results never rotate; assistant AUTH must be confirmed on the current
# account before the child is killed. A later real AUTH is the positive control.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "50-transcript-auth-needs-account-evidence"
fresh_root
export BATON_SOFT_SWITCH=0
write_behavior a <<'EOF'
STEP_STDOUT=("ok" "ok" "Invalid API key - Please run /login")
STEP_TRANSCRIPT=("sess-auth-evidence")
STEP_BLOCK=(1)
STEP_BLOCK_TICKS=(150)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
EOF

start_night
f=$(wait_for_transcript a 5)
if [ -z "$f" ]; then
  scenario_check "transcript appeared" 1
  stop_night
  cleanup_root
  scenario_end
  exit 1
fi
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"Invalid API key - Please run /login"}]}}' >> "$f"
sleep 1
scenario_check "tool result did not probe or rotate" $([ "$(invocation_count a)" -eq 1 ] && [ "$(invocation_count b)" -eq 0 ]; echo $?)
scenario_check "tool result did not kill the child" $([ ! -s "$(signals_log_of a)" ]; echo $?)

assistant_line='{"type":"assistant","message":{"content":[{"type":"text","text":"Invalid API key - Please run /login"}]}}'
printf '%s\n' "$assistant_line" >> "$f"
hlog="$BATON_ACCOUNTS_ROOT/.handoff.log"
for tick in {1..50}; do
  grep -q 'false-auth-suppressed' "$hlog" 2>/dev/null && break
  sleep 0.1
done
sleep 0.5
scenario_check "one suppression row, without replay on later polls" $([ "$(grep -c 'false-auth-suppressed' "$hlog")" -eq 1 ]; echo $?)
scenario_check "ALIVE probe kept the same lane" $([ "$(invocation_count a)" -eq 2 ] && [ "$(invocation_count b)" -eq 0 ] && [ ! -s "$(signals_log_of a)" ] && ! is_dead_marked a; echo $?)

printf '%s\n' "$assistant_line" >> "$f"
if wait_for_night_exit 10; then
  scenario_check "confirmed AUTH completed the handoff" 0
else
  scenario_check "confirmed AUTH completed the handoff" 1
  kill_fake_claude a
  kill_fake_claude b
  stop_night
fi
scenario_check "positive control: current account probed again" $([ "$(invocation_count a)" -eq 3 ]; echo $?)
scenario_check "positive control: AUTH killed the child" $([ -s "$(signals_log_of a)" ]; echo $?)
scenario_check "positive control: AUTH dead mark" $([ "$(dead_reason_of a)" = auth ]; echo $?)
scenario_check "positive control: b resumed the original session" $(grep -q -- '--resume sess-auth-evidence' "$(fake_log)"; echo $?)
scenario_check "child exit propagated" $([ "${NIGHT_EXIT:-1}" -eq 0 ]; echo $?)
cleanup_root
scenario_end
