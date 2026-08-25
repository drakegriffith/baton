#!/usr/bin/env bash
# watch -- child-process control for `baton --night`. Depends on detect
# (classify_text, for both the live-transcript and post-exit-probe paths)
# and on accounts' public surface only (pick_live/candidates_exist,
# mark_dead_for_class, probe, set_envargs, bump, die_no_live_account,
# handoff_log, is_uint/is_unum) -- never on accounts'
# private state files directly, and never a second copy of the LIMIT/AUTH
# regex family.
#
# Output rule (issue #2): run_watched backgrounds `claude` WITHOUT
# redirecting it, so the child inherits this process's stdout and stderr --
# the watcher and a full-screen TUI share one terminal for the whole night.
# Anything printed here is therefore printed into a terminal a human is
# using. Nothing in this file may write a runnable command to a stream; the
# durable record goes through accounts.sh's handoff_log().
#
# Forbidden dependency (see QA-DOC section 4 rule 4 and the dependency
# scenario in tests/scenarios): watch's only filesystem reads are transcript
# JSONL files under <config-dir>/projects/<slug>/. It never opens
# .claude.json, a credentials file, or anything else under an account dir.

# night_knobs -- resolve --night's three numeric env knobs ONCE, before any
# child is launched, or die. Unset or empty keeps the documented default;
# anything else must be a number, because all three fail PAST baton's error
# contract otherwise. Measured on the pre-hardening code:
#   BATON_WATCH_INTERVAL=abc     `sleep abc` failed on every poll, so the
#     watcher span at ~12% CPU and wrote 87 KB of shell errors in 3 seconds
#     -- all night, into whatever log the unattended run was pointed at.
#   BATON_MAX_HANDOFFS=abc       `[ n -gt abc ]` printed a raw
#     "integer expression expected" and then answered false forever: the cap
#     silently stopped existing and the run rotated until accounts ran out.
#   BATON_SESSION_WAIT_SECS=abc  the awk give-up comparison never fired, so
#     the documented fallback from `--resume <id>` to `-c` stopped existing.
# BATON_SESSION_WAIT_SECS is still ACCEPTED and still validated, but since
# the D6 amendment (watch every transcript for growth instead of waiting for
# a new file to appear) nothing waits on it: a session id exists exactly when
# a file grew, and the `-c` fallback is now decided by the post-exit-probe
# path alone. Kept because it is a documented knob an operator may already
# have exported, and a knob that is silently ignored should at least still
# refuse a typo rather than pretend a bad value was fine.
# Sets NIGHT_INTERVAL, NIGHT_WAIT_SECS and NIGHT_MAX_HANDOFFS, which
# run_watched and night_mode read INSTEAD of the environment -- one reader
# per knob, so a knob cannot mean one thing at validation time and another
# at use time. run_watched is only ever called from night_mode, which calls
# this first.
night_knobs() {
  NIGHT_INTERVAL="${BATON_WATCH_INTERVAL:-5}"
  NIGHT_WAIT_SECS="${BATON_SESSION_WAIT_SECS:-30}"
  NIGHT_MAX_HANDOFFS="${BATON_MAX_HANDOFFS:-3}"
  is_unum "$NIGHT_INTERVAL" || die "bad BATON_WATCH_INTERVAL '$NIGHT_INTERVAL' (want seconds, e.g. 5)"
  is_unum "$NIGHT_WAIT_SECS" || die "bad BATON_SESSION_WAIT_SECS '$NIGHT_WAIT_SECS' (want seconds, e.g. 30)"
  is_uint "$NIGHT_MAX_HANDOFFS" || die "bad BATON_MAX_HANDOFFS '$NIGHT_MAX_HANDOFFS' (want a whole number, e.g. 3)"
}

# transcript_dir_for CONFIG_DIR -> that account's transcript dir for $PWD,
# using the exact slug rule DOC.md gives the real CLI (absolute cwd, `/` and
# `.` replaced by `-`).
transcript_dir_for() {
  local slug; slug=$(printf '%s' "$PWD" | sed 's/[./]/-/g')
  echo "$1/projects/$slug"
}

