#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): baton is an argv passthrough in
# both modes, and nothing in the suite pinned that. Plain `baton ARGS...`
# must hand ARGS to claude untouched, and `baton --night ARGS...` must hand
# the same ARGS on WITHOUT its own --night flag (the `shift` in the dispatch
# arm) and without the resume flags leaking into the first launch. Kills the
# auto_launch "drop the args" mutant and watch's "--night not shifted"
# mutant (M36).
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "19-arg-passthrough"
fresh_root

write_behavior a <<'EOF'
STEP_STDOUT=("plain run")
EOF

"$BATON_BIN" --print "hello world" --flag=1 >/dev/null 2>&1
log="$(fake_log)"
line=$(grep "config=$(config_dir_of a) " "$log" | tail -1)
scenario_check "plain baton forwarded --print" $(printf '%s' "$line" | grep -q -- "argv=--print"; echo $?)
scenario_check "plain baton forwarded the quoted arg" $(printf '%s' "$line" | grep -q "hello"; echo $?)
scenario_check "plain baton forwarded --flag=1" $(printf '%s' "$line" | grep -q -- "--flag=1"; echo $?)
scenario_check "plain baton did not invent extra flags" $(! printf '%s' "$line" | grep -qE "argv=(-c|--resume|-p) "; echo $?)

cleanup_root
fresh_root
write_behavior a <<'EOF'
STEP_EXIT=(4)
STEP_STDOUT=("night run")
EOF

start_night --print "night arg" --flag=2
wait_for_night_exit 15
scenario_check "night process exited" $?
scenario_check "night propagated the child's exit code" $([ "${NIGHT_EXIT:-0}" -eq 4 ]; echo $?)
log="$(fake_log)"
line=$(grep "config=$(config_dir_of a) " "$log" | head -1)
scenario_check "night forwarded --print" $(printf '%s' "$line" | grep -q -- "argv=--print"; echo $?)
scenario_check "night forwarded --flag=2" $(printf '%s' "$line" | grep -q -- "--flag=2"; echo $?)
scenario_check "night did NOT pass its own --night flag through" $(! printf '%s' "$line" | grep -q -- "--night"; echo $?)
scenario_check "first night launch carried no resume flag" $(! printf '%s' "$line" | grep -qE "argv=(-c|--resume) "; echo $?)

cleanup_root
scenario_end
