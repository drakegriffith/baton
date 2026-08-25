#!/usr/bin/env bash
# lock -- the single-writer guard. Depends on accounts (for $ROOT) and on
# baton's die/warn/now, and on NOTHING else; nothing in detect, accounts or
# watch calls back into here, so the dependency edge only ever points one way.
#
# WHY THIS EXISTS (issue #2, 2026-08-25). Every baton account symlinks
# projects/ back into ~/.claude, which is the whole point -- it is what lets
# account b resume a session account a started. The cost of that design is
# that a session id is a name every account can open, and nothing was stopping
# two processes from opening the same one. On 2026-08-25 two relaunch command
# lines landed in one terminal, both were run, one claude absorbed the session
# and the other died.
#
# The `claude` CLI does not close this itself. Measured on 2.1.245: it holds
# a lock on git worktrees ("belongs to another running Claude Code session"),
# one on OAuth refresh (.oauth_refresh.lock, next to the credentials store),
# one on scheduled_tasks, and one serializing appends to its storage stream --
# and none of them refuse a second `--resume <id>`. There is not a single
# .lock file anywhere under a projects/ tree holding 5000+ transcripts. The
# OAuth one is the near miss: it is scoped to ONE credentials store, so two
# CLAUDE_CONFIG_DIRs logged into the same Anthropic account take two different
# locks and rotate each other's refresh token anyway -- which is why the login
# flow is serialized here too (issue #2 root cause 3).
#
# MECHANISM. `mkdir` is the arbiter: it is atomic and it fails for the loser,
# on every filesystem this runs on, with no flock(1) on stock macOS and no
# bash-3.2 noclobber games. Everything else (the owner record, the liveness
# check, the reclaim) hangs off that one atomic step. Deliberately NOT chosen:
# a plain `[ -f lock ] || echo $$ > lock` test-then-write, which two processes
# scheduled a microsecond apart both pass -- it is the exact bug being fixed,
# written one level down.
#
# EXIT CODES, and why there are three answers rather than two:
#   0  acquired / inspected at least one lock subject
#   1  inspected successfully and found ZERO lock subjects
#   3  refused: a live process holds the lock (its pid is named)
#   2  COULD NOT INSPECT: the lock root is missing or unreadable
# 2 is never a pass and never means "no lock is held". A check that opened
# nothing has not cleared anything, and collapsing "I found no locks" into "I
# could not look" is how a guard reports success on a run where it never
# executed. So `--locks` on an empty-but-readable root exits 1, not 0: it
# found nothing, and "found nothing" is an answer that has to be asked for.

LOCKROOT="$ROOT/.locks"

# How long a lock directory with no readable owner record is treated as being
# established by a racer that has not written its record yet, rather than as
# debris. Between another process's mkdir and its owner write there is a
# window in which the lock is real but anonymous; reclaiming inside that
# window would hand the same session to two processes, which is the bug.
# Outside it, an ownerless lock is a process that died in that window.
LOCK_GRACE_SECS="${BATON_LOCK_GRACE_SECS:-30}"