# --- watching for GROWTH (D6, amended post-review) ----------------------
#
# What the watcher looks for is a transcript that GROWS after the child is
# launched -- an existing file or a new one -- and it classifies only the
# bytes appended after launch. The file that grew is the session that is
# running, and its basename is the id the next handoff resumes.
#
# Looking only for a file that STARTS EXISTING after launch (the original
# reading of D6) went blind on exactly the run this feature exists for: all
# accounts share projects/ through the harness symlink, so after the first
# handoff `claude --resume <id>` re-opens the SAME JSONL that is already on
# disk. No new file ever appears, so the second limit of the night was never
# seen live, and an unattended run that was supposed to walk every account
# stopped on the second one.
#
# Classifying only the appended bytes is the other half of the fix, and it is
# load-bearing: the transcript a relaunch resumes already ENDS with the LIMIT
# line that caused the previous handoff. Re-reading pre-launch content would
# kill each relaunch on its first poll and burn one account per poll interval.
#
# The three helpers below exist to keep the per-poll cost independent of how
# many transcripts the project directory holds. Measured on this machine
# (2026-08-25), one real project dir under ~/.claude/projects held 5459
# transcripts: `wc -c` per file per poll cost 22 seconds, against a default
# poll interval of 5. `find -newer` over the same directory costs 0.013s and
# names only the handful of files anything has written to, so the snapshot of
# sizes is taken ONCE per child launch (0.46s) and consulted only for a file
# that turns out to have changed.

# transcript_sizes DIR -> "<bytes> <path>" for every transcript in DIR, in a
# single stat pass (find batches the arguments, so a directory with tens of
# thousands of files cannot blow the argv limit).
transcript_sizes() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -name '*.jsonl' -type f -exec stat -f '%z %N' {} + 2>/dev/null
}

# touched_since REF DIR -> transcripts in DIR modified after REF's mtime, one
# path per line. REF is deliberately backdated a couple of seconds by the
# caller: `-newer` is a strict comparison, so a child that creates its
# transcript within the same filesystem timestamp tick as REF would otherwise
# be invisible for the whole run.
touched_since() {
  [ -d "$2" ] || return 0
  find "$2" -maxdepth 1 -name '*.jsonl' -type f -newer "$1" 2>/dev/null
}

# launch_size SNAPSHOT PATH -> the bytes PATH held when the child was
# launched, or 0 if it did not exist then (a transcript created after launch
# is read whole -- none of it is pre-launch content).
launch_size() {
  awk -v p="$2" '{ s=$1; sub(/^[0-9]+ /, "", $0); if ($0 == p) { print s; found=1; exit } }
                 END { if (!found) print 0 }' "$1"
}

# cursor_of TABLE PATH -> bytes of PATH already classified during this run,
# empty when the watcher has not looked at PATH yet (the caller then falls
# back to launch_size). cursor_set returns TABLE with PATH's entry replaced.
# The table only ever holds files that changed during this run -- a handful --
# never the whole directory.
cursor_of() {
  local line
  while IFS= read -r line; do
    [ "${line#* }" = "$2" ] && { printf '%s' "${line%% *}"; return 0; }
  done <<EOF
$1
EOF
}

cursor_set() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ "${line#* }" = "$2" ] && continue
    printf '%s\n' "$line"
  done <<EOF
$1
EOF
  printf '%s %s\n' "$3" "$2"
}

