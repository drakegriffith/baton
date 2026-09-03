#!/usr/bin/env bash
# Unit tests for lib/usage.sh -- the reader for the statusline's rate-limit
# signal file. Like lib/detect.sh this file is a pure-ish module (one global,
# $ROOT, read at call time; no side effects, no process knowledge), so it is
# the second deliberate exception to "drive the real baton subprocess".
#
# What is being pinned is the FAIL-CLOSED rule (failover.feature D8): every
# way of not knowing -- missing file, malformed JSON, a missing field, a
# stale write -- has to answer the single token `unknown`, never 0 and never
# an empty string. A caller that armed a handoff on an empty string would
# switch accounts on a signal file that was never written.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/usage.sh"
. "$HERE/../fixtures/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP"

# write_signal NAME JSON -- put a signal file where usage_fraction looks.
write_signal() { mkdir -p "$ROOT/$1"; printf '%s' "$2" > "$ROOT/$1/.rate-limits.json"; }

check_fraction() { # $1 label, $2 account, $3 expected, [$4 max_age]
  local got
  got="$(usage_fraction "$2" ${4:+"$4"})"
  if [ "$got" = "$3" ]; then
    record_pass "unit:usage_fraction:$1"
  else
    record_fail "unit:usage_fraction:$1" "expected [$3] got [$got]"
  fi
}

NOW="$(date +%s)"

# --- the ways of not knowing, each of which must fail closed ---------------
check_fraction "missing-account-dir" "nosuch" unknown
mkdir -p "$ROOT/emptydir"
check_fraction "missing-file" "emptydir" unknown
write_signal malformed 'not json at all {'
check_fraction "malformed-json" malformed unknown
write_signal nofield "{\"seven_day\":{\"used_percentage\":40},\"written_at\":$NOW}"
check_fraction "no-five-hour-field" nofield unknown
write_signal nopct "{\"five_hour\":{\"resets_at\":$((NOW+900))},\"written_at\":$NOW}"
check_fraction "five-hour-without-percentage" nopct unknown
write_signal nowritten '{"five_hour":{"used_percentage":83}}'
check_fraction "no-written-at" nowritten unknown
write_signal stale "{\"five_hour\":{\"used_percentage\":83},\"written_at\":$((NOW-4000))}"
check_fraction "stale-beyond-default-max-age" stale unknown
write_signal badpct "{\"five_hour\":{\"used_percentage\":\"eighty\"},\"written_at\":$NOW}"
check_fraction "non-numeric-percentage" badpct unknown
write_signal emptyfile ''
check_fraction "empty-file" emptyfile unknown

# --- the ways of knowing ---------------------------------------------------
write_signal at83 "{\"five_hour\":{\"used_percentage\":83,\"resets_at\":$((NOW+900))},\"seven_day\":{\"used_percentage\":40},\"written_at\":$NOW}"
check_fraction "83-percent" at83 0.83
write_signal at100 "{\"five_hour\":{\"used_percentage\":100},\"written_at\":$NOW}"
check_fraction "100-percent" at100 1.00
write_signal at0 "{\"five_hour\":{\"used_percentage\":0},\"written_at\":$NOW}"
check_fraction "0-percent" at0 0.00
write_signal at805 "{\"five_hour\":{\"used_percentage\":80.5},\"written_at\":$NOW}"
check_fraction "fractional-percent" at805 0.81

# A signal written 4000s ago is fresh under a max age that admits it: the
# staleness rule is the CALLER'S, passed in, never re-read from the
# environment inside the reader (one reader per knob -- night_knobs owns the
# validation and hands the validated number down).
check_fraction "stale-file-under-a-wider-max-age" stale 0.83 9000
check_fraction "fresh-file-under-a-zero-max-age" at83 unknown 0

# --- the reset epoch, same fail-closed rule --------------------------------
check_reset() { # $1 label, $2 account, $3 expected
  local got
  got="$(usage_reset_epoch "$2")"
  if [ "$got" = "$3" ]; then
    record_pass "unit:usage_reset_epoch:$1"
  else
    record_fail "unit:usage_reset_epoch:$1" "expected [$3] got [$got]"
  fi
}
check_reset "present" at83 "$((NOW+900))"
check_reset "absent" at100 unknown
check_reset "missing-file" "nosuch" unknown