# is_lock_subject -- a subject becomes a path component under $LOCKROOT, so it
# is validated the same way is_account validates an account name, and for the
# same reason: session ids arrive from operator argv and from a transcript
# basename, and `../../a` must never reach mkdir or rm -rf.
is_lock_subject() {
  case "${1:-}" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# proc_start PID -> a stable witness of WHICH process that pid currently is,
# or empty if no such process exists. Pids are recycled (macOS wraps at
# 99998), so "the pid is alive" alone would let an unrelated new process
# inherit a dead session's lock and wedge baton until someone deleted the
# directory by hand. The start time distinguishes them: a recycled pid
# belongs to a process that started later than the one that wrote the record.
proc_start() {
  ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# lock_probe SUBJECT -> LOCK_STATE (free|pending|live|stale) and LOCK_PID.
# Never mutates anything: the reporter and the acquirer share one reading of
# what a lock directory means, so `--locks` cannot say "stale" about a lock
# the acquirer would refuse.
lock_probe() {
  local d="$LOCKROOT/$1" owner pid start mt age
  LOCK_PID=""
  LOCK_SINCE=""
  if [ ! -d "$d" ]; then LOCK_STATE=free; return 0; fi
  owner="$d/owner"
  if [ ! -s "$owner" ] || [ ! -r "$owner" ]; then
    mt=$(stat -f %m "$d" 2>/dev/null) || { LOCK_STATE=pending; return 0; }
    age=$(( $(now) - mt ))
    if [ "$age" -lt "$LOCK_GRACE_SECS" ]; then LOCK_STATE=pending; else LOCK_STATE=stale; fi
    return 0
  fi
  pid=$(awk '$1=="pid"{print $2; exit}' "$owner" 2>/dev/null)
  start=$(awk '$1=="start"{sub(/^[ \t]*start[ \t]+/, "", $0); print $0; exit}' "$owner" 2>/dev/null)
  LOCK_PID="$pid"
  LOCK_SINCE=$(awk '$1=="since"{print $2; exit}' "$owner" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) LOCK_STATE=stale; return 0 ;; esac
  if [ "$(proc_start "$pid")" = "$start" ] && [ -n "$start" ]; then
    LOCK_STATE=live
  else
    LOCK_STATE=stale
  fi
}

# lock_acquire SUBJECT WHAT -- 0 on success, 3 when a live (or still-being-
# established) holder has it, 2 when the lock root itself cannot be used.
#
# The reclaim of a stale lock goes through `mv` rather than a bare `rm -rf`
# on purpose. Two processes can both decide the same lock is stale; if both
# then rm -rf and mkdir, both believe they hold it -- the race, reintroduced
# inside the fix for the race. A rename can only succeed for ONE of them (the
# loser's source is already gone), so destruction is single-shot, and both
# then fall back to the same mkdir arbiter that decides everything else.
lock_acquire() {
  local subject="$1" what="${2:-}" d tries=0 trash
  is_lock_subject "$subject" || return 2
  mkdir -p "$LOCKROOT" 2>/dev/null || return 2
  [ -w "$LOCKROOT" ] && [ -x "$LOCKROOT" ] || return 2
  d="$LOCKROOT/$subject"
  while [ "$tries" -lt 20 ]; do
    tries=$((tries + 1))
    if mkdir "$d" 2>/dev/null; then
      {
        printf 'pid %s\n' "$$"
        printf 'start %s\n' "$(proc_start $$)"
        printf 'what %s\n' "$what"
        printf 'since %s\n' "$(now)"
      } > "$d/owner" 2>/dev/null || { rm -rf "$d"; return 2; }
      return 0
    fi
    lock_probe "$subject"
    case "$LOCK_STATE" in
      live) return 3 ;;
      pending)
        # The winner's mkdir has landed but its owner record has not yet.
        # Refusing THIS instant would refuse without naming a pid, and naming
        # the pid is the one thing the refusal exists to say -- "someone has
        # it, I don't know who" sends the operator nowhere. Measured against a
        # real racer (qa_failover block 15, two launches fired back to back):
        # this window is hit often enough to fail that assertion outright, so
        # it is waited out rather than reported. The window is a few file
        # writes wide; the budget here is ~2s, thousands of times that.
        sleep 0.1
        ;;
      stale)
        trash="$LOCKROOT/.reclaimed.$$.$tries"
        mv "$d" "$trash" 2>/dev/null && rm -rf "$trash"
        ;;
    esac
  done
  return 3
}

# lock_release SUBJECT -- give up a lock this process actually owns. A
# process that does not own it returns quietly rather than deleting it: the
# only thing worse than a stale lock is a released one that someone else is
# standing behind.
lock_release() {
  local subject="${1:-}" d pid
  [ -n "$subject" ] || return 0
  is_lock_subject "$subject" || return 0
  d="$LOCKROOT/$subject"
  [ -d "$d" ] || return 0
  pid=$(awk '$1=="pid"{print $2; exit}' "$d/owner" 2>/dev/null)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$d"
}