# run_watched NAME RESUME_MODE ARGS... -- launch NAME under its resolved env
# with RESUME_MODE ("" | "resume:<id>" | "continue") prefixed onto ARGS, then
# either wait for it to exit naturally or kill it the instant its transcript
# shows LIMIT/AUTH (classifying the RAW line text per D3 -- schema-agnostic
# on purpose, since the JSON shape of a limit event is unverified). This is
# the one deep function that owns the whole watch-or-reap decision: splitting
# "watch the transcript" from "decide what a kill vs. a natural exit means"
# would just be two functions passing the same five pieces of state back and
# forth, i.e. a shallow module.
#
# On return, sets:
#   NIGHT_RESULT      ROTATE | EXITED
#   NIGHT_EXIT_CODE   (EXITED only) the child's real exit code
#   NIGHT_CLASS       (ROTATE only) LIMIT | AUTH
#   NIGHT_TEXT        (ROTATE only) the raw text that produced NIGHT_CLASS
#   NIGHT_SESSION_ID  (ROTATE only) the basename of the transcript file that
#                     grew, i.e. the id of the session that was actually
#                     running, or "" (means: use -c on the next launch, never
#                     invent an id -- D6). Only ever non-empty when the kill
#                     came from a live transcript match; a post-exit-probe
#                     rotation has nothing to resume (D5: that account's own
#                     session is over, not paused).
run_watched() {
  local name="$1" resume_mode="$2"; shift 2

  # Single-writer guard on the session id (baton#2 root cause 1). All accounts
  # share projects/ through the harness symlink, so a session id names ONE
  # transcript that any account can reopen -- which is what makes two
  # simultaneous `--resume <id>` launches possible in the first place. One of
  # them absorbs the session and the other clobbers the pointer state.
  #
  # The claim is re-entrant for this process: a night that hands one session
  # from account to account is one writer resuming, not two, and lock.sh
  # answers `claimed` when the holder pid is our own. The lock needs no
  # explicit release -- the owner record carries this pid and its start time,
  # so this process dying IS the release, which is the only kind that
  # survives a host restart.
  local lock_sid=""
  case "$resume_mode" in resume:*) lock_sid="${resume_mode#resume:}" ;; esac
  if [ -n "$lock_sid" ]; then
    lock_claim "session:$lock_sid" \
      || die "not resuming session '$lock_sid': another live process is writing it"
  fi

  set_envargs "$name"
  local tdir; tdir=$(transcript_dir_for "$CONFIG_DIR")
  mkdir -p "$tdir"

  # Two bookkeeping files of the watcher's own (QA-DOC section 4 rule 4
  # allows exactly this and nothing else): a backdated mtime reference for
  # "modified since launch", and the pre-launch size of every transcript.
  # Both are written BEFORE the child starts, because that is the whole
  # point: every byte already on disk belongs to a session that is not this
  # child. They are removed on both of this function's exits.
  local ref snap
  ref=$(mktemp -t baton-watch-ref) || die "cannot create a temp file to watch transcripts"
  snap=$(mktemp -t baton-watch-snap) || die "cannot create a temp file to watch transcripts"
  touch -t "$(date -v-2S '+%Y%m%d%H%M.%S')" "$ref" 2>/dev/null || touch "$ref"
  transcript_sizes "$tdir" > "$snap"

  # bash 3.2 errors on "${arr[@]}" for an EMPTY array under set -u (same trap
  # documented at baton's top for the accounts array) -- and this expansion
  # runs inside a backgrounded subshell, where the failure is silent (the
  # subshell dies before ever exec'ing claude, no error surfaces to the
  # caller). Never expand resume_args unguarded.
  local resume_args=()
  case "$resume_mode" in
    resume:*) resume_args=(--resume "${resume_mode#resume:}") ;;
    continue) resume_args=(-c) ;;
  esac

  if [ "${#resume_args[@]}" -gt 0 ]; then
    "${ENVARGS[@]}" claude "${resume_args[@]}" "$@" &
  else
    "${ENVARGS[@]}" claude "$@" &
  fi
  local pid=$!

  # Durable receipts (baton#3). Written the instant the pid exists, because
  # that is the only moment anything knows it: if this process dies here, the
  # child is reparented to launchd and keeps running, and the receipt is then
  # the ONLY evidence distinguishing that live orphan from a unit that never
  # started. The two mktemp files above are still scratch and still deleted;
  # these are not.
  local unit="night-$(date -u +%Y%m%dT%H%M%SZ)-$$-$name"
  runs_record_start "$unit" "$pid" "$(runs_fingerprint "$pid")" "claude ${resume_args[*]-} $*"

  local interval="$NIGHT_INTERVAL"
  local cursors="" f size offset class line

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"

    # Only files something has written to since launch are even looked at,
    # so the poll costs the same in a directory with five transcripts and one
    # with five thousand.
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] || continue
      offset=$(cursor_of "$cursors" "$f")
      [ -n "$offset" ] || offset=$(launch_size "$snap" "$f")
      size=$(wc -c < "$f" | tr -d ' ')
      if [ "$size" -gt "$offset" ]; then
        while IFS= read -r line; do
          class=$(classify_text "$line")
          if [ "$class" = LIMIT ] || [ "$class" = AUTH ]; then
            kill -TERM "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$ref" "$snap"
            # This child's ending was OBSERVED (we ended it), so the unit
            # closes here. Without this receipt a rotated-away child would
            # read as dead-partial forever, and every restart would offer to
            # re-run work that baton itself deliberately stopped. The handoff
            # that follows opens its own unit with its own receipts.
            runs_record_complete "$unit" "rotated-$class"
            NIGHT_RESULT=ROTATE
            NIGHT_CLASS="$class"
            NIGHT_TEXT="$line"
            NIGHT_SESSION_ID=$(basename "$f" .jsonl)
            return 0
          fi
        done < <(tail -c "+$((offset + 1))" "$f")
      fi
      # A file that SHRANK records its new (smaller) size, so the next poll
      # reads from where the file now ends rather than past it.
      cursors=$(cursor_set "$cursors" "$f" "$size")
    done <<EOF
