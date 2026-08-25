#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): marking an account dead must also
# drop its ALIVE cache entry, so that when the mark expires the account is
# re-PROBED instead of launched on the strength of a 15-minute-old "it
# answered once" file. Without this, an account that hit its limit at 01:00
# and whose 5h mark expires at 06:00 would be launched blind at 06:00 from
# a cache entry written before the limit. Kills mutant M11 (mark_dead no
# longer removes $ALIVEDIR/<name>).
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "16-dead-mark-invalidates-alive-cache"
fresh_root

# Only b can be picked: a is parked well into the future.
"$BATON_BIN" --dead a 90m >/dev/null 2>&1

# b starts alive-cached (fresh_root touches .alive/b). Mark it dead for one
# second and let the mark expire: the cache entry must not have survived it.
"$BATON_BIN" --dead b 1 >/dev/null 2>&1
scenario_check "dead mark written for b" $(is_dead_marked b; echo $?)
sleep 1.5
scenario_check "b's alive-cache entry is gone" $([ ! -e "$BATON_ACCOUNTS_ROOT/.alive/b" ]; echo $?)

write_behavior b <<'EOF'
STEP_STDOUT=("ok" "ok")
EOF

"$BATON_BIN" some-arg >/dev/null 2>&1

log="$(fake_log)"
scenario_check "b was probed (headless -p) before being launched" \
  $(grep "config=$(config_dir_of b) " "$log" | grep -q "argv=-p"; echo $?)
scenario_check "b was then launched with the user's args" \
  $(grep "config=$(config_dir_of b) " "$log" | grep -q "argv=some-arg"; echo $?)

cleanup_root
scenario_end
