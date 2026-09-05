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
check_class "auth-word-only"        "authentication required before continuing" UNKNOWN
check_class "limit-word-not-alone"  "there is a rate limiter but nothing about usage" UNKNOWN

# Authentication as task subject matter is not evidence about this account.
check_class "auth-lookup-prose" 'the authentication lookup - resolveSeededUser' UNKNOWN
check_class "auth-markdown-heading" '### Authentication' UNKNOWN
check_class "auth-method-error" 'Could not resolve authentication method. Expected ANTHROPIC_API_KEY' UNKNOWN
check_class "auth-cli-positive-control" 'Invalid API key - Please run /login' AUTH
check_class "auth-oauth-expired" 'OAuth token expired' AUTH
check_class "auth-oauth-has-expired" 'OAuth token has expired' AUTH

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

# ---------------------------------------------------------------------------
# seat4 hardening rows (mutation-derived, no Gherkin row of their own).
#
# Precedence. A single transcript line can carry BOTH families of phrase --
# a limit message that also suggests /login, or a login notice followed by a
# limit notice. classify_text tests LIMIT first, and that order is a
# behavioural promise, not an accident: LIMIT parks the account until its
# real reset time, AUTH parks it for a flat hour and tells the operator to
# run /login. Getting the precedence backwards means the wrong dead
# duration and the wrong advice printed at 3am.
check_class "limit-and-auth-one-line" "You have hit your usage limit; you may also need to run /login" LIMIT
check_class "auth-phrase-first"       "Not logged in. Also: usage limit reached" LIMIT
check_class "whitespace-only"         "   " UNKNOWN
check_class "tab-only"                "$(printf '\t')" UNKNOWN
check_class "very-long-line"          "$(head -c 20000 /dev/zero | tr '\0' 'x')" UNKNOWN

# ---------------------------------------------------------------------------
# parse_reset_epoch: the value, not just "nonzero".
#
# Fix the local zone so these rows mean the same thing on any machine. The
# fixture messages carry an explicit (UTC), so a parser that honours the
# zone and one that ignores it give answers hours apart -- which is exactly
# what these windows are checking. Times are built from the wall clock
# rather than hard-coded so the rows stay deterministic whenever the suite
# runs.
export TZ=America/New_York

check_reset_window() { # $1 name, $2 text, $3 min delta secs, $4 max delta secs
  local epoch now delta
  epoch="$(printf '%s' "$2" | parse_reset_epoch)"
  now="$(date +%s)"
  delta=$(( epoch - now ))
  if [ "$epoch" -ne 0 ] && [ "$delta" -ge "$3" ] && [ "$delta" -le "$4" ]; then
    record_pass "unit:parse_reset_epoch:$1"
  else
    record_fail "unit:parse_reset_epoch:$1" "delta ${delta}s outside [$3,$4] (epoch $epoch)"
  fi
}

# A reset time still ahead of now is today's; one already past rolls to
# tomorrow (that is what the `t <= nowt` step is for), so the two windows
# are ~1h and ~23h and no operator flip can satisfy both.
check_reset_window "one-hour-ahead-is-today" \
  "hit your usage limit. resets $(date -u -v+1H '+%-I:%M%p') (UTC)" 1 7200
check_reset_window "one-hour-past-rolls-to-tomorrow" \
  "hit your usage limit. resets $(date -u -v-1H '+%-I:%M%p') (UTC)" 79200 86400
# 12-hour clock boundaries: 12:30pm is noon-thirty, not hour 24, and
# 12:15am is a quarter past midnight, not noon.
check_reset_window "noon-boundary-1230pm" "hit your usage limit. resets 12:30pm (UTC)" 1 86400
check_reset_window "midnight-boundary-1215am" "hit your usage limit. resets 12:15am (UTC)" 1 86400

# A message with no minutes means :00. Asserted as "lands exactly on an
# hour boundary in absolute time", which is true for any local zone and
# does not re-implement the parser to check it.
check_on_the_hour() { # $1 name, $2 text
  local epoch
  epoch="$(printf '%s' "$2" | parse_reset_epoch)"
  if [ "$epoch" -ne 0 ] && [ $(( epoch % 3600 )) -eq 0 ]; then
    record_pass "unit:parse_reset_epoch:$1"
  else
    record_fail "unit:parse_reset_epoch:$1" "epoch $epoch is not on an hour boundary"
  fi
}
check_on_the_hour "no-minutes-means-zero" "hit your usage limit. resets 3am (UTC)"

# Malformed clocks and zones must fall to 0 (the caller's contract: 0 means
# "use the default dead duration"), never to a wrong-but-plausible epoch.
check_reset "impossible-clock"   "hit your usage limit. resets 25:99pm" eq-0
check_reset "no-meridiem"        "hit your usage limit. resets 9 (UTC)" eq-0
check_reset "whitespace-only"    "   " eq-0
check_reset "digits-only"        "12345" eq-0
# An unknown or unterminated zone is not a parse failure: the clock time is
# still usable, read in local time.
check_reset "unknown-timezone"   "hit your usage limit. resets 9pm (Mars/Phobos)" gt-now
check_reset "unterminated-zone"  "hit your usage limit. resets 9pm (" gt-now
