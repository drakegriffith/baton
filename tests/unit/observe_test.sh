#!/usr/bin/env bash
# observe -- the wave-wake observer supervisor baton starts for a lane and
# reaps when the night ends, plus the manual `baton --observe` entry point for
# a terminal launched without PATHWAY_*.
#
# The mechanism is pathway's; baton only pins a target path, a run dir and an
# argv. So every test here drives a FAKE target (tests/fixtures/bin/
# fake-wave-wake) through BATON_WAVE_WAKE_TARGET and never depends on pathway
# being installed on the machine running the suite.
#
# Premise under test (the reason the reap is not a detail): a background child
# started from night_mode SURVIVES run_watched's handoff between accounts and
# is killed EXACTLY ONCE when the night ends. The handoff test below asserts
# both halves -- one start record, one stop record, alive in between.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
: "${RESULTS_FILE:=$(mktemp)}"
: "${BATON_BIN:=$ROOT_DIR/baton}"
: "${FIXTURES_DIR:=$ROOT_DIR/tests/fixtures}"
export BATON_BIN FIXTURES_DIR
. "$FIXTURES_DIR/lib.sh"
chmod +x "$FIXTURES_DIR/bin/fake-wave-wake" 2>/dev/null || true

pass=0; fail=0
check() {
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "PASS observe: $1" >>"$RESULTS_FILE"
  else fail=$((fail+1)); echo "FAIL observe: $1" >>"$RESULTS_FILE"; echo "  FAIL: $1"; fi
}

FAKE_TARGET="$FIXTURES_DIR/bin/fake-wave-wake"
# dirname(dirname(target)) -- the repo root baton puts on PYTHONPATH. Computed
# here from the target path, the same rule the code states, not read back out
# of the code.
FAKE_ROOT="$(dirname "$(dirname "$FAKE_TARGET")")"
OBSERVE_INTERVAL_EXPECTED=60

wait_for_file() { # $1 path $2 timeout-seconds
  local waited=0
  while [ ! -s "$1" ]; do
    sleep 0.1
    waited=$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.1}')
    awk -v w="$waited" -v t="$2" 'BEGIN{exit !(w>=t)}' && return 1
  done
  return 0
}
wait_for_grep() { # $1 pattern $2 file $3 timeout
  local waited=0
  while ! grep -qF "$1" "$2" 2>/dev/null; do
    sleep 0.1
    waited=$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.1}')
    awk -v w="$waited" -v t="$3" 'BEGIN{exit !(w>=t)}' && return 1
  done
  return 0
}
wait_for_gone() { # $1 pid $2 timeout
  local waited=0
  while kill -0 "$1" 2>/dev/null; do
    sleep 0.1
    waited=$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.1}')
    awk -v w="$waited" -v t="$2" 'BEGIN{exit !(w>=t)}' && return 1
  done
  return 0
}
observer_setup() { # fresh scenario root plus the observer's own env
  fresh_root
  unset PATHWAY_PICKUP
  OBS_RUN_DIR="$SCRATCH/wave-run"; mkdir -p "$OBS_RUN_DIR"
  export OBSERVE_FAKE_OUT="$SCRATCH/observer-record.txt"
  export BATON_WAVE_WAKE_TARGET="$FAKE_TARGET"
  HLOG="$BATON_ACCOUNTS_ROOT/.handoff.log"
}
expected_argv() { # $1 run dir
  printf 'arg=observe\narg=--supervise\narg=--run-dir\narg=%s\narg=--interval\narg=%s\n' \
    "$1" "$OBSERVE_INTERVAL_EXPECTED"
}

# --- (a) PATHWAY_PICKUP set: the observer is started, and reaped ------------
observer_setup
export PATHWAY_PICKUP="$OBS_RUN_DIR/pickup.json"; : > "$PATHWAY_PICKUP"
write_behavior a <<'EOF'
STEP_BLOCK=(1)
STEP_BLOCK_TICKS=(15)
STEP_EXIT=(0)
EOF
start_night
wait_for_file "$OBSERVE_FAKE_OUT" 8; check "pickup set: the observer target ran" $?
obs_pid=$(awk -F= '/^pid=/{print $2; exit}' "$OBSERVE_FAKE_OUT")
check "pickup set: argv is exactly the observe contract" \
  $([ "$(grep '^arg=' "$OBSERVE_FAKE_OUT")" = "$(expected_argv "$OBS_RUN_DIR" | grep '^arg=')" ]; echo $?)
check "pickup set: PYTHONPATH is dirname(dirname(target))" \
  $([ "$(awk -F= '/^pythonpath=/{print $2; exit}' "$OBSERVE_FAKE_OUT")" = "$FAKE_ROOT" ]; echo $?)
wait_for_grep "observer up" "$OBS_RUN_DIR/observer.log" 5
check "pickup set: stdout is appended to <run-dir>/observer.log" $?
check "pickup set: handoff log names the pid and the run dir" \
  $(grep -qF "OBSERVER: started pid=$obs_pid run_dir=$OBS_RUN_DIR" "$HLOG"; echo $?)
wait_for_night_exit 20; night_rc=$?
check "pickup set: the night still exited normally" \
  $([ "$night_rc" -eq 0 ] && [ "${NIGHT_EXIT:-1}" -eq 0 ]; echo $?)
wait_for_gone "$obs_pid" 5
check "pickup set: the observer is dead once baton's child is done" $?
# The reap must be SILENT. bash announces the death of a job it reaps
# ("<pid> Terminated: 15") on the shell's own stderr, and watch.sh's header
# rule is that this stream belongs to the claude child: a night lane shares
# one terminal with a full-screen TUI all night. The positive control is the
# second half -- a "no such text" assertion over an empty stream found
# nothing because it read nothing.
check "pickup set: stderr was actually inspected (positive control)" \
  $([ "$(grep -c . "$SCRATCH/night.err")" -gt 0 ]; echo $?)
