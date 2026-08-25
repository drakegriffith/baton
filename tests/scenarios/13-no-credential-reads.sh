#!/usr/bin/env bash
# Gherkin: "The watcher never reads account credentials" (@dependency).
# QA-DOC section 4 rule 4 + section 5 row 13: this is the forbidden-
# dependency test -- if `watch` ever grew a read of a credentials file
# (chmod 000 here), the OS would either bump its atime (impossible, it's
# unreadable, so a bare open() attempt instead throws EACCES) or the attempt
# would surface as "Permission denied" on stderr and the sentinel's mtime
# would move if anything ever tried to touch/rewrite it. This observes
# EFFECTS on the real filesystem/output, never source text, so it still
# fails if the forbidden watch -> credentials edge is reintroduced.
set -u
. "$FIXTURES_DIR/lib.sh"
scenario_begin "13-watcher-never-reads-credentials"
fresh_root

sentinel="$(config_dir_of a)/credentials.json"
echo '{"secret":"not-a-real-key"}' > "$sentinel"
chmod 000 "$sentinel"
# macOS BSD stat: %m = mtime epoch, %a = last-access epoch.
before_mtime=$(stat -f %m "$sentinel")
before_atime_epoch=$(stat -f %a "$sentinel")

write_behavior a <<'EOF'
STEP_EXIT=(0)
STEP_TRANSCRIPT=("sess-creds")
STEP_BLOCK=(1)
STEP_BLOCK_EXIT=(143)
EOF
write_behavior b <<'EOF'
STEP_EXIT=(0)
STEP_STDOUT=("done from b")
EOF

start_night
f=$(wait_for_transcript a 5)
scenario_check "transcript file appeared" $([ -n "$f" ]; echo $?)
printf '%s\n' 'You have hit your usage limit. resets 11:59pm (UTC)' >> "$f"

wait_for_night_exit 10
scenario_check "night process exited" $?
scenario_check "handoff to b completed" $(grep -q "config=$(config_dir_of b) " "$(fake_log)"; echo $?)
scenario_check "a marked dead" $(is_dead_marked a; echo $?)

after_mtime=$(stat -f %m "$sentinel")
after_atime_epoch=$(stat -f %a "$sentinel")
scenario_check "sentinel mtime unchanged" $([ "$before_mtime" = "$after_mtime" ]; echo $?)
scenario_check "sentinel atime unchanged" $([ "$before_atime_epoch" = "$after_atime_epoch" ]; echo $?)
scenario_check "no permission-denied message referencing the sentinel anywhere in stderr" \
  $(! grep -i "permission denied" "$SCRATCH/night.err" | grep -q "credentials.json"; echo $?)
scenario_check "no permission-denied message at all" $(! grep -qi "permission denied" "$SCRATCH/night.err"; echo $?)

chmod 600 "$sentinel"
cleanup_root
scenario_end
