#!/usr/bin/env bash
# qa/qa_failover.sh -- QA (seat 5) executable walkthrough of the --night
# failover feature, driven entirely through the real `baton` CLI subprocess
# against the fake `claude` fixture, per .ab/QA-DOC.md.
#
# This is a WORKFLOW, not a re-run of tests/run.sh: it is one script, told as
# one continuous operator's night, that sets up accounts, launches
# `baton --night`, injects a limit, watches the handoff happen, and then
# walks every remaining acceptance outcome the same way -- headless limit,
# auth, clean exit, nonzero exit, exhaustion, the handoff cap, UNKNOWN safety,
# the classification contract, plain-exec regression, existing flags,
# credential isolation, and real-root isolation. It never sources `baton`,
# `lib/detect.sh`, `lib/accounts.sh` or `lib/watch.sh`, and it never calls
# `bash tests/run.sh` or a `tests/scenarios/*.sh` file -- every assertion
# below is this script's own, checked against argv/exit-code/stdout/stderr of
# a real `baton` subprocess and the filesystem state it leaves behind (QA-DOC
# section 1: "the system surface under test").
#
# It DOES reuse tests/fixtures/bin/claude and the setup/observation helpers in
# tests/fixtures/lib.sh (fresh_root, write_behavior, start_night, ...) by
# sourcing them -- QA-DOC section 2 calls that file "fixture, not suite", and
# the assignment explicitly allows it. Nothing in lib.sh asserts anything;
# every `check` call below is written for this script.
#
# There are exactly 14 assertion blocks, one per Gherkin scenario in
# features/failover.feature (Background excluded, and per the QA assignment,
# the post-review hardening scenarios 15-26 excluded). Two post-review
# amendments are respected explicitly, not silently:
#   - D6 (amended): --night watches transcripts for GROWTH, not for a new
#     file appearing, so BATON_SESSION_WAIT_SECS no longer gates anything.
#     Block 1 sets it to 0 and still gets a --resume handoff, which is a real
#     behavioral proof of the amendment (the pre-amendment reading of D6 would
#     have fallen back to `-c` immediately with a wait of 0).
#   - QA-DOC section 6 note: tests/unit/detect_test.sh sourcing lib/detect.sh
#     is an ADDITIVE test, not a replacement for the black-box contract test.
#     Block 10 below is the black-box contract test -- it never sources
#     lib/detect.sh, only `baton --probe` and a live transcript, exactly as
#     section 6 prescribes.
#
# Hermetic: every block except 14 runs under a fresh temp HOME +
# BATON_ACCOUNTS_ROOT (tests/fixtures/lib.sh's fresh_root). Block 14
# deliberately does NOT override HOME (that is the scenario), so this script
# captures the real HOME once, up front, before anything can shadow it, and
# restores it explicitly for that one block. No block ever writes into the
# real ~/.claude-accounts, and block 14 itself proves that.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
export BATON_BIN="$REPO_ROOT/baton"
export FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
REAL_HOME="$HOME"

chmod +x "$FIXTURES_DIR/bin/claude" 2>/dev/null || true
chmod +x "$BATON_BIN" 2>/dev/null || true

. "$FIXTURES_DIR/lib.sh"

QA_RESULTS="$(mktemp)"
trap 'rm -f "$QA_RESULTS"' EXIT

BLOCK_NUM=0
CURRENT_BLOCK=""
CURRENT_FAILS=""

block_begin() { # $1 = Gherkin scenario label, $2 = QA-DOC anchor
  BLOCK_NUM=$((BLOCK_NUM + 1))
  CURRENT_BLOCK="$1"
  CURRENT_FAILS=""
  echo ""
  echo "== block $BLOCK_NUM: $1 -- $2 =="
}

