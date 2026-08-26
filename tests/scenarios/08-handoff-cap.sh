#!/usr/bin/env bash
# Gherkin: "Handoff cap is reached before every account is exhausted".
# QA-DOC section 5 row 8.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "08-handoff-cap"
fresh_root
add_account c

export BATON_MAX_HANDOFFS=1

write_behavior a <<'EOF'
STEP_TRANSCRIPT=("sess-cap-a")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_TRANSCRIPT=("sess-cap-b")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF

start_night
a_transcript=$(wait_for_transcript a 5)
scenario_check "a transcript appeared" $([ -n "$a_transcript" ]; echo $?)
[ -n "$a_transcript" ] && printf '%s\n' "usage limit reached" >> "$a_transcript"

b_transcript=$(wait_for_transcript b 5)
scenario_check "b transcript appeared" $([ -n "$b_transcript" ]; echo $?)
[ -n "$b_transcript" ] && printf '%s\n' "usage limit reached" >> "$b_transcript"

wait_for_night_exit 10
scenario_check "night process exited" $?
scenario_check "exit nonzero" $([ "$NIGHT_EXIT" -ne 0 ]; echo $?)
scenario_check "cap stop uses baton's reserved exit 75" $([ "$NIGHT_EXIT" -eq 75 ]; echo $?)
scenario_check "stderr names the cap 1" $(grep -q "1" "$SCRATCH/night.err"; echo $?)
scenario_check "stderr names BATON_MAX_HANDOFFS" $(grep -q "BATON_MAX_HANDOFFS" "$SCRATCH/night.err"; echo $?)
handoff_log_path="$BATON_ACCOUNTS_ROOT/.handoff.log"
stderr_subjects=$(grep -c . "$SCRATCH/night.err" 2>/dev/null)
log_subjects=$(grep -c . "$handoff_log_path" 2>/dev/null)
scenario_check "resume check inspected stderr subjects (got $stderr_subjects)" \
  $([ "$stderr_subjects" -gt 0 ]; echo $?)
scenario_check "resume check inspected handoff-log subjects (got $log_subjects)" \
  $([ "$log_subjects" -gt 0 ]; echo $?)
stderr_resume=$(grep -cF "baton b --resume sess-cap-b" "$SCRATCH/night.err" 2>/dev/null)
log_resume=$(grep -cF "baton b --resume sess-cap-b" "$handoff_log_path" 2>/dev/null)
scenario_check "stderr carries NO runnable resume line (got $stderr_resume)" \
  $([ "$stderr_resume" -eq 0 ]; echo $?)
scenario_check "stderr says the resume line is in the handoff log" \
  $(grep -qF "the resume line is in the handoff log: $handoff_log_path" "$SCRATCH/night.err"; echo $?)
scenario_check "handoff log carries the exact resume line (got $log_resume)" \
  $([ "$log_resume" -gt 0 ]; echo $?)
scenario_check "stderr names the last account, session id, and handoff log path" \
  $(grep -q "last account 'b'.*session id 'sess-cap-b'.*$handoff_log_path" "$SCRATCH/night.err"; echo $?)
scenario_check "handoff log names the last account, session id, and its own path" \
  $(grep -q "last account 'b'.*session id 'sess-cap-b'.*$handoff_log_path" "$handoff_log_path"; echo $?)
scenario_check "c never probed or launched" $([ "$(invocation_count c)" -eq 0 ]; echo $?)
# The cap is a cap ON handoffs, not on launches: BATON_MAX_HANDOFFS=1 must
# ALLOW the first handoff (a -> b) and refuse only the second. An off-by-one
# in the comparison turns "1" into "none", which is a different feature and
# every assertion above still passes.
scenario_check "the one permitted handoff did happen (b ran)" $([ "$(invocation_count b)" -ge 1 ]; echo $?)
scenario_check "b was launched, not merely probed" $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)
# The other half of the pair with scenario 26: here an account is still
# alive, so the cap really is the reason the run stopped and the
# no-live-account message would be a lie. A build that answers with one
# fixed message fails one of the two scenarios.
scenario_check "stderr does NOT claim accounts are exhausted" \
  $(! grep -q "no live account" "$SCRATCH/night.err"; echo $?)

unset BATON_MAX_HANDOFFS
cleanup_root
scenario_end
