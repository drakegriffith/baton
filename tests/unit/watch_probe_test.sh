#!/usr/bin/env bash
# Exercise the confirmation guard with the real headless probe and fake CLI.
# No process-table access or real account credentials are needed here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FIXTURES_DIR:=$HERE/../fixtures}"
: "${RESULTS_FILE:=$(mktemp)}"
. "$FIXTURES_DIR/lib.sh"
. "$HERE/../../lib/detect.sh"
. "$HERE/../../lib/watch.sh"
now() { date +%s; }
warn() { echo "baton: $*" >&2; }
pass=0; fail=0
check() {
  if [ "$2" -eq 0 ]; then
    record_pass "unit:watch-probe:$1"; pass=$((pass + 1))
  else
    record_fail "unit:watch-probe:$1" "assertion failed"; fail=$((fail + 1))
  fi
}

check_probe() { # account, probe reply, expected class, expected guard status
  local account="$1" reply="$2" expected="$3" expected_rc="$4" rc rows
  fresh_root
  . "$HERE/../../lib/accounts.sh"
  write_behavior "$account" <<EOF
STEP_STDOUT=("$reply")
EOF
  PROBE_CLASS=UNSET
  confirm_transcript_auth "$account" >"$SCRATCH/guard.out" 2>"$SCRATCH/guard.err"
  rc=$?
  check "$account:$expected:decision" $([ "$rc" -eq "$expected_rc" ]; echo $?)
  check "$account:$expected:fresh-probe" $([ "$PROBE_CLASS" = "$expected" ]; echo $?)
  check "$account:$expected:current-account-only" \
    $([ "$(invocation_count "$account")" -eq 1 ] && [ "$(wc -l < "$(fake_log)" | tr -d ' ')" -eq 1 ]; echo $?)
  check "$account:$expected:headless-probe" \
    $(grep -qF 'argv=-p reply\ with\ exactly:\ ok' "$(fake_log)"; echo $?)
  check "$account:$expected:quiet-streams" \
    $([ ! -s "$SCRATCH/guard.out" ] && [ ! -s "$SCRATCH/guard.err" ]; echo $?)
  if [ "$expected" = AUTH ]; then
    check "$account:$expected:auth-mark" $([ "$(dead_reason_of "$account")" = auth ]; echo $?)
    check "$account:$expected:no-suppression" $([ ! -e "$HANDOFF_LOG" ]; echo $?)
  else
    rows=$(grep -c 'false-auth-suppressed' "$HANDOFF_LOG" 2>/dev/null || true)
    check "$account:$expected:one-timestamped-suppression" \
      $([ "$rows" = 1 ] && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} baton: false-auth-suppressed account=$account probe=$expected$" "$HANDOFF_LOG"; echo $?)
  fi
  cleanup_root
}

check_probe a 'ok' ALIVE 1
check_probe a 'network unavailable' UNKNOWN 1
check_probe a 'usage limit reached' LIMIT 1
check_probe a 'Invalid API key - Please run /login' AUTH 0
check_probe b 'OAuth token has expired' AUTH 0

echo "watch_probe_test: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