# lock_take SUBJECT WHAT -- acquire or EXIT. Every launch guard calls this
# rather than lock_acquire, so no call site can acquire, ignore the answer and
# launch anyway; the one place that phrases the refusal is here, which is also
# why the guard added to watch.sh is a single line and adds no output site of
# its own.
lock_take() {
  local subject="$1" what="${2:-}" rc
  lock_acquire "$subject" "$what"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 2 ]; then
    echo "baton: could not inspect or write the lock root $LOCKROOT -- refusing to launch. This is could-not-inspect, not 'no lock is held'." >&2
    exit 2
  fi
  if [ "$LOCK_STATE" = pending ]; then
    echo "baton: refusing to launch '$subject': another baton took that lock in the last ${LOCK_GRACE_SECS}s and has not recorded its pid yet. Try again in a moment, or run: baton --locks" >&2
  else
    echo "baton: refusing to launch '$subject': it is already held by pid $LOCK_PID, which is still running. Two processes on one session is what destroys it -- go back to pid $LOCK_PID, or wait for it to exit. See: baton --locks" >&2
  fi
  exit 3
}

# lock_subject_for_argv ARGS... -- the lock subject a claude argv implies, or
# nothing. Only an EXPLICIT `--resume <id>` / `--resume=<id>` is keyable: a
# cold start and `-c` have no session id at the moment of launch (the id only
# becomes knowable once a transcript grows), so they are deliberately
# unguarded rather than guarded by a guessed key. The incident was two
# `--resume <id>` launches; this is the shape that is coverable today.
lock_subject_for_argv() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "--resume" ]; then printf 'session-%s' "$a"; return 0; fi
    case "$a" in
      --resume=*) printf 'session-%s' "${a#--resume=}"; return 0 ;;
    esac
    prev="$a"
  done
  return 1
}

# lock_guard_launch ARGS... -- the guard baton's interactive dispatch calls
# just before handing ARGS to claude. baton `exec`s, so the pid recorded here
# BECOMES the claude process (scenario 11 pins that exec, not fork) and the
# lock stays live for exactly as long as the session does, with no trap to
# miss and no release to forget.
lock_guard_launch() {
  local subject
  subject=$(lock_subject_for_argv "$@") || return 0
  [ -n "$subject" ] || return 0
  if ! is_lock_subject "$subject"; then
    warn "the session id after --resume has a shape baton cannot use as a lock key; launching WITHOUT a single-writer lock"
    return 0
  fi
  lock_take "$subject" "$* (in $PWD)"
}

# lock_report -- the `--locks` check. Read-only: a reporter that reclaims what
# it reports cannot be trusted about what was there before it looked.
lock_report() {
  local d subject n=0
  if [ ! -d "$LOCKROOT" ] || [ ! -r "$LOCKROOT" ] || [ ! -x "$LOCKROOT" ]; then
    echo "baton: cannot inspect the lock root $LOCKROOT (missing or unreadable). COULD-NOT-INSPECT -- this is not a report that no lock is held." >&2
    return 2
  fi
  printf "%-44s %-8s %-8s %s\n" SUBJECT STATE PID HELD-BY
  for d in "$LOCKROOT"/*/; do
    [ -d "$d" ] || continue
    subject=$(basename "$d")
    lock_probe "$subject"
    printf "%-44s %-8s %-8s %s\n" "$subject" "$LOCK_STATE" "${LOCK_PID:--}" \
      "$(awk '$1=="what"{sub(/^[ \t]*what[ \t]*/, "", $0); print $0; exit}' "$d/owner" 2>/dev/null)"
    n=$((n + 1))
  done
  echo "baton: inspected $n lock subject(s) under $LOCKROOT"
  [ "$n" -gt 0 ] || return 1
  return 0
}
