#!/usr/bin/env bash
# Unit tests for lib/pickup.sh's pure classifier -- the second file in the
# codebase safe to source directly, for the same reason lib/detect.sh is
# (pure function, no set -u/ROOT dependency, no side effects). Everything
# else in tests/ drives the real `baton` subprocess per QA-DOC section 1.
#
# pickup_classify is deliberately a string -> string function of THREE tokens
# and nothing else, so the same call can be made from the live watcher and
# from a restart hours later and cannot drift between them (the lesson
# lib/detect.sh already encodes: one classifier, two callers).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/pickup.sh"
. "$HERE/../fixtures/lib.sh"

check_bucket() { # $1 name, $2 start, $3 complete, $4 alive, $5 expected bucket
  local got
  got="$(pickup_classify "$2" "$3" "$4")"
  if [ "$got" = "$5" ]; then
    record_pass "unit:pickup_classify:$1"
  else
    record_fail "unit:pickup_classify:$1" "expected $5 got $got for start=$2 complete=$3 alive=$4"
  fi
}

#            name                    start complete alive     expected
# A completion receipt is the only evidence that closes a unit, and it closes
# it whatever the process now looks like: a pid that died AFTER writing its
# exit code is done, not dead-partial.
check_bucket "completed-pid-gone"     yes   yes      no        done
check_bucket "completed-pid-reused"   yes   yes      yes       done

# Started, no completion receipt, process confirmed gone: the turn died
# somewhere between launch and exit. Partial output may be on disk; that is
# a salvage question for the projection, not a second bucket.
check_bucket "started-then-died"      yes   no       no        dead-partial

# Started, no completion receipt, process confirmed still alive under a
# matching fingerprint: an orphan reparented to launchd, still working. Never
# re-dispatch this one.
check_bucket "started-still-running"  yes   no       yes       orphan-running

# A dispatch was recorded but the launcher never got as far as a start
# receipt. Nothing ran, so re-dispatch is safe.
check_bucket "never-launched"         no    no       no        never-started

# ---- fail-closed rows: ambiguity NEVER resolves to success ----------------
# (the rule reconcile.py litigated at mechanisms/lifecycle-reconciler:285 --
# absent success is SUSPECT, never a confirmed death, and never a pass)

# Liveness could not be determined at all (no ps, a permissions failure, a
# host that cannot answer). This is the exit-code-2 case: could-not-inspect
# is not a pass and not a death.
check_bucket "started-liveness-unknown"  yes no    unknown   unknown
check_bucket "nostart-liveness-unknown"  no  no    unknown   unknown

# A completion receipt with no start receipt is INCONSISTENT evidence, not a
# completion. A unit cannot finish without starting, so something wrote a
# receipt it had no business writing, or a start receipt was lost. Either way
# the honest answer is unknown -- reading it as done would let corrupt
# evidence close a unit.
check_bucket "complete-without-start"    no  yes   no        unknown
check_bucket "complete-without-start-live" no yes  yes       unknown

# Garbage in any position is unknown, never a silent default to one of the
# real buckets. An empty token is the shape a missing field arrives in when
# a receipt is truncated mid-write.
check_bucket "empty-start"               ""  no    no        unknown
check_bucket "empty-complete"            yes ""    no        unknown
check_bucket "empty-alive"               yes no    ""        unknown
check_bucket "garbage-token"             yes no    probably  unknown

# A never-started unit whose process somehow reports alive is contradictory
# evidence (no start receipt, yet something matching is running). Fail closed.
check_bucket "nostart-but-alive"         no  no    yes       unknown
