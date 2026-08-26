#!/usr/bin/env bash
# baton#12 gap 1: `-c` on the auto-pick paths (`--fast`, `--next`, plain auto-
# pick) is deliberately UNGUARDED. A cold start has no session id at launch
# time; giving it a guessed key would serialize every unrelated cold start onto
# one subject, which is a worse bug than the unguarded exposure. lib/lock.sh
# documents this decision at lock_subject_for_argv. This scenario records the
# DOCUMENTED count so the exposure is measured, not silent.
#
# Recorded decision for Drake: two concurrent `--fast -c` both launch. If the
# project later decides `-c` needs a subject, that is a new design decision and
# a new entry point, not a silent behavioral change.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "49-fast-c-is-unguarded-documented"
fresh_root
export BATON_LOCK_PROV=test

write_behavior a <<'EOF'
STEP_EXIT=(0 0)
STEP_STDOUT=("first" "second")
EOF

before=$(grep -c '^inv=' "$(fake_log)" 2>/dev/null || echo 0)

# Two `--fast -c` launches. Neither has a keyable session subject, so the
# single-writer guard is a no-op for both.
"$BATON_BIN" --fast -c >"$SCRATCH/one.out" 2>"$SCRATCH/one.err"
rc1=$?
"$BATON_BIN" --fast -c >"$SCRATCH/two.out" 2>"$SCRATCH/two.err"
rc2=$?

after=$(grep -c '^inv=' "$(fake_log)" 2>/dev/null || echo 0)

scenario_check "both --fast -c launches exited 0" \
  $([ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; echo $?)
scenario_check "the documented count is two launches" \
  $([ "$((after - before))" -eq 2 ]; echo $?)
scenario_check "no session lock was minted for a guessed -c subject" \
  $([ "$(find "$(baton_lock_dir)" -maxdepth 1 -name 'session_*.lock' 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; echo $?)

cleanup_root
scenario_end