check() { # $1 description, $2 = 0/nonzero (0 == pass)
  if [ "$2" -eq 0 ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    CURRENT_FAILS="${CURRENT_FAILS}[$1] "
  fi
}

block_end() {
  if [ -z "$CURRENT_FAILS" ]; then
    echo "PASS block $BLOCK_NUM ($CURRENT_BLOCK)" >>"$QA_RESULTS"
  else
    echo "FAIL block $BLOCK_NUM ($CURRENT_BLOCK) -- $CURRENT_FAILS" >>"$QA_RESULTS"
  fi
}

# safe_wait_night TIMEOUT -- wraps wait_for_night_exit so a timeout never
# leaves NIGHT_EXIT unset under `set -u`; records the timeout itself as a
# failed wait rather than crashing the whole script.
safe_wait_night() {
  if wait_for_night_exit "$1"; then
    return 0
  fi
  NIGHT_EXIT=-1
  stop_night
  return 1
}

# ============================================================================
# Block 1 -- Scenario: "Unattended interactive session hits its limit and the
# run continues on the next account" (headline). QA-DOC section 5 row 1.
# ============================================================================
block_begin "01 interactive limit -> handoff (headline)" "QA-DOC S5 row 1"
fresh_root
# D6 amendment: an absurdly small wait knob must not matter any more.
export BATON_SESSION_WAIT_SECS=0

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-headline")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(42)
STEP_STDOUT=("night continues under b")
EOF

start_night -- some-project-args
f=$(wait_for_transcript a 5)
check "account a's transcript file appeared" $([ -n "$f" ]; echo $?)

printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >>"$f"

safe_wait_night 10
check "the --night run terminated" $?

log="$(fake_log)"
check "account a was launched exactly once (killed while blocked, never re-launched)" \
  $([ "$(grep -c "config=$(config_dir_of a) " "$log")" -eq 1 ]; echo $?)
check "account a's child actually received SIGTERM" $([ -s "$(signals_log_of a)" ]; echo $?)
check "account a is marked dead with a future epoch" \
  $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
check "baton announced the handoff on stderr naming both accounts" \
  $(printf '%s' "$(night_stderr)" | grep -q "'a'" && printf '%s' "$(night_stderr)" | grep -q "'b'"; echo $?)
check "b was relaunched with --resume and a's captured session id" \
  $(grep -q -- "--resume sess-headline" "$log"; echo $?)
check "the pass-through project args reached the relaunch" \
  $(grep -q "some-project-args" "$log"; echo $?)
check "resume id present despite BATON_SESSION_WAIT_SECS=0 (D6: growth-watch makes the wait knob inert)" \
  $(grep -q -- "--resume sess-headline" "$log"; echo $?)
check "the run's final exit code is the second account's, not a crash" $([ "$NIGHT_EXIT" -eq 42 ]; echo $?)

unset BATON_SESSION_WAIT_SECS
cleanup_root
block_end

# ============================================================================
# Block 2 -- Scenario: "Reset time missing from the transcript line falls
# back to the default dead duration". QA-DOC section 5 row 2.
# ============================================================================
block_begin "02 reset-time-missing -> 5h fallback" "QA-DOC S5 row 2"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-fallback")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("b took over")
EOF

start_epoch=$(date +%s)
start_night
f=$(wait_for_transcript a 5)
check "account a's transcript file appeared" $([ -n "$f" ]; echo $?)

# Matches the shared LIMIT pattern but has no parseable "resets <time>" clause.
printf '%s\n' 'You have hit your usage limit today, sorry about that.' >>"$f"

safe_wait_night 10
check "the --night run terminated" $?

check "account a is marked dead" $(is_dead_marked a; echo $?)
epoch=$(dead_epoch_of a)
expected=$((start_epoch + 5 * 3600))
diff=$((epoch - expected)); [ "$diff" -lt 0 ] && diff=$((-diff))
check "dead-until epoch is (run start + 5h) within 60s tolerance" $([ "$diff" -le 60 ]; echo $?)
check "dead reason recorded as 'limit'" $([ "$(dead_reason_of a)" = "limit" ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 3 -- Scenario: "Headless child exits after hitting its limit and the
# run rotates to the next account". QA-DOC section 5 row 3.
# ============================================================================
block_begin "03 headless limit -> rotate" "QA-DOC S5 row 3"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("hello from b")
EOF

start_night
safe_wait_night 10
check "the --night run terminated" $?

log="$(fake_log)"
a_lines=$(grep -n "config=$(config_dir_of a) " "$log" | cut -d: -f1)
a_count=$(printf '%s\n' "$a_lines" | grep -c .)
a_last=$(printf '%s\n' "$a_lines" | tail -1)
b_first=$(grep -n "config=$(config_dir_of b) " "$log" | head -1 | cut -d: -f1)
check "account a was invoked exactly twice (launch + post-exit probe)" $([ "$a_count" -eq 2 ]; echo $?)
check "both of a's invocations happened before b was ever launched" \
  $([ -n "${b_first:-}" ] && [ "${a_last:-0}" -lt "$b_first" ]; echo $?)
check "account a is marked dead with a future epoch" \
  $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
check "baton announced the handoff naming a and b" \
  $(grep -q "'a'" "$SCRATCH/night.err" && grep -q "'b'" "$SCRATCH/night.err"; echo $?)
check "the run kept going and exited with b's code, not a's" $([ "$NIGHT_EXIT" -eq 0 ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 4 -- Scenario: "Headless child exits after an auth failure and the
# run rotates to the next account". QA-DOC section 5 row 4.
# ============================================================================
block_begin "04 headless auth -> rotate" "QA-DOC S5 row 4"
fresh_root

start_epoch=$(date +%s)
write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("Not logged in. Please run /login" "Not logged in. Please run /login")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("hi from b")
EOF

start_night
safe_wait_night 10
check "the --night run terminated" $?

check "account a is marked dead" $(is_dead_marked a; echo $?)
check "dead reason recorded as 'auth'" $([ "$(dead_reason_of a)" = "auth" ]; echo $?)
epoch=$(dead_epoch_of a)
expected=$((start_epoch + 3600))
diff=$((epoch - expected)); [ "$diff" -lt 0 ] && diff=$((-diff))
check "dead-until epoch is (run start + 1h) within 60s tolerance" $([ "$diff" -le 60 ]; echo $?)
check "account b was launched" $([ "$(invocation_count b)" -ge 1 ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 5 -- Scenario: "Child exits cleanly and baton exits with the same
# code, no rotation". QA-DOC section 5 row 5.
# ============================================================================
block_begin "05 clean exit -> no rotation" "QA-DOC S5 row 5"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0 0)
STEP_STDOUT=("all done" "ok")
EOF

start_night
safe_wait_night 10
check "the --night run terminated" $?

check "baton exits with the child's own code (0)" $([ "$NIGHT_EXIT" -eq 0 ]; echo $?)
check "account a is NOT marked dead" $(! is_dead_marked a; echo $?)
check "account a was invoked exactly twice (real run + post-exit probe), never a third time" \
  $([ "$(invocation_count a)" -eq 2 ]; echo $?)
check "account b was never launched" $([ "$(invocation_count b)" -eq 0 ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 6 -- Scenario: "Child exits with a nonzero non-limit code and baton
# propagates it, no rotation". QA-DOC section 5 row 6.
# ============================================================================
block_begin "06 nonzero non-limit exit -> propagate, no rotation" "QA-DOC S5 row 6"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(7 0)
STEP_STDOUT=("boom" "ok")
EOF

start_night
safe_wait_night 10
check "the --night run terminated" $?

check "baton propagates the child's nonzero exit code (7)" $([ "$NIGHT_EXIT" -eq 7 ]; echo $?)
check "account a is NOT marked dead" $(! is_dead_marked a; echo $?)
check "account b was never launched" $([ "$(invocation_count b)" -eq 0 ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 7 -- Scenario: "All accounts are limited and baton dies with the
# no-live-account message". QA-DOC section 5 row 7.
# ============================================================================
block_begin "07 exhaustion -> no-live-account message names the root" "QA-DOC S5 row 7"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF

start_night
safe_wait_night 10
check "the --night run terminated" $?

check "baton exits nonzero" $([ "$NIGHT_EXIT" -ne 0 ]; echo $?)
check "stderr carries the no-live-account guidance (--status / --revive)" \
  $(grep -q "no live account under .*baton --status to see dead marks; baton --revive <name> to override" "$SCRATCH/night.err"; echo $?)
check "the message names the ACTUAL resolved accounts root (not just the string)" \
  $(grep -qF "$BATON_ACCOUNTS_ROOT" "$SCRATCH/night.err"; echo $?)
check "the message names the BATON_ACCOUNTS_ROOT knob" $(grep -q "BATON_ACCOUNTS_ROOT" "$SCRATCH/night.err"; echo $?)
check "account a is marked dead with a future epoch" \
  $(is_dead_marked a && [ "$(dead_epoch_of a)" -gt "$(date +%s)" ]; echo $?)
check "account b is marked dead with a future epoch" \
  $(is_dead_marked b && [ "$(dead_epoch_of b)" -gt "$(date +%s)" ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 8 -- Scenario: "Handoff cap is reached before every account is
# exhausted". QA-DOC section 5 row 8. Two sub-runs: the cap-is-the-real-cause
# case (from the Gherkin, one account still alive) and, because the
# assignment asks this block to also walk the exhaustion-beats-cap ordering,
# a second sub-run where the cap and exhaustion land on the very same
# handoff -- proving night_mode checks exhaustion BEFORE the cap so the
# operator-facing message never blames a cap that raising would not fix.
# ============================================================================
block_begin "08 handoff cap (incl. exhaustion-beats-cap ordering)" "QA-DOC S5 row 8"

echo "  -- sub-run A: cap is the real cause (account c still alive, untouched)"
fresh_root
add_account c
export BATON_MAX_HANDOFFS=1
write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF

start_night
safe_wait_night 10
check "sub-run A: the --night run terminated" $?
check "sub-run A: baton exits nonzero" $([ "$NIGHT_EXIT" -ne 0 ]; echo $?)
check "sub-run A: stderr names the cap value 1" $(grep -q "1" "$SCRATCH/night.err"; echo $?)
check "sub-run A: stderr names the BATON_MAX_HANDOFFS knob" $(grep -q "BATON_MAX_HANDOFFS" "$SCRATCH/night.err"; echo $?)
check "sub-run A: account c was never probed or launched" $([ "$(invocation_count c)" -eq 0 ]; echo $?)
check "sub-run A: the one permitted handoff to b did happen" $([ "$(invocation_count b)" -ge 1 ]; echo $?)
check "sub-run A: stderr does NOT falsely claim exhaustion" \
  $(! grep -q "no live account" "$SCRATCH/night.err"; echo $?)
unset BATON_MAX_HANDOFFS
cleanup_root

echo "  -- sub-run B: cap and exhaustion coincide; exhaustion must win the message"
fresh_root
export BATON_MAX_HANDOFFS=1
write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
write_behavior b <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF

start_night
safe_wait_night 10
check "sub-run B: the --night run terminated" $?
check "sub-run B: baton exits nonzero" $([ "$NIGHT_EXIT" -ne 0 ]; echo $?)
check "sub-run B: stderr reports no-live-account (the true cause)" \
  $(grep -q "no live account" "$SCRATCH/night.err"; echo $?)
check "sub-run B: stderr does NOT blame the handoff cap instead" \
  $(! grep -q "handoff cap" "$SCRATCH/night.err"; echo $?)
check "sub-run B: the one permitted handoff to b still happened first" \
  $([ "$(invocation_count b)" -ge 1 ]; echo $?)
unset BATON_MAX_HANDOFFS
cleanup_root

block_end

# ============================================================================
# Block 9 -- Scenario: "Unrecognized transcript content is classified UNKNOWN
# and never treated as a limit". QA-DOC section 5 row 9.
# ============================================================================
block_begin "09 UNKNOWN content is never actionable" "QA-DOC S5 row 9"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-unknown")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
STEP_BLOCK_TICKS=(40)
EOF

start_night
f=$(wait_for_transcript a 5)
check "account a's transcript file appeared" $([ -n "$f" ]; echo $?)

printf '%s\n' 'Here is the code you asked for, hope it helps!' >>"$f"
printf '%s\n' 'Sure, I can add a test for that function too.' >>"$f"

# BATON_WATCH_INTERVAL is 0.2 (fresh_root default); wait several poll cycles
# and confirm nothing happened yet, well before the fixture's own natural
# exit (4s away, STEP_BLOCK_TICKS=40 * 0.1s).
sleep 1.5
check "night process is still running (no crash, no exit)" $(kill -0 "$NIGHT_PID" 2>/dev/null; echo $?)
check "account a was NOT killed (no SIGTERM sent)" $(! [ -s "$(signals_log_of a)" ]; echo $?)
check "account a is NOT marked dead" $(! is_dead_marked a; echo $?)
check "no handoff/crash text on stderr yet" $(! grep -qi "handoff\|no live account" "$SCRATCH/night.err"; echo $?)

safe_wait_night 10
check "when the child later exits on its own, baton exits with its code" $([ "$NIGHT_EXIT" -eq 0 ]; echo $?)
check "still never received a SIGTERM across the whole run" $(! [ -s "$(signals_log_of a)" ]; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 10 -- Scenario Outline: "The same shared classification function
# backs both detection paths". QA-DOC section 5 row 10 + section 6.
#
# Per QA-DOC section 6's amended disposition, this is the black-box
# cross-site guard: it drives classification ONLY through `baton --probe`
# and a live transcript, and never sources lib/detect.sh (that is
# tests/unit/detect_test.sh's job, an additive test this block does not
# duplicate or replace).
# ============================================================================
block_begin "10 classification contract (probe vs. transcript)" "QA-DOC S5 row 10 + S6"

qa_check_row() { # $1 = text, $2 = expected class (LIMIT|AUTH|UNKNOWN)
  local text="$1" expected="$2" probe_out probe_class f observed

  # call site 1: probe() via `baton --probe a`
  fresh_root
  write_behavior a <<EOF
STEP_STDOUT=("$text")
EOF
  probe_out="$("$BATON_BIN" --probe a 2>/dev/null)"
  probe_class=$(printf '%s' "$probe_out" | head -1 | awk '{print $2}')
  check "probe(--probe a) classifies [$text] as $expected" $([ "$probe_class" = "$expected" ]; echo $?)
  cleanup_root

  # call site 2: the --night live-transcript watcher
  fresh_root
  write_behavior a <<'INNEREOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-contract")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
INNEREOF
  start_night
  f=$(wait_for_transcript a 5)
  printf '%s\n' "$text" >>"$f"
  sleep 1

  observed=UNKNOWN
  [ -s "$(signals_log_of a)" ] && observed=ACTIONABLE
  case "$expected" in
    UNKNOWN) check "watcher took no action on [$text] (agrees: UNKNOWN)" $([ "$observed" = UNKNOWN ]; echo $?) ;;
    *)       check "watcher killed the child on [$text] (agrees: $expected is actionable)" $([ "$observed" = ACTIONABLE ]; echo $?) ;;
  esac

  kill_fake_claude a
  stop_night
  cleanup_root
}

qa_check_row "You've hit your usage limit. resets 2:30pm (America/New_York)" LIMIT
qa_check_row "usage limit reached for this account" LIMIT
qa_check_row "Not logged in. Please run /login" AUTH
qa_check_row "Invalid API key" AUTH
qa_check_row "Here is the code you asked for..." UNKNOWN
qa_check_row "" UNKNOWN

block_end

# ============================================================================
# Block 11 -- Scenario: "Plain baton still execs and never watches". QA-DOC
# section 5 row 11.
# ============================================================================
block_begin "11 plain baton execs (no fork, no watch)" "QA-DOC S5 row 11"
fresh_root

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("plain run")
EOF

this_pid=$$
"$BATON_BIN" some-arg >"$SCRATCH/plain.out" 2>"$SCRATCH/plain.err" &
plain_pid=$!
wait "$plain_pid"
plain_exit=$?

pidfile="$(config_dir_of a)/.fake-pid-ppid"
check "the fake claude process recorded its pid/ppid" $([ -s "$pidfile" ]; echo $?)
child_pid=$(awk '{print $1}' "$pidfile")
child_ppid=$(awk '{print $2}' "$pidfile")
check "the running process kept baton's own PID (exec, not a fork)" $([ "$child_pid" = "$plain_pid" ]; echo $?)
check "its PPID is this script's own PID (no extra process generation)" $([ "$child_ppid" = "$this_pid" ]; echo $?)
check "baton's exit code is the child's own (0)" $([ "$plain_exit" -eq 0 ]; echo $?)
check "no SIGTERM/kill marker exists (no watching happened)" $(! [ -s "$(signals_log_of a)" ]; echo $?)
check "no handoff/night-mode text appears on stderr" \
  $(! grep -qi "handoff\|night mode\|no live account" "$SCRATCH/plain.err"; echo $?)

cleanup_root
block_end

# ============================================================================
# Block 12 -- Scenario Outline: "Existing flags are unaffected by the --night
# addition". QA-DOC section 5 row 12: byte-diff (minus wall-clock text)
# against the pre-failover baton at commit 173fd9e.
# ============================================================================
block_begin "12 existing flags byte-identical to pre-failover baton" "QA-DOC S5 row 12"

OLD_BATON="$(mktemp)"
if git -C "$REPO_ROOT" show 173fd9e:baton >"$OLD_BATON" 2>/dev/null; then
  chmod +x "$OLD_BATON"

  qa_normalize() {
    sed -E \
      -e 's/[A-Za-z]{3} [A-Za-z]{3} +[0-9]{1,2} [0-9:]{8} [A-Za-z]{2,5} [0-9]{4}/<DATE>/g' \
      -e 's/[A-Za-z]{3} +[0-9]{1,2}:[0-9]{2}(AM|PM)/<DATE>/g'
  }

  qa_run_flag_case() { # $1 = human label, remaining = flags
    local label="$1"; shift
    local old_out old_err old_code new_out new_err new_code n_old_out n_new_out n_old_err n_new_err

    fresh_root_hardcoded_default
    old_out=$("$OLD_BATON" "$@" 2>"$SCRATCH/old.err"); old_code=$?
    old_err=$(cat "$SCRATCH/old.err")
    cleanup_root

    fresh_root_hardcoded_default
    new_out=$("$BATON_BIN" "$@" 2>"$SCRATCH/new.err"); new_code=$?
    new_err=$(cat "$SCRATCH/new.err")
    cleanup_root

    n_old_out=$(printf '%s' "$old_out" | qa_normalize)
    n_new_out=$(printf '%s' "$new_out" | qa_normalize)
    n_old_err=$(printf '%s' "$old_err" | qa_normalize)
    n_new_err=$(printf '%s' "$new_err" | qa_normalize)

    check "$label: stdout unchanged from pre-failover baton" $([ "$n_old_out" = "$n_new_out" ]; echo $?)
    check "$label: stderr unchanged from pre-failover baton" $([ "$n_old_err" = "$n_new_err" ]; echo $?)
    check "$label: exit code unchanged from pre-failover baton" $([ "$old_code" = "$new_code" ]; echo $?)
  }

  qa_run_flag_case "--status" --status
  qa_run_flag_case "--pick" --pick
  qa_run_flag_case "--dead a 90m" --dead a 90m
  qa_run_flag_case "--revive a" --revive a
  qa_run_flag_case "--next" --next
  qa_run_flag_case "--fast" --fast
  qa_run_flag_case "forced account a" a
else
  check "pre-failover baton (173fd9e) available for byte-diff" 1
fi
rm -f "$OLD_BATON"

block_end

# ============================================================================
# Block 13 -- Scenario: "The watcher never reads account credentials".
# QA-DOC section 5 row 13.
# ============================================================================
block_begin "13 watcher never reads credentials" "QA-DOC S5 row 13"
fresh_root

sentinel="$(config_dir_of a)/credentials.json"
echo '{"secret":"not-a-real-key"}' >"$sentinel"
chmod 000 "$sentinel"
before_mtime=$(stat -f %m "$sentinel")
before_atime=$(stat -f %a "$sentinel")

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-creds")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

start_night
f=$(wait_for_transcript a 5)
check "account a's transcript file appeared" $([ -n "$f" ]; echo $?)
printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >>"$f"

safe_wait_night 10
check "the --night run terminated" $?
check "the handoff to b completed exactly as in block 1" \
  $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)
check "account a is marked dead" $(is_dead_marked a; echo $?)

after_mtime=$(stat -f %m "$sentinel")
after_atime=$(stat -f %a "$sentinel")
check "credentials sentinel mtime unchanged by the run" $([ "$before_mtime" = "$after_mtime" ]; echo $?)
check "credentials sentinel atime unchanged by the run" $([ "$before_atime" = "$after_atime" ]; echo $?)
check "no 'Permission denied' message anywhere in stderr" $(! grep -qi "permission denied" "$SCRATCH/night.err"; echo $?)

chmod 600 "$sentinel"
cleanup_root
block_end

# ============================================================================
# Block 14 -- Scenario: "Tests never touch the real accounts root". QA-DOC
# section 5 row 14. Deliberately does NOT override HOME.
# ============================================================================
block_begin "14 real accounts root left untouched" "QA-DOC S5 row 14"

REAL_ROOT="$REAL_HOME/.claude-accounts"
real_root_existed=0
[ -d "$REAL_ROOT" ] && real_root_existed=1

marker="$(mktemp)"
sleep 1.1

unset CLAUDE_CONFIG_DIR
export HOME="$REAL_HOME"
Q14_SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
export BATON_ACCOUNTS_ROOT="$Q14_SCRATCH/accounts"
mkdir -p "$BATON_ACCOUNTS_ROOT"
export PATH="$FIXTURES_DIR/bin:$PATH"
export BATON_WATCH_INTERVAL="0.2"
mkdir -p "$Q14_SCRATCH/fake_a_home/.claude"
ln -s "$Q14_SCRATCH/fake_a_home/.claude" "$BATON_ACCOUNTS_ROOT/a"
mkdir -p "$BATON_ACCOUNTS_ROOT/b" "$BATON_ACCOUNTS_ROOT/.alive"
touch "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b"

"$BATON_BIN" --status >/dev/null 2>&1

write_behavior a <<'EOF'
STEP_EXIT=(1 1)
STEP_STDOUT=("usage limit reached" "usage limit reached")
EOF
"$BATON_BIN" --night >/dev/null 2>&1

if [ "$real_root_existed" -eq 1 ]; then
  changed=$(find "$REAL_ROOT" -newer "$marker" 2>/dev/null)
  check "real \$HOME/.claude-accounts has no file newer than the pre-run marker" $([ -z "$changed" ]; echo $?)
else
  check "real \$HOME/.claude-accounts still does not exist" $([ ! -d "$REAL_ROOT" ]; echo $?)
fi

fakes=$(find "$REAL_HOME/.claude" -maxdepth 1 -name '.fake-*' -newer "$marker" 2>/dev/null)
check "real ~/.claude gained no fake-fixture files" $([ -z "$fakes" ]; echo $?)

rm -f "$marker"
rm -rf "$Q14_SCRATCH"
unset BATON_ACCOUNTS_ROOT
block_end

# ============================================================================
# 15. The morning after: the host died mid-run and two terminals came back.
#     baton#2 acceptance: "A kill-and-double-relaunch QA scenario proves
#     exactly one survivor claims the session."
#
#     This is the one block that is not in features/failover.feature, and it
#     is deliberately last, because it is the story that starts where every
#     other block ends: a run that was interrupted rather than finished. The
#     operator opens two terminals (or a launchd relaunch races an
#     interactive start), both read the same board, and both want to pick the
#     same session back up. Exactly one may.
# ============================================================================
block_begin "15 kill-and-double-relaunch: exactly one survivor claims the session" "baton#2 acceptance"
fresh_root
export BATON_LOCK_PROV=test

SID="sess-morning-after"
write_behavior a <<'EOF'
STEP_BLOCK=(1)
STEP_TRANSCRIPT=("sess-morning-after")
STEP_STDOUT=("half way through the night")
EOF

# Every other block sets a 0.2s poll so the watcher acts quickly. This block
# wants the opposite: its subject is a host that died with a child still
# working, so the watcher must NOT get a poll cycle in during the second it
# takes to set the scene. At the suite-wide 0.2s the watcher occasionally
# reached in and SIGTERMed the child before it could become an orphan
# (measured 1 in 6 runs, diagnosed from the fixture's own signals log), which
# is a property of the setup, not of anything this block asserts.
BATON_WATCH_INTERVAL=5
export BATON_WATCH_INTERVAL

start_night
f="$(wait_for_transcript a 10)"
check "the night's session was really running before the host died" $([ -n "$f" ]; echo $?)

# The host dies: the parent goes, the child is reparented and keeps running.
stop_night

RUNS="$BATON_ACCOUNTS_ROOT/.runs"
start_receipt="$(ls -1 "$RUNS"/*.start 2>/dev/null | head -1)"
check "a start receipt survived the host" $([ -n "$start_receipt" ]; echo $?)
Q15_UNIT="$(basename "${start_receipt:-none}" .start)"
Q15_ORPHAN="$(sed -n 's/^pid=//p' "${start_receipt:-/dev/null}" 2>/dev/null | head -1)"

# Both terminals read the identical board, because the board is a projection
# and carries no ownership. That is correct, and it is exactly why the board
# cannot be the thing that arbitrates.
board_a="$("$BATON_BIN" --pickup 2>/dev/null)"
board_b="$("$BATON_BIN" --pickup 2>/dev/null)"
check "both terminals see the same board (a projection arbitrates nothing)" \
  $([ "$(printf '%s' "$board_a" | grep -c '"unit"')" = "$(printf '%s' "$board_b" | grep -c '"unit"')" ]; echo $?)
check "the board inspected more than zero units" \
  $(printf '%s' "$board_a" | grep -qE '"inspected": [1-9]'; echo $?)

# Both terminals now try to pick the session back up. The work each would do
# is represented by one line appended to a shared log; two lines is the
# duplicate this whole issue is about.
Q15_LOG="$SCRATCH/relaunches.log"
: > "$Q15_LOG"
"$BATON_BIN" --claim "session:$SID" -- sh -c "echo relaunched >> '$Q15_LOG'; sleep 2" \
  >"$SCRATCH/t1.out" 2>"$SCRATCH/t1.err" &
T1=$!
"$BATON_BIN" --claim "session:$SID" -- sh -c "echo relaunched >> '$Q15_LOG'; sleep 2" \
  >"$SCRATCH/t2.out" 2>"$SCRATCH/t2.err" &
T2=$!
wait "$T1"; Q15_RC1=$?
wait "$T2"; Q15_RC2=$?

q15_relaunches=$(grep -c relaunched "$Q15_LOG" 2>/dev/null || true)
q15_winners=0
[ "$Q15_RC1" -eq 0 ] && q15_winners=$((q15_winners + 1))
[ "$Q15_RC2" -eq 0 ] && q15_winners=$((q15_winners + 1))

check "exactly one relaunch happened" $([ "$q15_relaunches" -eq 1 ]; echo $?)
check "exactly one terminal survived the claim" $([ "$q15_winners" -eq 1 ]; echo $?)
check "the relaunch count is positive (not simply both refused)" $([ "$q15_relaunches" -gt 0 ]; echo $?)

if [ "$Q15_RC1" -ne 0 ]; then q15_loser="$SCRATCH/t1.err"; q15_winner="$T2"; else q15_loser="$SCRATCH/t2.err"; q15_winner="$T1"; fi
check "the losing terminal exited nonzero" $([ "$Q15_RC1" -ne 0 ] || [ "$Q15_RC2" -ne 0 ]; echo $?)
check "the losing terminal was told which pid held the session" $(grep -q "$q15_winner" "$q15_loser"; echo $?)

# And the orphan the night left behind: redoing that unit kills it and
# CONFIRMS the death before the replacement starts. The replacement's first
# instruction is the probe, so any window in which both were alive is exactly
# what it would capture.
#
# The probe compares IDENTITY, not presence. `ps -p <pid>` answering at all is
# the bare-pid check lock.sh exists to reject: this block runs last, after
# fourteen others have spawned hundreds of short-lived processes, so the
# orphan's number is genuinely likely to be reused within milliseconds of its
# death -- and it was, which is how this row first went red. A stranger at the
# same number is not the orphan. Measured: the same probe run in isolation was
# clean 15 of 15, and only ever failed inside the full workflow.
Q15_ORPHAN_ARGS="$(ps -p "${Q15_ORPHAN:-0}" -o args= 2>/dev/null | tr -s ' ')"
check "the orphan from the interrupted night is still alive" \
  $([ -n "$Q15_ORPHAN_ARGS" ]; echo $?)
[ -n "$Q15_ORPHAN_ARGS" ] || {
  echo "  15: no orphan at pid ${Q15_ORPHAN:-none} when the reconcile began." >&2
  echo "  15:   receipt      = $start_receipt" >&2
  echo "  15:   signals log  = [$(cat "$(signals_log_of a)" 2>/dev/null)]" >&2
  echo "  15:   board        = $("$BATON_BIN" --pickup 2>/dev/null | tr -d '\n')" >&2
}
"$BATON_BIN" --redispatch "$Q15_UNIT" -- \
  sh -c "ps -p $Q15_ORPHAN -o args= > '$SCRATCH/q15-overlap' 2>/dev/null; echo replaced >> '$SCRATCH/q15-replacements.log'" \
  >/dev/null 2>&1
q15_redrc=$?
q15_ov="$(tr -s ' ' < "$SCRATCH/q15-overlap" 2>/dev/null)"
check "the redispatch exited 0" $([ "$q15_redrc" -eq 0 ]; echo $?)
check "the replacement ran exactly once" \
  $([ "$(grep -c replaced "$SCRATCH/q15-replacements.log" 2>/dev/null || echo 0)" -eq 1 ]; echo $?)
check "there was no window in which the orphan and its replacement were both alive" \
  $([ "$q15_ov" != "$Q15_ORPHAN_ARGS" ]; echo $?)
[ "$q15_ov" != "$Q15_ORPHAN_ARGS" ] || {
  echo "  15: the orphan was STILL ITSELF when the replacement started." >&2
  echo "  15:   orphan pid   = $Q15_ORPHAN" >&2
  echo "  15:   orphan args  = [$Q15_ORPHAN_ARGS]" >&2
  echo "  15:   probe saw    = [$q15_ov]" >&2
}

unset BATON_LOCK_PROV
cleanup_root
block_end

# ============================================================================
# Tally
# ============================================================================
total=$(grep -cE '^(PASS|FAIL) block' "$QA_RESULTS" 2>/dev/null)
passed=$(grep -c '^PASS block' "$QA_RESULTS" 2>/dev/null)
failed=$(grep -c '^FAIL block' "$QA_RESULTS" 2>/dev/null)

echo ""
echo "----"
grep '^FAIL block' "$QA_RESULTS" 2>/dev/null || true
echo "QA BLOCKS: $total  PASS: $passed  FAIL: $failed  (15 expected: 14 from features/failover.feature -- background excluded, scenarios 15-26 excluded per assignment -- plus block 15, the kill-and-double-relaunch walkthrough baton#2 asks this workflow to carry)"

# The count is asserted, not reported. A block that died mid-file writes no
# result line, and a missing line is invisible in a PASS/FAIL tally: the
# workflow would just report one fewer block and still exit 0.
if [ "$total" -ne 15 ]; then
  echo "qa_failover: expected exactly 15 assertion blocks, got $total" >&2
  exit 1
fi

[ "$failed" -eq 0 ]
