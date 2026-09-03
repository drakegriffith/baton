#!/usr/bin/env bash
# usage -- the reader for the ONE usage signal baton is allowed to see.
#
# Why this is its own file, beside detect.sh: it is the second pure-ish
# module (no process knowledge, no child, no side effects -- it reads one
# file and prints one token), and it is the only place in the codebase that
# knows the shape of that file. watch.sh's header rule stands unchanged --
# the watcher never opens .claude.json or a credentials file -- because the
# signal comes from a DIFFERENT file that a different program writes.
#
# Who writes it: the harness statusline script, on every render, to
# <CLAUDE_CONFIG_DIR>/.rate-limits.json (for a baton account that resolves to
# $ROOT/<name>/.rate-limits.json, through the primary account's symlink like
# everything else). baton only ever reads it. Content is the statusline's own
# `.rate_limits` object plus `written_at`, a unix epoch:
#
#   {"five_hour":{"used_percentage":83,"resets_at":1756900000},
#    "seven_day":{"used_percentage":40,"resets_at":1757300000},
#    "written_at":1756870000}
#
# THE RULE THIS FILE EXISTS TO ENFORCE (failover.feature D8): every way of
# not knowing answers the single token `unknown`, and `unknown` never arms
# anything. Missing file, unparseable JSON, absent field, non-numeric value,
# and a write older than the caller's max age are all the same answer,
# because they are the same fact -- baton does not know how much of the
# window is gone. The alternative spelling (0, or an empty string) is worse
# than useless here: it is a confident number about a five-hour budget,
# derived from no measurement, and the thing it would drive is switching a
# working account off.
#
# Staleness is the CALLER'S number, passed in, never re-read from the
# environment here: night_knobs validates BATON_USAGE_MAX_AGE once before any
# child is launched and hands the validated value down, so a knob cannot mean
# one thing at validation time and another at use time (the one-reader-per-
# knob rule watch.sh's night_knobs already follows).

USAGE_SIGNAL_FILE=".rate-limits.json"
USAGE_MAX_AGE_DEFAULT=600

# usage_signal_path NAME -> where that account's signal file lives. $ROOT is
# accounts.sh's accounts root, read at call time (this file defines functions
# and two constants, nothing else, so it can be sourced anywhere).
usage_signal_path() { printf '%s/%s/%s' "$ROOT" "$1" "$USAGE_SIGNAL_FILE"; }

# _usage_read FILE FIELD MAX_AGE -> the five_hour FIELD, or `unknown`.
# python3 for the JSON, exactly as detect.sh's parse_reset_epoch does, and
# for the same reason: a shell-side parse of someone else's JSON is a second
# schema in a language with no parser.
_usage_read() {
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || printf 'unknown\n'
import json, sys, time

path, field, max_age = sys.argv[1], sys.argv[2], sys.argv[3]


def unknown():
    print("unknown")
    raise SystemExit(0)


try:
    max_age = float(max_age)
except (TypeError, ValueError):
    max_age = 600.0

try:
    with open(path) as fh:
        doc = json.load(fh)
except Exception:
    unknown()

if not isinstance(doc, dict):
    unknown()


def number(value):
    # bool is an int in python; a JSON `true` is not a percentage.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


written = number(doc.get("written_at"))
if written is None or time.time() - written > max_age:
    unknown()

window = doc.get("five_hour")
if not isinstance(window, dict):
    unknown()

value = number(window.get(field))
if value is None:
    unknown()

if field == "used_percentage":
    # Clamped, then rendered to two decimals: the fraction is compared
    # against an operator-set threshold, and a server that ever reports 104%
    # must not read as a different KIND of number than 100%.
    print("%.2f" % (max(0.0, min(100.0, value)) / 100.0))
else:
    print("%d" % value)
PY
}

# usage_fraction NAME [MAX_AGE] -> "0.00".."1.00", or `unknown`.
usage_fraction() {
  _usage_read "$(usage_signal_path "$1")" used_percentage "${2:-$USAGE_MAX_AGE_DEFAULT}"
}

# usage_reset_epoch NAME [MAX_AGE] -> the epoch the five-hour window resets
# at, or `unknown`. Used to date a soft dead mark from the account's own
# reported reset rather than from a default duration -- the same preference
# mark_dead_for_class already has for a LIMIT message's parsed reset.
usage_reset_epoch() {
  _usage_read "$(usage_signal_path "$1")" resets_at "${2:-$USAGE_MAX_AGE_DEFAULT}"
}
