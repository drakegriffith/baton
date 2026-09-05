#!/usr/bin/env bash
# Transcript role eligibility is separate from the text classifier and the
# account probe. These rows pin the boundary without launching a night lane.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/detect.sh"
. "$HERE/../../lib/watch.sh"
. "$HERE/../fixtures/lib.sh"
: "${RESULTS_FILE:=$(mktemp)}"
pass=0; fail=0

check_line() { # name, raw JSONL/text, expected rotation class
  local got
  got=$(classify_transcript_line "$2")
  if [ "$got" = "$3" ]; then
    record_pass "unit:watch-role:$1"; pass=$((pass + 1))
  else
    record_fail "unit:watch-role:$1" "expected $3 got [$got]"; fail=$((fail + 1))
  fi
}

check_line user-tool-result '{"type":"user","message":{"content":[{"type":"tool_result","content":"Invalid API key - Please run /login"}]}}' UNKNOWN
check_line assistant-positive-control '{"type":"assistant","message":{"content":[{"type":"text","text":"Invalid API key - Please run /login"}]}}' AUTH
check_line system-positive-control '{"type":"system","text":"Invalid API key - Please run /login"}' AUTH
for role in attachment summary progress; do
  check_line "$role" "{\"type\":\"$role\",\"text\":\"Invalid API key - Please run /login\"}" UNKNOWN
done
check_line nested-assistant-is-not-top-level '{"type":"user","message":{"type":"assistant","text":"Invalid API key"}}' UNKNOWN
check_line missing-role '{"message":{"content":"Invalid API key"}}' UNKNOWN
check_line json-array '[{"type":"assistant","text":"Invalid API key"}]' UNKNOWN
check_line json-string '"Invalid API key"' UNKNOWN
check_line plain-text-fallback 'Invalid API key - Please run /login' AUTH
check_line malformed-json-fallback '{"type":"user","text":"Invalid API key"' AUTH
check_line escaped-role '{"type":"\u0061ssistant","text":"Invalid API key"}' AUTH
check_line user-limit '{"type":"user","text":"usage limit reached"}' UNKNOWN
check_line assistant-limit '{"type":"assistant","text":"usage limit reached"}' LIMIT
check_line plain-limit 'usage limit reached' LIMIT

echo "watch_auth_test: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
