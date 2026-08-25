#!/usr/bin/env bash
# Unit tests for lib/detect.sh -- the one file in the codebase safe to source
# directly (pure functions, no set -u/ROOT dependency, no side effects).
# Everything else in tests/ drives the real `baton` subprocess per QA-DOC
# section 1; this file is the deliberate exception for the pure module.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/detect.sh"
. "$HERE/../fixtures/lib.sh"

check_class() { # $1 name, $2 text, $3 expected class
  local got
  got="$(classify_text "$2")"
  if [ "$got" = "$3" ]; then
    record_pass "unit:classify_text:$1"
  else
    record_fail "unit:classify_text:$1" "expected $3 got $got for text [$2]"
  fi
}

# The same six rows the Gherkin outline exercises (Scenario Outline "The same
# shared classification function backs both detection paths"), plus a few
# edge cases the outline doesn't reach -- multi-line transcript-style text and
# case-insensitivity -- because a unit test's job is coverage the black-box
# system tests are too coarse to bother with.
check_class "limit-with-reset"      "You've hit your usage limit. resets 2:30pm (America/New_York)" LIMIT
check_class "limit-reached-phrase"  "usage limit reached for this account" LIMIT
check_class "auth-please-login"     "Not logged in. Please run /login" AUTH
check_class "auth-invalid-key"      "Invalid API key" AUTH
check_class "ordinary-chatter"      "Here is the code you asked for..." UNKNOWN
check_class "empty-string"          "" UNKNOWN
check_class "case-insensitive-auth" "NOT LOGGED IN, please authenticate" AUTH
check_class "multiline-json-line"   '{"type":"assistant","text":"You have HIT YOUR USAGE LIMIT, resets 9am"}' LIMIT
check_class "auth-word-only"        "authentication required before continuing" AUTH
check_class "limit-word-not-alone"  "there is a rate limiter but nothing about usage" UNKNOWN

check_reset() { # $1 name, $2 text, $3 grep pattern the epoch must satisfy ("gt-now" or "eq-0")
  local epoch now
  epoch="$(printf '%s' "$2" | parse_reset_epoch)"
  now="$(date +%s)"
  case "$3" in
    gt-now)
      if [ "$epoch" -gt "$now" ] 2>/dev/null; then
        record_pass "unit:parse_reset_epoch:$1"
      else
        record_fail "unit:parse_reset_epoch:$1" "expected epoch > now, got $epoch"
      fi
      ;;
    eq-0)
      if [ "$epoch" = 0 ]; then
        record_pass "unit:parse_reset_epoch:$1"
      else
        record_fail "unit:parse_reset_epoch:$1" "expected 0, got $epoch"
      fi
      ;;
  esac
}

check_reset "parses-explicit-time" "hit your usage limit. resets 11:45pm (UTC)" gt-now
check_reset "no-resets-clause"     "hit your usage limit, try again later" eq-0
check_reset "not-a-limit-message"  "hello world" eq-0
