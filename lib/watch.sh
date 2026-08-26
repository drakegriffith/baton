#!/usr/bin/env bash
# watch -- child-process control for `baton --night`. Depends on detect
# (classify_text, for both the live-transcript and post-exit-probe paths)
# and on accounts' public surface only (pick_live/candidates_exist,
# mark_dead_for_class, probe, set_envargs, bump, die_no_live_account,
# die_night_stopped, handoff_log, is_uint/is_unum) -- never on accounts'
# private state files directly, and never a second copy of the LIMIT/AUTH
# regex family.
#
# Output rule (issue #2): run_watched backgrounds `claude` WITHOUT
# redirecting it, so the child inherits this process's stdout and stderr --
# the watcher and a full-screen TUI share one terminal for the whole night.
# Anything printed here is therefore printed into a terminal a human is
# using. Nothing in this file may write a runnable command to a stream; the
# durable record goes through accounts.sh's handoff_log(). That includes the
# final stop after a killed child: die_night_stopped puts the resume line in
# the log and names the log path on stderr.
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

  # What the log will call this launch. Computed BEFORE the fork, because the
  # two refusals below have to name it and neither of them will have a child.
  local what
  case "$resume_mode" in
    resume:*) what="resumed session ${resume_mode#resume:} under account '$name'" ;;
    continue) what="continued the last session under account '$name'" ;;
    *)        what="account '$name'" ;;
  esac

  # POSITIVE CONTROL ON THE PROCESS TABLE, before anything is forked.
  #
  # Everything this function does after the fork depends on `ps` being able to
  # answer questions: the start-up liveness check, the fingerprint on the
  # receipt, the pid-reuse guard that reads it back. A `ps` that is denied,
  # missing, or broken answers a question about a live child exactly like a
  # `ps` reporting an absent one -- empty output, nonzero exit -- so the
  # watcher concluded "gone", fell through to a blocking wait, and watched no
  # transcripts for the rest of the night. The limit line that triggers a
  # handoff would never be seen and the run would look like a clean session.
  #
  # lib/runs.sh has carried the control since baton#3: pid 1 exists on every
  # machine this runs on, so a `ps` that cannot describe it is not answering
  # questions at all. The watcher simply never called it.
  #
  # Exit 2, not die's 1, and before the fork rather than after: a watcher that
  # cannot watch must not start a child it would immediately lose track of.
  # "Could not inspect" is not a failure of the run, it is a refusal to guess.
  _runs_ps_usable || {
    echo "baton: watch-result=could-not-inspect reason=process-table-unreadable -- ps cannot describe pid 1, so a child could not be watched or even confirmed to exist. Nothing was launched. This exit 2 belongs to the watcher, not to a child." >&2
    exit 2
  }

  # PREFLIGHT THE EXECUTABLE, before the fork, because after a successful exec
  # the question is unanswerable.
  #
  # The previous round asked it afterwards, from the child's exit code: 126 or
  # 127 meant "the exec failed". That premise is false, and this repo's own
  # fixture is the counterexample -- tests/fixtures/bin/claude runs perfectly
  # well and returns 127 because a behavior file told it to, and a real CLI
  # may do the same. An exit code is application status. It cannot say whether
  # the application ever started.
  #
  # Before the fork it is a plain question with a plain answer: does the name
  # resolve on PATH, and is what it resolves to executable. `command -v`
  # already requires executability, and the explicit -x is kept for the window
  # between resolving and forking. ENVARGS only ever sets or unsets
  # CLAUDE_CONFIG_DIR, never PATH, so the parent resolves the same binary the
  # child would.
  #
  # The resolved path is then USED, not re-resolved. The exec line used to run
  # the bare name again, which made preflight and launch two separate lookups
  # of the same word at two different moments -- a PATH edit, a chmod, or a
  # replaced file between them passes the check and fails the exec, after the
  # fork, where the exit code can no longer answer the question (see below).
  # One resolution, used twice. `-f` rejects a directory outright; measured
  # note, `command -v` already skips directories on this bash, so -f is the
  # belt for a path that becomes one between the lookup and the fork.
  local claude_bin
  claude_bin=$(command -v claude 2>/dev/null)
  if [ -z "$claude_bin" ] || [ ! -f "$claude_bin" ] || [ ! -x "$claude_bin" ]; then
    handoff_log "LAUNCH FAILED: $what -- the claude executable does not resolve on PATH, so no child was started and no unit was opened"
    die "cannot launch '$name': no executable file 'claude' on PATH"
  fi

  if [ "${#resume_args[@]}" -gt 0 ]; then
    "${ENVARGS[@]}" "$claude_bin" "${resume_args[@]}" "$@" &
  else
    "${ENVARGS[@]}" "$claude_bin" "$@" &
  fi
  local pid=$!

  # Durable receipts (baton#3). Written the instant the pid exists, because
  # that is the only moment anything knows it: if this process dies here, the
  # child is reparented to launchd and keeps running, and the receipt is then
  # the ONLY evidence distinguishing that live orphan from a unit that never
  # started. The two mktemp files above are still scratch and still deleted;
  # these are not.
  local unit="night-$(date -u +%Y%m%dT%H%M%SZ)-$$-$name"
  local receipt_ok=1
  runs_record_start "$unit" "$pid" "$(runs_fingerprint "$pid")" "$claude_bin ${resume_args[*]-} $*" \
    || receipt_ok=0

  local interval="$NIGHT_INTERVAL"
  local cursors="" f size offset class line

  # Did the child actually START? `cmd &` hands back a pid whatever happens
  # next: if the exec fails -- binary missing, or present and not executable
  # -- the child exits 126/127 immediately and nothing ever ran, but the fork
  # already succeeded and the pid already exists. Writing LAUNCHED off the
  # back of that records that BASH MANAGED TO FORK, which is not the claim
  # the line makes.
  #
  # So the child is given one watch tick to still be there. `ps -o state=`
  # rather than `kill -0`, because a child that has exited but not yet been
  # reaped is a ZOMBIE and kill -0 SUCCEEDS on a zombie -- the exact case
  # being tested for would read as alive.
  #
  # The status is captured here rather than re-waited later: `wait` on an
  # already-reaped pid returns 127, which would overwrite a child's real exit
  # code with a fake one on its way to NIGHT_EXIT_CODE.
  sleep "$interval"
  local launch_code="" state ps_rc
  state=$(ps -p "$pid" -o state= 2>/dev/null); ps_rc=$?
  state=$(printf '%s' "$state" | tr -d ' \n')
  # The control has to be about THIS SUBJECT, not about `ps` in general. A ps
  # can answer for pid 1 and refuse everything else -- a sandbox that permits
  # init, a container with a restricted /proc view, a visibility policy. The
  # pre-fork control passes, the child-specific call comes back empty, and
  # empty reads as "the child is gone": a blocking wait, and no transcript
  # watching for the rest of the night, so the limit line that triggers a
  # handoff is never seen.
  #
  # `kill -0` is the second opinion, and it is a good one here precisely
  # because this process FORKED that pid -- it is a signal-permission question
  # answered by the kernel, not another read of the same table. When the two
  # disagree -- ps says nothing, kill -0 says the pid is there -- that is
  # could-not-inspect. It is never "dead".
  if { [ "$ps_rc" -ne 0 ] || [ -z "$state" ]; } && kill -0 "$pid" 2>/dev/null; then
    echo "baton: watch-result=could-not-inspect reason=child-liveness-unreadable -- ps gave no answer for the child just started, but the pid is still signalable, so its liveness cannot be established and its transcript cannot be watched. The child is still running and unit $unit records it. This exit 2 belongs to the watcher, not to a child." >&2
    exit 2
  fi
  case "$state" in
    ''|Z*) wait "$pid" 2>/dev/null; launch_code=$? ;;
  esac

  # The handoff log's launch record is written HERE and only here: the first
  # point where the session lock is held (or was never needed), the receipt
  # lib/runs.sh reads back at restart is on disk, and a child has actually
  # been observed.
  #
  # It used to be written by night_mode BEFORE calling this function, which
  # put it before the lock claim above. A refused resume dies up there, so the
  # log was left asserting a launch that never happened -- in the one durable
  # record of the night, read hours later by someone who cannot see the
  # terminal, and in the file that makes a refusal (the guard WORKING)
  # indistinguishable from a child that started and vanished. night_mode still
  # logs what it is about to try; the difference is a tense.
  if [ "$receipt_ok" -eq 0 ]; then
    # No receipt means no durable evidence this child exists, so there is
    # nothing to point a restart at and no launch to claim. Same rule as the
    # lock: the record follows the evidence, never the intention.
    handoff_log "LAUNCH FAILED: $what -- the launch receipt for unit $unit could not be written, so nothing durable records this child"
    warn "the launch receipt for '$name' could not be written; see $HANDOFF_LOG"
  elif [ -n "$launch_code" ]; then
    # It exec'd and has already finished: a headless child that did its work,
    # one that hit its limit on the first call, or one that failed on its own
    # terms. All three ARE launches. The exit code is recorded as what it is
    # -- application status -- and never re-read as evidence about whether the
    # program started, which is the mistake the preflight above now prevents
    # from ever needing to be made.
    handoff_log "LAUNCHED: $what as unit $unit (pid $pid); already exited $launch_code before the first watch tick"
  else
    handoff_log "LAUNCHED: $what as unit $unit (pid $pid)"
  fi

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
  # A child reaped by the start-up liveness check above must NOT be waited on
  # again: `wait` on an already-reaped pid answers 127, and that fake code
  # would flow straight into runs_record_complete and NIGHT_EXIT_CODE, so a
  # clean headless exit would read as "command not found".
  local code
  if [ -n "$launch_code" ]; then
    code="$launch_code"
  else
    wait "$pid"
    code=$?
  fi
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
  local handoffs=0 resume_mode="" resume_hint="" acct prev max_handoffs
  night_knobs
  max_handoffs="$NIGHT_MAX_HANDOFFS"

  pick_live probe || die_no_live_account "" ""
  acct="$PICKED"

  while true; do
    bump "$acct"
    warn "launching as account '$acct' (night mode)"
    # ATTEMPT, not "launching": run_watched can still refuse below (the
    # single-writer guard) and die without ever reaching the CLI. The
    # matching LAUNCHED line is appended by run_watched once the lock is held
    # and the receipt exists.
    handoff_log "ATTEMPT: launch as account '$acct' (night mode)${resume_mode:+, $resume_mode}"
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
        candidates_exist || die_no_live_account "$acct" "$NIGHT_SESSION_ID"
        if [ $((handoffs + 1)) -gt "$max_handoffs" ]; then
          die_night_stopped \
            "handoff cap ($max_handoffs) reached; raise it with BATON_MAX_HANDOFFS" \
            "$acct" "$NIGHT_SESSION_ID"
        fi
        pick_live probe || die_no_live_account "$acct" "$NIGHT_SESSION_ID"
        prev="$acct"
        acct="$PICKED"
        handoffs=$((handoffs + 1))
        warn "handoff: account '$prev' is unavailable ($NIGHT_CLASS); switching to account '$acct'"
        # One branch decides BOTH what run_watched is told to do and what the
        # log says it will do, so the two cannot disagree. They used to be
        # written twice: this if/else for resume_mode, and a separate
        # ${NIGHT_SESSION_ID:+--resume $NIGHT_SESSION_ID}${NIGHT_SESSION_ID:--c}
        # inside the log line. That second spelling was wrong. `:-` falls back
        # to its word only when the variable is unset OR EMPTY, and otherwise
        # substitutes THE VALUE -- so a set session id was emitted twice and
        # the log read "--resume sess-a-01sess-a-01". The empty case (`-c`)
        # was correct, which is why nothing caught it: the branch that worked
        # is the branch that ran in most scenarios.
        #
        # It matters because this is the ONE line an operator copies out of a
        # morning log to recover a session by hand, and it named a session id
        # that does not exist.
        if [ -n "$NIGHT_SESSION_ID" ]; then
          resume_mode="resume:$NIGHT_SESSION_ID"
          resume_hint="--resume $NIGHT_SESSION_ID"
        else
          resume_mode="continue"
          resume_hint="-c"
        fi
        # The morning record. It names the session id, which makes it the one
        # place holding a command the operator could actually re-run by hand
        # -- which is exactly why it is written here and not printed.
        #
        # Stated as an ATTEMPT for the same reason as the launch line above:
        # the resume this describes is the one that takes the session lock,
        # so it is precisely the case that can be refused. The loop's next
        # iteration calls run_watched, and run_watched appends LAUNCHED only
        # if the resume actually happened.
        handoff_log "ATTEMPT: handoff -- '$prev' unavailable ($NIGHT_CLASS); will resume under '$acct' with $resume_hint"
        ;;
    esac
  done
}
