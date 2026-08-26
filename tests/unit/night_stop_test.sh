#!/usr/bin/env bash
# die_night_stopped: the runnable resume line goes to the handoff log only,
# and only when both halves are safe to paste; stderr names the session and
# the log path in words. verify-cap (2026-08-26) showed an unquoted id with a
# space or a leading dash produced a non-runnable command presented as
# runnable, and PR #4's rule keeps runnable commands off shared streams.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
pass=0; fail=0
: "${RESULTS_FILE:=$(mktemp)}"
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "PASS $1" >>"$RESULTS_FILE"; else fail=$((fail+1)); echo "FAIL $1" >>"$RESULTS_FILE"; echo "  FAIL: $1"; fi; }
run_stop() { # $1 root $2 account $3 session id -> stderr text; log at $1/.handoff.log
  ( HOME="$(mktemp -d)"; export HOME; export BATON_ACCOUNTS_ROOT="$1"
    die() { echo "baton: $*" >&2; exit 1; }; warn() { echo "baton: $*" >&2; }
    . "$ROOT_DIR/lib/accounts.sh"
    die_night_stopped "reason" "$2" "$3" ) 2>&1
}
root=$(mktemp -d); out=$(run_stop "$root" b sess-ok-01); rc=$?; log="$root/.handoff.log"
check "valid id: exit 75" $([ "$rc" -eq 75 ]; echo $?)
check "valid id: log carries the exact resume line" $(grep -qF "resume line: baton b --resume sess-ok-01" "$log"; echo $?)
check "valid id: stderr carries no runnable resume line" $(! printf '%s' "$out" | grep -q "resume line: baton"; echo $?)
check "valid id: stderr names session id and log path" $(printf '%s' "$out" | grep -qF "session id 'sess-ok-01'; the resume line is in the handoff log: $log"; echo $?)
root=$(mktemp -d); out=$(run_stop "$root" b "sess with spaces"); log="$root/.handoff.log"
check "space in id: no resume line rendered anywhere" $(! grep -q "resume line: baton" "$log" && ! printf '%s' "$out" | grep -q "resume line: baton"; echo $?)
check "space in id: withheld in words in the log" $(grep -q "resume line withheld (unsafe session id)" "$log"; echo $?)
root=$(mktemp -d); out=$(run_stop "$root" b "-rf danger"); log="$root/.handoff.log"
check "leading dash id: no resume line rendered" $(! grep -q "resume line: baton" "$log"; echo $?)
root=$(mktemp -d); out=$(run_stop "$root" "" sess-ok-02); log="$root/.handoff.log"
check "unknown account with known id: withheld in words" $(grep -q "withheld because the account is unknown" "$log" && ! grep -q "resume line: baton" "$log"; echo $?)
root=$(mktemp -d); out=$(run_stop "$root" "" ""); log="$root/.handoff.log"
check "both unknown: no empty quotes on stderr or in the log" $(! printf '%s' "$out" | grep -q "''" && ! grep -q "''" "$log"; echo $?)
check "both unknown: says unknown in words" $(printf '%s' "$out" | grep -q "last account unknown" && printf '%s' "$out" | grep -q "session id unknown"; echo $?)
echo "night_stop_test: $pass pass, $fail fail"
