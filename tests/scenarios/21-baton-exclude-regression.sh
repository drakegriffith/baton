#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): BATON_EXCLUDE is a pre-failover
# knob -- at 173fd9e auto_launch ranked with `ranked "${BATON_EXCLUDE:-}"`,
# so `BATON_EXCLUDE=a baton` skipped account a. Extracting pick_live() for
# --night dropped the argument, silently killing the knob; scenario 12
# (existing-flags regression) compares flags, not env knobs, so nothing
# noticed. Restored with this test to pin it, for both the plain and the
# --night entry points, since both now share pick_live.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "21-baton-exclude-regression"
fresh_root

write_behavior a <<'EOF'
STEP_STDOUT=("from a")
EOF
write_behavior b <<'EOF'
STEP_STDOUT=("from b")
EOF

# Both accounts are live and tied on tally, so the default pick is "a"
# (ranked sorts ties by name). Excluding it must move the launch to b.
scenario_check "default pick is a" $([ "$("$BATON_BIN" --pick)" = a ]; echo $?)

env BATON_EXCLUDE=a "$BATON_BIN" some-arg >/dev/null 2>&1
log="$(fake_log)"
scenario_check "excluded account a was never launched" \
  $(! grep -q "config=$(config_dir_of a) " "$log"; echo $?)
scenario_check "b was launched instead" \
  $(grep -q "config=$(config_dir_of b) " "$log"; echo $?)

cleanup_root
scenario_end
