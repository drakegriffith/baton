#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): --night's three numeric env knobs
# are adversarial inputs, and a typo in any of them used to fail PAST the
# module's error contract rather than into it. Measured before the fix:
#   BATON_WATCH_INTERVAL=abc      -> `sleep abc` failed every poll, so the
#     watcher span at ~12% CPU and wrote 87 KB of `sleep: invalid time
#     interval` to stderr in 3 seconds (an overnight run writes gigabytes).
#   BATON_MAX_HANDOFFS=abc        -> `[ 1 -gt abc ]` leaked
#     `lib/watch.sh: line 156: [: abc: integer expression expected` and the
#     cap then never tripped: unbounded handoffs.
#   BATON_SESSION_WAIT_SECS=abc   -> the awk give-up comparison silently
#     never fired, so the --resume fallback to `-c` was disabled.
# All three must now die before any child is launched. An unset or empty
# knob keeps its documented default (that is what `${VAR:-default}` means),
# and 0 stays a legal value for the two second-counts.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "18-night-env-knobs"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("should never run")
EOF

knob_refused() { # $1 var, $2 value
  local out rc
  out=$(env "$1=$2" "$BATON_BIN" --night 2>&1); rc=$?
  scenario_check "$1=[$2] exits nonzero" $([ "$rc" -ne 0 ]; echo $?)
  scenario_check "$1=[$2] names the knob on stderr" $(printf '%s' "$out" | grep -q "$1"; echo $?)
  scenario_check "$1=[$2] leaks no raw shell error" \
    $(! printf '%s' "$out" | grep -qE "integer expression|invalid time interval|line [0-9]+:"; echo $?)
  scenario_check "$1=[$2] launched no child at all" $([ "$(invocation_count a)" -eq 0 ]; echo $?)
}

knob_refused BATON_WATCH_INTERVAL abc
knob_refused BATON_WATCH_INTERVAL -1
knob_refused BATON_WATCH_INTERVAL 1.2.3
knob_refused BATON_MAX_HANDOFFS abc
knob_refused BATON_MAX_HANDOFFS -1
knob_refused BATON_MAX_HANDOFFS 1.5
knob_refused BATON_SESSION_WAIT_SECS abc
knob_refused BATON_SESSION_WAIT_SECS -30

# ... and the legal values still run. BATON_SESSION_WAIT_SECS=0 means "do
# not wait for a transcript at all", which is the boundary value of the
# documented fallback: the handoff must still happen, using -c instead of
# --resume <id> because no session id was ever discovered.
cleanup_root
fresh_root
write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF
export BATON_SESSION_WAIT_SECS=0
start_night
wait_for_night_exit 15
scenario_check "SESSION_WAIT_SECS=0 still completes the run" $?
scenario_check "SESSION_WAIT_SECS=0 handed off to b" $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)
unset BATON_SESSION_WAIT_SECS

cleanup_root
scenario_end