check "pickup set: no job-control notice reaches the lane's stderr" \
  $(! grep -qiE "terminated|killed|signal 15" "$SCRATCH/night.err"; echo $?)
stop_night 2>/dev/null
cleanup_root

# --- (b) PATHWAY_PICKUP unset: nothing is started --------------------------
observer_setup
write_behavior a <<'EOF'
STEP_EXIT=(0)
EOF
start_night
wait_for_night_exit 20 >/dev/null
check "pickup unset: the observer target never ran" $([ ! -f "$OBSERVE_FAKE_OUT" ]; echo $?)
check "pickup unset: the handoff log says nothing about an observer" \
  $(! grep -q "OBSERVER:" "$HLOG" 2>/dev/null; echo $?)
cleanup_root

# --- (c) target absent: one witness, and the lane launches anyway ----------
observer_setup
export PATHWAY_PICKUP="$OBS_RUN_DIR/pickup.json"; : > "$PATHWAY_PICKUP"
export BATON_WAVE_WAKE_TARGET="$SCRATCH/nowhere/wave_wake.py"
write_behavior a <<'EOF'
STEP_EXIT=(0)
EOF
start_night
wait_for_night_exit 20 >/dev/null
check "target absent: the handoff log carries the OBSERVER witness line" \
  $(grep -qF "OBSERVER: target absent $BATON_WAVE_WAKE_TARGET" "$HLOG"; echo $?)
check "target absent: the claude child still launched" $([ "$(invocation_count a)" -ge 1 ]; echo $?)
check "target absent: the night exited with the child's code" $([ "${NIGHT_EXIT:-1}" -eq 0 ]; echo $?)
cleanup_root

# --- (f) the premise: survives a handoff, killed exactly once --------------
observer_setup
export PATHWAY_PICKUP="$OBS_RUN_DIR/pickup.json"; : > "$PATHWAY_PICKUP"
write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-observer")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_BLOCK=(1)
STEP_BLOCK_TICKS=(20)
STEP_EXIT=(9)
EOF
start_night
wait_for_file "$OBSERVE_FAKE_OUT" 8 || true
obs_pid=$(awk -F= '/^pid=/{print $2; exit}' "$OBSERVE_FAKE_OUT" 2>/dev/null)
f=$(wait_for_transcript a 8)
printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$f"
wait_for_grep "config=$(config_dir_of b) " "$(fake_log)" 10
check "handoff: the second account launched" $?
check "handoff: the observer is still alive across the handoff" \
  $([ -n "${obs_pid:-}" ] && kill -0 "$obs_pid" 2>/dev/null; echo $?)
wait_for_night_exit 25 >/dev/null
check "handoff: the observer was started exactly once" \
  $([ "$(grep -c '^pid=' "$OBSERVE_FAKE_OUT" 2>/dev/null)" -eq 1 ]; echo $?)
check "handoff: the handoff log holds exactly one OBSERVER start" \
  $([ "$(grep -c 'OBSERVER: started' "$HLOG")" -eq 1 ]; echo $?)
check "handoff: the handoff log holds exactly one OBSERVER stop" \
  $([ "$(grep -c 'OBSERVER: stopped' "$HLOG")" -eq 1 ]; echo $?)
wait_for_gone "${obs_pid:-1}" 5
check "handoff: the observer is dead once the night ends" $?
stop_night 2>/dev/null
cleanup_root

# --- (d) `baton --observe <id>` resolves the dir and execs the observer -----
observer_setup
mkdir -p "$HOME/.claude/state/wave-wake/run-77"
: > "$HOME/.claude/state/wave-wake/run-77/run.json"
"$BATON_BIN" --observe run-77 >"$SCRATCH/observe.out" 2>"$SCRATCH/observe.err" &
cli_pid=$!
wait_for_file "$OBSERVE_FAKE_OUT" 8; check "--observe <id>: the observer target ran" $?
check "--observe <id>: argv names the resolved run dir" \
  $([ "$(grep '^arg=' "$OBSERVE_FAKE_OUT")" = "$(expected_argv "$HOME/.claude/state/wave-wake/run-77" | grep '^arg=')" ]; echo $?)
check "--observe <id>: the observer REPLACED baton (exec, not a child)" \
  $([ "$(awk -F= '/^pid=/{print $2; exit}' "$OBSERVE_FAKE_OUT")" = "$cli_pid" ]; echo $?)
kill -KILL "$cli_pid" 2>/dev/null; wait "$cli_pid" 2>/dev/null
cleanup_root

# --- (e) a directory that is not a run directory is refused ----------------
observer_setup
mkdir -p "$SCRATCH/not-a-run"
"$BATON_BIN" --observe "$SCRATCH/not-a-run" >"$SCRATCH/observe.out" 2>"$SCRATCH/observe.err"
rc=$?
check "--observe <dir> without run.json: exits nonzero" $([ "$rc" -ne 0 ]; echo $?)
check "--observe <dir> without run.json: says why in one line" \
  $(grep -q "run.json" "$SCRATCH/observe.err" && [ "$(grep -c . "$SCRATCH/observe.err")" -eq 1 ]; echo $?)
check "--observe <dir> without run.json: started nothing" $([ ! -f "$OBSERVE_FAKE_OUT" ]; echo $?)
cleanup_root

echo "observe_test: $pass pass, $fail fail"
