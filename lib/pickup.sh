#!/usr/bin/env bash
# pickup -- what survived the last session, and what may be re-dispatched.
#
# Dependency direction (QA-DOC section 4): this file depends on NOTHING, the
# same rule lib/detect.sh lives under. It touches no account, no process, no
# file. That is what lets the same classifier be called by the live watcher
# and by a restart hours later without the two drifting apart -- the lesson
# detect.sh already encodes for LIMIT/AUTH.
#
# THE RULE THIS FILE EXISTS TO ENFORCE: ambiguity never resolves to success.
# A unit is `done` only on a completion receipt written by the launcher that
# owned the child. Everything a caller merely FAILED to observe is `unknown`,
# which is a could-not-inspect verdict, not a pass and not a death. Silence
# is not evidence; a classifier that inspected nothing found nothing, and it
# must say so rather than report a clean board.

# pickup_classify START COMPLETE ALIVE -- three evidence tokens in, one
# bucket out, nothing else consulted.
#
#   START     yes|no       a start receipt exists for this unit
#   COMPLETE  yes|no       a completion receipt exists for this unit
#   ALIVE     yes|no|unknown
#                          yes     = a live process matches BOTH the recorded
#                                    pid and the recorded fingerprint
#                          no      = confirmed gone
#                          unknown = liveness could not be determined
#
# Buckets:
#   done           finished; its exit code is on disk, consume it
#   dead-partial   started, never finished, process confirmed gone; partial
#                  output may be salvageable
#   orphan-running still running, reparented; adopt it, NEVER re-dispatch
#   never-started  nothing ever ran; re-dispatch is safe
#   unknown        evidence is missing or contradictory; hold for a human
pickup_classify() {
  local start="${1-}" complete="${2-}" alive="${3-}"

  case "$start" in yes|no) ;; *) printf 'unknown\n'; return 0 ;; esac
  case "$complete" in yes|no) ;; *) printf 'unknown\n'; return 0 ;; esac
  case "$alive" in yes|no|unknown) ;; *) printf 'unknown\n'; return 0 ;; esac

  # A completion receipt closes the unit whatever the process looks like now:
  # a child that wrote its exit code and then vanished is done, and a pid
  # that has since been REUSED by a stranger must not reopen it.
  if [ "$complete" = yes ]; then
    # ...but only if the unit also started. A completion with no start is
    # evidence that contradicts itself: something wrote a receipt it had no
    # business writing, or a start receipt was lost. Reading that as `done`
    # would let corrupt evidence close a unit, so it fails closed.
    [ "$start" = yes ] && printf 'done\n' || printf 'unknown\n'
    return 0
  fi

  if [ "$start" = yes ]; then
    case "$alive" in
      yes) printf 'orphan-running\n' ;;
      no)  printf 'dead-partial\n' ;;
      *)   printf 'unknown\n' ;;
    esac
    return 0
  fi

  # No start receipt. Only a CONFIRMED-gone process makes "nothing ran" safe
  # to assert: a matching live process with no start receipt is contradictory
  # evidence, and re-dispatching on it would double-run the work.
  [ "$alive" = no ] && printf 'never-started\n' || printf 'unknown\n'
}
