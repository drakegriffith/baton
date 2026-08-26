#!/usr/bin/env bash
# Gherkin: "Plain baton still execs and never watches". QA-DOC section 5 row
# 11: prove exec (not fork) via PPID, and prove no watch-only side effects.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "11-plain-baton-execs"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("plain run")
EOF

# `exec` replaces the process image without forking: the fake claude that
# ends up running keeps baton's OWN pid, and its PPID is whatever forked
# baton in the first place (this test script's own $$). A forking launcher
# would instead show the fake claude with a fresh pid whose PPID is baton's
# pid.
this_pid=$$
"$BATON_BIN" some-arg >"$SCRATCH/stdout.log" 2>"$SCRATCH/stderr.log" &
BATON_PID=$!
wait "$BATON_PID"
baton_exit=$?

pidfile="$(config_dir_of a)/.fake-pid-ppid"
scenario_check "fake claude wrote its pid/ppid" $([ -s "$pidfile" ]; echo $?)
child_pid=$(awk '{print $1}' "$pidfile")
child_ppid=$(awk '{print $2}' "$pidfile")
scenario_check "the running process kept baton's own PID (exec, not fork)" $([ "$child_pid" = "$BATON_PID" ]; echo $?)
scenario_check "its PPID is this test's own PID (no extra generation)" $([ "$child_ppid" = "$this_pid" ]; echo $?)
scenario_check "baton exited with the child's exit code" $([ "$baton_exit" -eq 0 ]; echo $?)
scenario_check "no sigterm/kill marker (no watching happened)" $(! [ -s "$(signals_log_of a)" ]; echo $?)
# "handoff:" with the colon -- same note as scenario 09. Since issue #2 a
# bare "handoff" also matches the handoff-LOG path the AUTH branch names on
# stderr, which is not handoff-related output; it is a pointer to where
# instructions were written instead of printed.
scenario_check "no handoff-related output on stderr" $(! grep -qi "handoff:\|night mode\|no live account" "$SCRATCH/stderr.log"; echo $?)

cleanup_root
scenario_end
