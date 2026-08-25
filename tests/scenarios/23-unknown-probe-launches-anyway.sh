#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): an UNKNOWN probe result (the CLI
# said something that is neither the canary reply nor a limit/auth message
# -- a network outage, a proxy error page) must NOT take the account out of
# the running. baton's header states the reason: an outage affects every
# account equally, so refusing to launch would strand the user with no
# account at all. Scenario 10 pins what `--probe` PRINTS for unknown text;
# nothing pinned what pick_live DOES with it, so making UNKNOWN skip the
# account kept the suite green. Kills mutant M15.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "23-unknown-probe-launches-anyway"
fresh_root

# Drop the alive marks so the pick actually probes instead of trusting the
# 15-minute cache.
rm -f "$BATON_ACCOUNTS_ROOT/.alive/a" "$BATON_ACCOUNTS_ROOT/.alive/b"

write_behavior a <<'EOF'
STEP_STDOUT=("curl: (6) could not resolve host" "curl: (6) could not resolve host")
EOF
write_behavior b <<'EOF'
STEP_STDOUT=("curl: (6) could not resolve host" "curl: (6) could not resolve host")
EOF

out=$("$BATON_BIN" some-arg 2>&1); rc=$?
scenario_check "baton did not die" $([ "$rc" -eq 0 ]; echo $?)
scenario_check "no 'no live account' message" $(! printf '%s' "$out" | grep -q "no live account"; echo $?)
scenario_check "warned that it is launching anyway" $(printf '%s' "$out" | grep -qi "launching anyway"; echo $?)

log="$(fake_log)"
scenario_check "the probed account was probed" \
  $(grep "config=$(config_dir_of a) " "$log" | grep -q "argv=-p"; echo $?)
scenario_check "and then launched with the user's args" \
  $(grep "config=$(config_dir_of a) " "$log" | grep -q "argv=some-arg"; echo $?)
scenario_check "the unknown result left no dead mark" $(! is_dead_marked a; echo $?)

cleanup_root
scenario_end
