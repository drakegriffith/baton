#!/usr/bin/env bash
# detect -- pure text classification, nothing else.
#
# Why this file exists on its own: probe() (headless, in accounts.sh) and the
# --night transcript watcher (in watch.sh) both need to answer "does this
# text mean the account is in trouble?", and DOC.md's failure mode to avoid
# is two regex copies drifting apart. So the answer lives in exactly one
# place, as a pure function of a string: no file, account, or process
# knowledge. classify_text() is a total partition -- every input maps to
# exactly one of LIMIT, AUTH, UNKNOWN, never none, never both.
#
# ALIVE (the fourth probe() outcome) is deliberately NOT part of this
# contract: it only makes sense for a probe's own canary reply ("ok"), and
# the watcher is never sending a canary, only watching for trouble. See
# features/failover.feature D2.

classify_text() { # $1 raw text -> LIMIT|AUTH|UNKNOWN
  local text="$1"
  if printf '%s' "$text" | grep -qiE 'hit your .*limit|usage limit|limit reached'; then
    echo LIMIT
  elif printf '%s' "$text" | grep -qiE 'not logged in|please run /login|invalid api key|authentication'; then
    echo AUTH
  else
    echo UNKNOWN
  fi
}

parse_reset_epoch() { # stdin: limit message -> epoch of "resets 2:30pm (TZ)", or 0 if unparseable
  python3 -c '
import re, sys, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None
msg = sys.stdin.read()
m = re.search(r"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?", msg, re.I)
if not m:
    print(0); sys.exit()
h = int(m.group(1)) % 12
if m.group(3).lower() == "pm":
    h += 12
mi = int(m.group(2) or 0)
tz = None
if m.group(4) and ZoneInfo:
    try: tz = ZoneInfo(m.group(4))
    except Exception: tz = None
nowt = datetime.datetime.now(tz)
t = nowt.replace(hour=h, minute=mi, second=0, microsecond=0)
if t <= nowt:
    t += datetime.timedelta(days=1)
print(int(t.timestamp()))
' 2>/dev/null || echo 0
}