$(touched_since "$ref" "$tdir")
EOF
  done

  rm -f "$ref" "$snap"
  wait "$pid"
  local code=$?
  # The completion receipt is written from the code wait() actually returned,
  # before anything else can fail. It is the only evidence that closes a unit,
  # so it is never written from an assumption about how the child ended.
  runs_record_complete "$unit" "$code"
  probe "$name"
  case "$PROBE_CLASS" in
    LIMIT|AUTH)
      NIGHT_RESULT=ROTATE
      NIGHT_CLASS="$PROBE_CLASS"
      NIGHT_TEXT="$PROBE_OUT"
      NIGHT_SESSION_ID=""
      ;;
    *)
      NIGHT_RESULT=EXITED
      NIGHT_EXIT_CODE="$code"
      ;;
  esac
}

# night_mode ARGS... -- the --night CLI entry point: pick a starting account
# the same way plain baton does (D1), run it under run_watched, and on
# ROTATE keep handing off (marking the losing account dead, announcing the
# handoff, carrying forward --resume/-c) until either the child exits on its
# own, every account is exhausted, or BATON_MAX_HANDOFFS is hit.
night_mode() {
  local handoffs=0 resume_mode="" acct prev max_handoffs
  night_knobs
  max_handoffs="$NIGHT_MAX_HANDOFFS"

  pick_live probe || die_no_live_account
  acct="$PICKED"

  while true; do
    bump "$acct"
    warn "launching as account '$acct' (night mode)"
    handoff_log "launching as account '$acct' (night mode)${resume_mode:+, $resume_mode}"
    run_watched "$acct" "$resume_mode" "$@"

    case "$NIGHT_RESULT" in
      EXITED)
        exit "$NIGHT_EXIT_CODE"
        ;;
      ROTATE)
        mark_dead_for_class "$acct" "$NIGHT_CLASS" "$NIGHT_TEXT"
        # Exhaustion is decided BEFORE the cap, or the last account of the
        # night reports the wrong cause: with two accounts and a cap of 1,
        # both hitting their limit, the run really ended because there was
        # nobody left, and "handoff cap (1) reached; raise it with
        # BATON_MAX_HANDOFFS" sends the operator to raise a cap that would
        # change nothing. candidates_exist() answers from dead marks only --
        # it never probes, so the account the cap is about to refuse stays
        # untouched (failover.feature's cap scenario).
        candidates_exist || die_no_live_account
        if [ $((handoffs + 1)) -gt "$max_handoffs" ]; then
          die "handoff cap ($max_handoffs) reached; raise it with BATON_MAX_HANDOFFS"
        fi
        pick_live probe || die_no_live_account
        prev="$acct"
        acct="$PICKED"
        handoffs=$((handoffs + 1))
        warn "handoff: account '$prev' is unavailable ($NIGHT_CLASS); switching to account '$acct'"
        if [ -n "$NIGHT_SESSION_ID" ]; then
          resume_mode="resume:$NIGHT_SESSION_ID"
        else
          resume_mode="continue"
        fi
        # The morning record. It names the session id, which makes it the one
        # place holding a command the operator could actually re-run by hand
        # -- which is exactly why it is written here and not printed.
        handoff_log "handoff: '$prev' unavailable ($NIGHT_CLASS); resuming under '$acct' with ${NIGHT_SESSION_ID:+--resume $NIGHT_SESSION_ID}${NIGHT_SESSION_ID:--c}"
        ;;
    esac
  done
}
