#!/usr/bin/env bash
# watch -- child-process control for `baton --night`. Depends on detect
# (classify_text, for both the live-transcript and post-exit-probe paths)
# and on accounts' public surface only (ranked/pick_live, mark_dead_for_class,
# probe, set_envargs, bump, die_no_live_account, is_uint/is_unum) -- never on accounts'
# private state files directly, and never a second copy of the LIMIT/AUTH
# regex family.
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

# find_new_jsonl DIR BEFORE_LISTING -> path of a *.jsonl file in DIR whose
# basename is not in BEFORE_LISTING (newline-separated), or empty. Used for
# --resume session-id discovery (D6): the transcript that "starts existing
# after child launch" is the one baton continues.
find_new_jsonl() {
  local dir="$1" before="$2" f b
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.jsonl; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    printf '%s\n' "$before" | grep -qxF "$b" || { echo "$f"; return 0; }
  done
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
#   NIGHT_SESSION_ID  (ROTATE only) discovered session id, or "" (means: use
#                     -c on the next launch, never invent an id -- D6). Only
#                     ever non-empty when the kill came from a live
#                     transcript match; a post-exit-probe rotation has
#                     nothing to resume (D5: that account's own session is
#                     over, not paused).
run_watched() {
  local name="$1" resume_mode="$2"; shift 2
  set_envargs "$name"
  local tdir; tdir=$(transcript_dir_for "$CONFIG_DIR")
  local before_files; before_files=$(mkdir -p "$tdir" && ls "$tdir" 2>/dev/null)

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

  local interval="$NIGHT_INTERVAL"
  local wait_secs="$NIGHT_WAIT_SECS"
  local newfile="" offset=0 elapsed=0 gave_up_looking=0

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$interval"

    if [ -z "$newfile" ] && [ "$gave_up_looking" -eq 0 ]; then
      newfile=$(find_new_jsonl "$tdir" "$before_files")
      if [ -z "$newfile" ]; then
        elapsed=$(awk -v e="$elapsed" -v i="$interval" 'BEGIN{printf "%.3f", e+i}')
        awk -v e="$elapsed" -v w="$wait_secs" 'BEGIN{exit !(e>=w)}' && gave_up_looking=1
      fi
    fi

    [ -n "$newfile" ] && [ -f "$newfile" ] || continue

    local size; size=$(wc -c < "$newfile" | tr -d ' ')
    [ "$size" -gt "$offset" ] || continue
    local class line
    while IFS= read -r line; do
      class=$(classify_text "$line")
      if [ "$class" = LIMIT ] || [ "$class" = AUTH ]; then
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        NIGHT_RESULT=ROTATE
        NIGHT_CLASS="$class"
        NIGHT_TEXT="$line"
        NIGHT_SESSION_ID=$(basename "$newfile" .jsonl)
        return 0
      fi
    done < <(tail -c "+$((offset + 1))" "$newfile")
    offset="$size"
  done

  wait "$pid"
  local code=$?
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
    run_watched "$acct" "$resume_mode" "$@"

    case "$NIGHT_RESULT" in
      EXITED)
        exit "$NIGHT_EXIT_CODE"
        ;;
      ROTATE)
        mark_dead_for_class "$acct" "$NIGHT_CLASS" "$NIGHT_TEXT"
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
        ;;
    esac
  done
}
