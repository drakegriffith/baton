#!/usr/bin/env bash
# Round-4 finding. The round-3 fix asked `ps` about pid 1 before forking and
# treated success as proof the process table was readable. It is not: a `ps`
# can answer for pid 1 and fail for everything else -- a sandbox that permits
# the init process, a container with a restricted /proc view, a policy that
# scopes process visibility. The positive control passed, the child-specific
# call then returned empty, and empty was read as "the child is gone", which
# fell through to a blocking `wait` with no transcript watching for the rest
# of the night.
#
# That is the same defect as the round-3 finding, one pid along: a control
# that proves the prober works IN GENERAL does not prove it answered THIS
# question. The control has to be about the subject, and the subject here is
# the child that was just forked -- a pid this process knows is alive,
# because it created it.
#
# So: if the child-specific `ps` fails or comes back empty while `kill -0`
# still says the pid is there, the two disagree, and disagreement is
# could-not-inspect. Never "dead".
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "45-a-ps-that-answers-for-pid-1-only"
fresh_root

# A `ps` that answers for pid 1 and refuses everything else. This is the
# shape the round-3 control cannot see.
mkdir -p "$SCRATCH/shim"
cat > "$SCRATCH/shim/ps" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "1" ] && exec /bin/ps "$@"
done
exit 1
EOF
chmod +x "$SCRATCH/shim/ps"
export PATH="$SCRATCH/shim:$PATH"

# Positive controls for the shim: it must pass for pid 1 and fail for a pid
# that certainly exists. Without both, this scenario is asserting things
# about a condition it never created.
scenario_check "positive control: the shim still answers for pid 1" \
  $(ps -p 1 -o args= >/dev/null 2>&1; echo $?)
scenario_check "positive control: the shim refuses this shell's own pid" \
  $(! ps -p $$ -o state= >/dev/null 2>&1; echo $?)

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF

start_night
wait_for_night_exit 25
waited_rc=$?
scenario_check "the run ended rather than blocking on an unwatchable child" $waited_rc

scenario_check "an unreadable child liveness exits 2 (got ${NIGHT_EXIT:-none})" \
  $([ "${NIGHT_EXIT:-0}" -eq 2 ]; echo $?)
scenario_check "stderr carries the could-not-inspect marker" \
  $(grep -q 'watch-result=could-not-inspect' "$SCRATCH/night.err"; echo $?)
scenario_check "the marker says why" \
  $(grep -q 'reason=' "$SCRATCH/night.err"; echo $?)

# At most one launch: it must refuse on the first child, not rotate through
# every account launching unwatchable children.
inv_a=$(invocation_count a); inv_b=$(invocation_count b)
scenario_check "at most one account was launched (a=$inv_a b=$inv_b)" \
  $([ $((inv_a + inv_b)) -le 1 ]; echo $?)

scenario_check "stderr hands over no runnable baton command line" \
  $([ "$(runnable_command_lines "$SCRATCH/night.err")" -eq 0 ]; echo $?)
scenario_check "positive control: the predicate can see a leak" \
  $([ "$(predicate_positive_control "$SCRATCH/predicate-control.txt")" -eq 3 ]; echo $?)

kill_fake_claude a
kill_fake_claude b
cleanup_root
scenario_end
