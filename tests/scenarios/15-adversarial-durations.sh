#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): every malformed `--dead <dur>`
# value must fail INTO baton's own error contract -- nonzero exit, the
# "bad duration" message, no dead mark left behind -- instead of the
# pre-hardening behaviour, where `-5h` marked an account "dead until" a
# time in the PAST (exit 0, message printed, mark inert), a 20-digit value
# overflowed bash arithmetic into an unprintable epoch (exit 0, "dead
# until " with an empty date), and `1e3m` leaked a raw
# `lib/accounts.sh: line 44: 1e3: value too great for base` at the
# operator. Kills mutant M08 (duration validation dropped).
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "15-adversarial-durations"
fresh_root

bad_dur() { # $1 the duration string that must be refused
  local out rc
  out=$("$BATON_BIN" --dead b "$1" 2>&1); rc=$?
  scenario_check "[$1] exits nonzero" $([ "$rc" -ne 0 ]; echo $?)
  scenario_check "[$1] reports bad duration" $(printf '%s' "$out" | grep -q "bad duration"; echo $?)
  scenario_check "[$1] leaks no raw shell/date error" \
    $(! printf '%s' "$out" | grep -qiE "value too great|invalid time|integer expression|line [0-9]+:"; echo $?)
  scenario_check "[$1] leaves no dead mark" $(! is_dead_marked b; echo $?)
  rm -f "$BATON_ACCOUNTS_ROOT/.dead/b"
}

bad_dur "abc"
bad_dur "5x"
bad_dur "-5h"
bad_dur "1e3m"
bad_dur "5 h"
bad_dur "12.5h"
bad_dur "99999999999999999999h"
bad_dur " "

# The documented forms still work, and an omitted/empty duration still falls
# back to the documented default (5h) -- validation must not swallow those.
now=$(date +%s)
"$BATON_BIN" --dead b 90m >/dev/null 2>&1
got=$(dead_epoch_of b); diff=$(( got - (now + 5400) )); [ "$diff" -lt 0 ] && diff=$((-diff))
scenario_check "90m marks dead ~5400s out" $([ "$diff" -le 30 ]; echo $?)
rm -f "$BATON_ACCOUNTS_ROOT/.dead/b"

"$BATON_BIN" --dead b >/dev/null 2>&1
got=$(dead_epoch_of b); diff=$(( got - (now + 18000) )); [ "$diff" -lt 0 ] && diff=$((-diff))
scenario_check "omitted duration falls back to the 5h default" $([ "$diff" -le 30 ]; echo $?)
rm -f "$BATON_ACCOUNTS_ROOT/.dead/b"

"$BATON_BIN" --dead b 300 >/dev/null 2>&1
got=$(dead_epoch_of b); diff=$(( got - (now + 300) )); [ "$diff" -lt 0 ] && diff=$((-diff))
scenario_check "bare seconds still accepted" $([ "$diff" -le 30 ]; echo $?)

cleanup_root
scenario_end
