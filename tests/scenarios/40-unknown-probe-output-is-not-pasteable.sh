#!/usr/bin/env bash
# Issue #2 root cause 2, on the ONE path that still relayed foreign text
# verbatim to a shared stream (review finding: lib/accounts.sh pick_live,
# UNKNOWN branch).
#
# The AUTH branch was fixed by moving baton's OWN sentence to the handoff
# log. The UNKNOWN branch was not, because the text it printed was not
# baton's sentence at all -- it was the first 120 characters of whatever the
# `claude` CLI said, echoed straight into `warn`. That is worse than the
# original bug, not better: baton's own strings are a closed set a reviewer
# can read, and probe output is an OPEN set that includes proxy error pages,
# shell fragments, and -- the shape this scenario plants -- a complete
# `baton <account> --resume <id>` line. Fetched text is data; a program that
# relays it to a human's terminal has turned data into an instruction.
#
# So the contract is: the shared stream says WHAT HAPPENED and where to read
# the details; the handoff log carries the probe's own words, quoted as data.
# Nothing baton prints may be pasteable.
#
# Absence-is-not-evidence discipline: "stderr carries no command" is asserted
# only after (1) the predicate is proven to match the three leak shapes that
# have actually mattered, and (2) the stream is proven to hold more than zero
# lines. A predicate that matches nothing and a stream that holds nothing
# both "pass" a negative assertion for the wrong reason.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "40-unknown-probe-output-is-not-pasteable"
fresh_root

HANDOFF_LOG_PATH="$BATON_ACCOUNTS_ROOT/.handoff.log"

# The poison. It must classify UNKNOWN, so it carries none of detect.sh's
# LIMIT or AUTH markers, and it must not contain the substring "ok" or
# probe() would upgrade it to ALIVE on the canary check.
POISON='proxy error 502 from upstream -- retry with: baton a --resume abc123'

# Only the FIRST invocation (the probe) says it. The second invocation is
# the real launch, and its stdout is the child's, not baton's -- letting the
# poison through DEFAULT_STDOUT would make this scenario assert something
# about the fake claude instead of about baton.
write_behavior a <<EOF
STEP_STDOUT=("$POISON")
EOF
# Clear the alive cache or pick_live short-circuits and never probes at all.
rm -f "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b"

"$BATON_BIN" some-arg >"$SCRATCH/plain.out" 2>"$SCRATCH/plain.err"
rc=$?

# --- positive control 1: the predicate can see a leak ----------------------
# If this fails, every "no runnable command" assertion below is vacuous.
control_hits=$(predicate_positive_control "$SCRATCH/predicate-control.txt")
scenario_check "positive control: the predicate matches all 3 known leak shapes (got $control_hits)" \
  $([ "$control_hits" -eq 3 ]; echo $?)

# --- positive control 2: the UNKNOWN branch actually ran -------------------
# Without this, a baton that died before probing would pass everything below.
scenario_check "baton did not die on an unrecognized probe result" $([ "$rc" -eq 0 ]; echo $?)
scenario_check "positive control: the UNKNOWN branch fired (stderr says it launched anyway)" \
  $(grep -qi "launching anyway" "$SCRATCH/plain.err"; echo $?)
scenario_check "positive control: an unrecognized result left no dead mark" \
  $(! is_dead_marked a; echo $?)

# --- positive control 3: more than zero lines were inspected ---------------
scanned=0
for stream in out err; do
  scanned=$((scanned + $(stream_lines "$SCRATCH/plain.$stream")))
done
if [ "$scanned" -eq 0 ]; then
  echo "40-unknown-probe-output-is-not-pasteable: COULD NOT INSPECT -- baton produced 0 output lines" >&2
  cleanup_root
  exit 2
fi
scenario_check "inspected more than zero baton output lines (got $scanned)" \
  $([ "$scanned" -gt 0 ]; echo $?)

# --- the claim: no pasteable command on either shared stream ---------------
for stream in out err; do
  hits=$(runnable_command_lines "$SCRATCH/plain.$stream")
  scenario_check "plain.$stream: no runnable baton command line (got $hits)" \
    $([ "$hits" -eq 0 ]; echo $?)
done
# The specific shape the incident produced, checked literally as well as by
# predicate, so a future predicate regression cannot quietly retire it.
for stream in out err; do
  scenario_check "plain.$stream: does not carry the planted resume command" \
    $(! grep -q -- "--resume abc123" "$SCRATCH/plain.$stream"; echo $?)
done

# --- the words are not lost, they are durable ------------------------------
# Suppressing the probe's own text without recording it anywhere would trade
# one failure (an instruction in the terminal) for another (a network
# diagnosis nobody can make). The log is the channel that may hold it.
scenario_check "the handoff log exists" $([ -f "$HANDOFF_LOG_PATH" ]; echo $?)
scenario_check "the handoff log carries the raw probe output verbatim" \
  $(grep -q -- "--resume abc123" "$HANDOFF_LOG_PATH" 2>/dev/null; echo $?)
scenario_check "the handoff log names the account the probe was about" \
  $(grep -q "'a'" "$HANDOFF_LOG_PATH" 2>/dev/null; echo $?)
scenario_check "the handoff log frames it as data, not as an instruction" \
  $(grep -qi "do not run" "$HANDOFF_LOG_PATH" 2>/dev/null; echo $?)

# --- the stream still points at the log ------------------------------------
# Moving text off a stream must not make it invisible.
scenario_check "stderr points at the handoff log instead of quoting the probe" \
  $(grep -q "handoff\.log" "$SCRATCH/plain.err"; echo $?)

cleanup_root
scenario_end
