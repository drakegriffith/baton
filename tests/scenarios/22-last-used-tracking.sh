#!/usr/bin/env bash
# seat4 hardening test (no Gherkin row): every launch records the account it
# used in .last, and two operator-facing behaviours read it -- `--status`
# marks that row "<- last", and `--dead` / `--next` with no name act on it.
# Nothing pinned that: scenario 12 gives each invocation a fresh root, so
# both batons see an empty .last and agree. Dropping the write left the
# whole suite green while `baton --dead` (the "park the account I was just
# using" gesture) became a no-op that dies with "no last-used account".
# Kills mutant M17.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "22-last-used-tracking"
fresh_root

write_behavior a <<'EOF'
STEP_STDOUT=("from a")
EOF

"$BATON_BIN" some-arg >/dev/null 2>&1
scenario_check "launch recorded a as last-used" $([ "$(cat "$BATON_ACCOUNTS_ROOT/.last" 2>/dev/null)" = a ]; echo $?)

status=$("$BATON_BIN" --status 2>&1)
scenario_check "--status marks a as the last-used account" \
  $(printf '%s\n' "$status" | grep '^a ' | grep -q "last"; echo $?)
scenario_check "--status does not mark b" \
  $(! printf '%s\n' "$status" | grep '^b ' | grep -q "last"; echo $?)

out=$("$BATON_BIN" --dead 2>&1); rc=$?
scenario_check "--dead with no name succeeded" $([ "$rc" -eq 0 ]; echo $?)
scenario_check "--dead with no name parked the last-used account" $(is_dead_marked a; echo $?)
scenario_check "--dead with no name left b alone" $(! is_dead_marked b; echo $?)
scenario_check "--dead with no name named a in its message" $(printf '%s' "$out" | grep -q "'a'"; echo $?)

cleanup_root
scenario_end
