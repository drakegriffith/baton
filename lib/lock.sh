#!/usr/bin/env bash
# lock -- ONE lock root, many subjects. The single-writer guard for anything
# that must not happen twice at once: a session being resumed, a run unit
# being re-dispatched after a restart, a login flow rotating an account's
# OAuth token.
#
# WHY ONE ROOT AND NOT TWO MECHANISMS (baton#2 root causes 1 and 4)
#   A per-session lockfile and a per-unit claim want the same three things:
#   an owner record carrying enough identity to survive a reboot, a staleness
#   rule that can reclaim without a human, and a refusal that names the
#   holder. Built separately they would drift -- two staleness rules is two
#   chances to get "the owner is gone" wrong, and getting it wrong in either
#   direction is a duplicate run or a subject deadlocked forever. So the
#   subject is an ARGUMENT. The next lockable thing costs a string, not a
#   module.
#
# DEPENDENCY DIRECTION (QA-DOC section 4)
#   lock -> runs, and nothing else. It reuses runs.sh's `runs_fingerprint`,
#   `runs_alive`, its `ps -p 1` positive control and its write-then-rename,
#   rather than deriving a second copy of any of them -- the same rule that
#   keeps one LIMIT regex in detect.sh. Only `baton` and `watch.sh` may
#   depend on THIS file; `pickup` must never, because the evidence layer has
#   to keep working with no lock installed at all.
#
# THE THREE-STATE RULE
#   A subject is never simply locked or free. Every probe resolves to one of:
#     free               no owner record, or the last one is a release tombstone
#     held               a live process matches the owner record
#     stale-dead         the owner pid is CONFIRMED gone
#     stale-foreign      the owner pid is live but is a different process
#                        (pid reuse across a reboot); reclaimable, because a
#                        bare pid in a lockfile would otherwise let a stranger
#                        hold a subject forever
#     could-not-inspect  the question could not be asked
#   could-not-inspect is exit 2. It is NOT a pass and it is NOT a free lock:
#   an unreachable process table would otherwise report every live holder as
#   dead, which is precisely how the duplicate this file exists to prevent
#   gets launched.
#
# ATOMICITY, without flock (macOS has none)
#   `mkdir` is the only test-and-set the filesystem gives us for free, so the
#   gate is a directory whose NAME carries the generation being replaced:
#   `<subject>.lock/g-<token>`, where <token> is read out of the owner record
#   currently on disk (or `none` when there is no owner). Two processes that
#   both see the same stale owner compute the same gate name and exactly one
#   `mkdir` wins; the loser re-probes, now finds a live holder, and refuses.
#   A process arriving later reads a NEWER token, so it never races for an
#   already-decided generation. Gate directories are never pruned: pruning
#   one would hand a racer that is still holding the old token a second
#   chance to win a generation that has already been decided.
#
#   The owner record itself is written temp-then-rename (runs.sh's
#   `_runs_write`), so a reader never sees a half-written owner.
#
# ESCAPE HATCH, AND WHY IT IS LOUD
#   BATON_LOCK_DISABLE=1 makes every claim succeed without inspecting. It
#   exists because a guard that can strand an operator with no way through is
#   a worse failure than the one it prevents; it is named as a KNOB in the
#   refusal message, never as a runnable command line (baton#2 root cause 2:
#   a shared stream may say what happened, never what to type).
#
#   It leaves evidence on four surfaces, because a bypass nobody can find
#   afterwards is indistinguishable from a guard that silently did not work:
#     1. a warning on stderr for EVERY bypassed claim (not once per process --
#        the var is exported, so one `export` covers a whole night);
#     2. `bypassed=yes` on every receipt written while it is set (runs.sh);
#     3. `state=bypassed` from lock_probe, so the reporter never answers
#        `free` -- the one answer an automated caller reads as safe-to-launch;
#     4. a line in `<lock root>/bypass.log`, because the environment that set
#        the var is long gone by the time anyone asks why two of something ran.
#
# COULD-NOT-INSPECT IS MARKED, NOT RECODED
#   Exit 2 from the lock layer and exit 2 from a guarded command used to be
#   indistinguishable. The lock layer's own now carries
#   `lock-result=could-not-inspect` on stderr (_lock_cni). The exit code is
#   unchanged because it is written into this issue's acceptance criteria.

# lock_dir -- where owner records live. Honors BATON_LOCK_DIR, then falls back
# under BATON_ACCOUNTS_ROOT so a test that redirects the accounts root
# redirects the locks by construction (half-isolation reads as isolation).
lock_dir() {
  printf '%s\n' "${BATON_LOCK_DIR:-${BATON_ACCOUNTS_ROOT:-$HOME/.claude-accounts}/.locks}"
}

_lock_say() { echo "baton: $*" >&2; }

# _lock_cni SUBJECT REASON -- the machine-readable marker that separates the
# lock layer's OWN could-not-inspect from a guarded command that happened to
# exit 2.
#
# Both used to be a bare exit 2 with nothing to tell them apart, so automation
# wrapping `--claim` could not distinguish "the work ran and reported failure"
# from "nothing ran because the guard could not look" -- which is the whole
# reason a third exit code exists. The fix adds a CHANNEL rather than moving
# the code: exit 2 for an unreadable lock root is written into this issue's
# acceptance criteria, and redefining a criterion to suit an implementation is
# not a fix. Automation greps stderr for `lock-result=could-not-inspect`;
# present means the lock layer refused, absent means the exit code is the
# guarded command's own.
#
# It also closes a plain silence: the sealed-root arm previously wrote zero
# bytes anywhere, so the failure was not merely ambiguous, it was invisible.
# Phrased as a statement of fact with a knob name at most, never as a command
# to paste (root cause 2: a shared stream may say what happened, never what to
# type).
_lock_cni() {
  _lock_say "lock-result=could-not-inspect subject='${1-}' reason=${2-unknown} -- nothing was claimed and nothing ran. This exit 2 belongs to the lock layer, not to a guarded command."
}

# _lock_bypassed -- is the escape hatch on right now?
_lock_bypassed() { [ "${BATON_LOCK_DISABLE:-}" = 1 ]; }

# _lock_note_bypass SUBJECT -- a durable trace, because BATON_LOCK_DISABLE is
# an exported env var: once set it persists for the shell and every child for
# an entire night, and the environment is long gone by the time anyone asks
# why two of something ran. Best-effort by construction -- the hatch exists
# for the case where the lock root itself is the problem, so failing to write
# the trace must never be able to block the bypass it is recording.
_lock_note_bypass() {
  local root; root="$(lock_dir)"
  mkdir -p "$root" 2>/dev/null || return 0
  printf '%s pid=%s subject=%s prov=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "${1-}" \
    "${BATON_LOCK_PROV:-${BATON_RUNS_PROV:-live}}" \
    >> "$root/bypass.log" 2>/dev/null || return 0
}

# _lock_root_usable ROOT -- can this lock root be inspected AT ALL?
#
# An existing root has to be a readable, searchable directory. A root that
# does NOT exist yet is only a determinate answer if it COULD exist: the
# nearest existing ancestor has to be a directory this process can enter.
#
# Without that second half the reporter and the acquirer disagreed about the
# same root. `BATON_LOCK_DIR=/dev/null/nope --lock-status` skipped the check
# entirely (the root does not exist, so the `[ -e ]` guard was false), fell
# through to `state=free inspected=1 EXIT=0`, and reported a clean board --
# while `--claim` on that identical root failed its `mkdir -p` and correctly
# answered could-not-inspect. The reporter is the one that gets asserted on.
#
# "Absent but creatable" stays determinate on purpose: a first-ever run has no
# lock root, and refusing to launch on that would be a guard that never lets
# anything start.
_lock_root_usable() {
  local p="${1-}" parent next
  [ -n "$p" ] || return 1
  if [ -e "$p" ]; then
    [ -d "$p" ] && [ -r "$p" ] && [ -x "$p" ]
    return $?
  fi
  parent="$p"
  while [ ! -e "$parent" ]; do
    next="$(dirname "$parent")"
    [ "$next" = "$parent" ] && break
    parent="$next"
  done
  [ -d "$parent" ] && [ -r "$parent" ] && [ -x "$parent" ]
}

# _lock_reset -- every output variable gets a value before any early return,
# so a caller reading LOCK_HOLDER_PID after a could-not-inspect answer gets an
# empty string rather than an unbound-variable death under `set -u`.
_lock_reset() {
  LOCK_STATE=could-not-inspect
  LOCK_HOLDER_PID=""
  LOCK_HOLDER_FP=""
  LOCK_HOLDER_BIRTH=""
  LOCK_HOLDER_PROV=""
  LOCK_CLAIMED_AT=""
  LOCK_TOKEN=none
  LOCK_RELEASED=no
  LOCK_INSPECTED=0
  LOCK_SUBJECT_KEY=""
}

# _lock_key SUBJECT -- a subject is arbitrary text (a session id from a
# transcript filename, a unit name, an account name) and it becomes a path.
# Every character outside a conservative set becomes `_`, so "../../etc" can
# name nothing outside the lock root. Returns 1 on an empty subject: mapping
# empty to a shared default would serialize every unrelated caller onto one
# lock, which is a worse bug than refusing.
_lock_key() {
  local s="${1-}" out="" c i
  [ -n "$s" ] || return 1
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9._-]) out="$out$c" ;;
      *)              out="${out}_" ;;
    esac
  done
  # A key of only dots would name `.` or `..` -- i.e. the lock root itself.
  case "$out" in .|..) out="_$out" ;; esac
  printf '%s' "${out:0:180}"
}

# The start-time half of a fingerprint lives in runs.sh as `runs_birth`, not
# here. It is the identity that survives an `exec` -- which baton's login path
# does deliberately, replacing itself with `claude` while still holding the
# lock -- and it is what `runs_alive` already uses to decide whether a live pid
# is still the recorded process. One rule, one place.

# _lock_write_owner SUBJECT PID FINGERPRINT [RELEASED] -- the owner record,
# written atomically. Every write mints a fresh token, so every ownership
# transition (claim, reclaim, release) advances the generation the next gate
# is named after. `subject` is stored in its SANITIZED form: the raw text can
# contain a newline, and a newline in a receipt is a field-injection.
_lock_write_owner() {
  local subject="${1-}" pid="${2-}" fp="${3-}" released="${4:-no}" key d nonce
  key="$(_lock_key "$subject")" || return 1
  d="$(lock_dir)/$key.lock"
  mkdir -p "$d" 2>/dev/null || return 1
  nonce="$$-$(date -u +%s)-${RANDOM}"
  _runs_write "$d/owner" \
"subject=$key
pid=$pid
birth=$(runs_birth "$fp")
fingerprint=$fp
token=$(_lock_key "$pid-$nonce")
released=$released
claimed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prov=${BATON_LOCK_PROV:-${BATON_RUNS_PROV:-live}}
"
}

# _lock_read_owner FILE -- fields back out, via runs.sh's anchored reader.
_lock_read_owner() {
  local owner="$1"
  LOCK_HOLDER_PID="$(runs_field "$owner" pid)"
  LOCK_HOLDER_FP="$(runs_field "$owner" fingerprint)"
  LOCK_HOLDER_BIRTH="$(runs_field "$owner" birth)"
  LOCK_HOLDER_PROV="$(runs_field "$owner" prov)"
  LOCK_CLAIMED_AT="$(runs_field "$owner" claimed_at)"
  LOCK_TOKEN="$(runs_field "$owner" token)"
  LOCK_RELEASED="$(runs_field "$owner" released)"
  [ -n "$LOCK_TOKEN" ] || LOCK_TOKEN=none
}

# lock_probe SUBJECT -> 0 (free or reclaimable) | 1 (held) | 2 (could not
# inspect). Sets LOCK_STATE, LOCK_HOLDER_PID, LOCK_INSPECTED and friends.
#
# LOCK_INSPECTED counts LOCK SUBJECTS WHOSE OWNER RECORD THIS PROBE ACTUALLY
# READ. It used to mean "I reached a determinate answer about the one subject
# you named" and it was reported under a name that reads as a count of things
# found, so a subject that had never been locked reported `inspected=1` and a
# caller asserting "it inspected more than zero subjects" was asserting
# nothing at all. A never-locked subject now honestly reports 0. A caller that
# wants evidence about the BOARD rather than about one name asks lock_report,
# whose count can also come back zero.
#
# lock_probe itself is a thin wrapper around _lock_probe_raw that overlays one
# fact the raw reading cannot see: whether the guard is switched OFF right
# now. Under BATON_LOCK_DISABLE=1 no claim is being arbitrated, so answering
# `free` -- the one answer an automated caller reads as "safe to launch" -- is
# the specific lie this used to tell. The overlay is applied at the seam so
# every caller (--lock-status, --locks, release) inherits it and none of them
# has to remember the knob exists.
lock_probe() {
  local rc
  _lock_probe_raw "$@"; rc=$?
  if _lock_bypassed; then
    LOCK_STATE=bypassed
    return 0
  fi
  return "$rc"
}

_lock_probe_raw() {
  local subject="${1-}" key root d owner got
  _lock_reset
  key="$(_lock_key "$subject")" || return 2
  LOCK_SUBJECT_KEY="$key"
  root="$(lock_dir)"

  # An unusable lock root is the could-not-inspect case the acceptance
  # criteria name explicitly, and it is judged by exactly the rule the
  # acquirer uses, so the two can never disagree about one root again.
  _lock_root_usable "$root" || return 2

  d="$root/$key.lock"
  owner="$d/owner"
  if [ -e "$d" ] && { [ ! -d "$d" ] || [ ! -r "$d" ] || [ ! -x "$d" ]; }; then
    return 2
  fi

  if [ ! -e "$owner" ]; then
    # Nothing on disk for this subject. Determinate, and honestly zero: there
    # was no record to read.
    LOCK_STATE=free
    LOCK_INSPECTED=0
    return 0
  fi
  [ -r "$owner" ] || return 2

  _lock_read_owner "$owner"
  LOCK_INSPECTED=1

  if [ "$LOCK_RELEASED" = yes ]; then
    LOCK_STATE=free
    return 0
  fi

  case "$LOCK_HOLDER_PID" in
    ''|*[!0-9]*) _lock_reset; return 2 ;;
  esac

  case "$(runs_alive "$LOCK_HOLDER_PID" "$LOCK_HOLDER_FP")" in
    unknown) _lock_reset; return 2 ;;
    yes)     LOCK_STATE=held; return 1 ;;
  esac

  # runs_alive says "not our process", and it has already accounted for the
  # owner having exec'd (same pid, same start time). Two very different
  # remaining reasons, and they differ in what a caller may do next, so they
  # are not collapsed into one "stale".
  got="$(runs_fingerprint "$LOCK_HOLDER_PID")"
  if [ -z "$got" ]; then
    LOCK_STATE=stale-dead
    return 0
  fi
  LOCK_STATE=stale-foreign
  return 0
}

# lock_claim SUBJECT -> 0 claimed | 1 refused (a live holder, named on
# stderr) | 2 could not inspect.
#
# Exit 2 never claims and never reclaims. A claim that cannot judge staleness
# would be a coin flip between deadlocking a subject and double-dispatching
# it, and the fail-closed side of that coin is "do nothing".
lock_claim() {
  local subject="${1-}" key root d gate fp attempt=0 rc
  _lock_reset

  # The escape hatch, and the three pieces of evidence it now leaves. It used
  # to set LOCK_STATE=disabled, which was read by zero consumers, and return
  # silently: two concurrent dispatches of one unit, 0 bytes on stderr, no
  # field on any receipt, `--lock-status` still answering `free`, and not even
  # a lock root on disk afterwards. An escape hatch is defensible; one that
  # leaves no evidence it was used is not, because the operator debugging the
  # duplicate a week later has nothing to find.
  #
  # The warning fires on EVERY bypassed claim rather than once per process, on
  # purpose: BATON_LOCK_DISABLE is exported, so one `export` covers a whole
  # night and every child in it, and a once-per-process line would under-report
  # by exactly the factor that matters.
  if _lock_bypassed; then
    LOCK_STATE=bypassed
    LOCK_HOLDER_PID="$$"
    LOCK_INSPECTED=0
    _lock_say "SINGLE-WRITER GUARD BYPASSED for '$subject' -- BATON_LOCK_DISABLE=1 is set, so nothing was inspected and nothing is arbitrating this subject. A second writer will NOT be refused."
    _lock_note_bypass "$subject"
    return 0
  fi

  key="$(_lock_key "$subject")" || return 2
  root="$(lock_dir)"
  mkdir -p "$root" 2>/dev/null || return 2
  [ -r "$root" ] && [ -w "$root" ] && [ -x "$root" ] || return 2
  # Staleness cannot be judged without a process table, and a claim that
  # cannot judge staleness must not take the lock.
  _runs_ps_usable || return 2

  # Winning the gate and writing the owner record are two steps, so there is a
  # window of a few microseconds in which a subject reads `free` while a
  # claim is already in flight. A racer that only looked once inside that
  # window would loop straight past every retry and answer could-not-inspect
  # for a lock that is plainly held (measured: 3 of 3 concurrent runs before
  # this backoff existed). The retries are therefore SPACED, and the total
  # window is long enough to cover the two syscalls by orders of magnitude.
  while [ "$attempt" -lt 8 ]; do
    [ "$attempt" -eq 0 ] || sleep 0.1
    attempt=$((attempt + 1))

    lock_probe "$subject" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 2 ]; then
      _lock_reset
      return 2
    fi
    if [ "$rc" -eq 1 ]; then
      if [ "$LOCK_HOLDER_PID" = "$$" ]; then
        # Re-entrance is not a second writer. --night hands one session id
        # from one account to the next inside a single baton process; that is
        # the same writer resuming, not two.
        LOCK_STATE=claimed
        return 0
      fi
      # The knob is still named, and deliberately: a guard that blocks an
      # operator at 3am with no stated way through is a worse failure than the
      # one it prevents. It is named as a KNOB and never as a pasteable
      # command line (root cause 2), and the line now also says that using it
      # is recorded -- an escape hatch you can find afterwards is a different
      # object from one you cannot.
      _lock_say "'$subject' is locked by live pid $LOCK_HOLDER_PID (held since ${LOCK_CLAIMED_AT:-unknown}, prov=${LOCK_HOLDER_PROV:-unknown}); refusing to be the second writer. Knob to bypass, recorded on every claim and receipt when set: BATON_LOCK_DISABLE"
      return 1
    fi

    # free | stale-dead | stale-foreign: race for THIS generation's gate.
    d="$root/$key.lock"
    mkdir -p "$d" 2>/dev/null || { _lock_reset; return 2; }
    gate="$d/g-$LOCK_TOKEN"
    if mkdir "$gate" 2>/dev/null; then
      fp="$(runs_fingerprint $$)"
      _lock_write_owner "$subject" "$$" "$fp" || { _lock_reset; return 2; }
      _lock_read_owner "$d/owner"
      if [ "$LOCK_HOLDER_PID" = "$$" ]; then
        LOCK_STATE=claimed
        LOCK_INSPECTED=1
        return 0
      fi
      _lock_reset
      return 2
    fi
    # Someone else took this generation. Loop: the next probe sees them.
  done

  # Every retry saw an unowned subject whose gate was already taken. Either a
  # claimer is still mid-write (it is not, after this many spaced retries) or
  # one died in the two-syscall window between winning the gate and writing
  # its owner record, leaving a gate nobody will ever claim. That is a
  # could-not-determine, not a free lock: taking it here would be guessing.
  _lock_say "'$subject': a claim gate is taken but no owner record ever appeared. Not claiming. Clear the subject's directory under $(lock_dir) to reset it."
  _lock_reset
  return 2
}

# lock_release SUBJECT -> 0 released (or already free) | 1 held by someone
# else | 2 could not inspect.
#
# A release writes a tombstone rather than deleting the record. An absent
# record and an unreadable one must not look alike, and the tombstone is what
# advances the generation token so the next claimer races a gate name that
# has never been won.
lock_release() {
  local subject="${1-}" rc
  lock_probe "$subject" >/dev/null 2>&1; rc=$?
  case "$rc" in
    2) return 2 ;;
    0) return 0 ;;
  esac
  if [ "$LOCK_HOLDER_PID" != "$$" ]; then
    return 1
  fi
  _lock_write_owner "$subject" "$$" "$LOCK_HOLDER_FP" yes || return 2
  return 0
}

# lock_hold SUBJECT -- CMD... -- claim, run, release, propagate the child's
# exit code. The claim and the work it guards are one statement so a claim
# cannot outlive the thing it was taken for, and the owner pid on disk is
# this process, which is alive for exactly as long as the guarded command.
lock_hold() {
  local subject="${1-}" rc
  shift 2>/dev/null || { _lock_say "lock_hold needs a subject"; return 2; }
  if [ "${1-}" != "--" ]; then
    _lock_say "lock_hold needs a -- before the command to run"
    return 2
  fi
  shift
  if [ $# -eq 0 ]; then
    _lock_say "lock_hold needs a command to run"
    return 2
  fi
  lock_claim "$subject"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # The claim layer's own exit 2 is marked here, at the seam where it is
    # about to become a process exit code that automation reads. Without the
    # marker this exit 2 is byte-identical to `"$@"` having run and exited 2.
    [ "$rc" -eq 2 ] && _lock_cni "$subject" claim-could-not-inspect
    return "$rc"
  fi
  "$@"
  rc=$?
  lock_release "$subject" >/dev/null 2>&1
  return "$rc"
}

# lock_redispatch UNIT -- CMD... -- the reconcile action, as ONE statement:
# claim the unit, confirm the matched orphan is dead, then launch the
# replacement. Splitting these apart is what produces the split-brain the
# lock exists to stop -- a claim with no kill leaves two live copies, and a
# kill with no claim lets a second orchestrator claim the corpse's unit and
# launch a third.
#
# There is deliberately no path from "could not confirm the orphan is gone"
# to launching anyway. That branch releases the claim and exits 2, so the
# unit stays visible on the next board rather than being quietly consumed.
lock_redispatch() {
  local unit="${1-}" rc
  shift 2>/dev/null || { _lock_say "lock_redispatch needs a unit"; return 2; }
  if [ "${1-}" != "--" ]; then
    _lock_say "lock_redispatch needs a -- before the replacement command"
    return 2
  fi
  shift
  if [ $# -eq 0 ]; then
    _lock_say "lock_redispatch needs a replacement command to run"
    return 2
  fi

  lock_claim "unit:$unit"; rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 2 ] && _lock_cni "unit:$unit" claim-could-not-inspect
    return "$rc"
  fi

  if ! lock_kill_orphan "$unit"; then
    _lock_say "'$unit': could not CONFIRM the matched orphan is gone; not launching a replacement on top of it"
    _lock_cni "unit:$unit" orphan-death-unconfirmed
    lock_release "unit:$unit" >/dev/null 2>&1
    return 2
  fi

  "$@"
  rc=$?
  lock_release "unit:$unit" >/dev/null 2>&1
  return "$rc"
}

# lock_subject_for_argv ARGS... -- the lock subject a claude argv implies, or
# nothing (return 1). Only an EXPLICIT `--resume <id>` / `--resume=<id>` is
# keyable: a cold start and `-c` have no session id at the moment of launch
# (the id only becomes knowable once a transcript grows), so they are
# deliberately UNguarded rather than guarded by a guessed key -- a guessed key
# would serialize unrelated launches onto one subject, which is a worse bug
# than the one being prevented. The 2026-08-25 incident was two `--resume
# <id>` launches; that is the shape this can cover today.
#
# Ported from the unmerged fix/2-resume-lock branch (PR #5), which had this
# right before main did. Only the subject namespace changed: main's lock root
# takes namespaced subjects (`session:`, `unit:`, `login:`), so the branch's
# `session-<id>` becomes `session:<id>` and reaches the same key.
lock_subject_for_argv() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "--resume" ]; then
      [ -n "$a" ] || return 1
      printf 'session:%s' "$a"; return 0
    fi
    case "$a" in
      --resume=*)
        [ -n "${a#--resume=}" ] || return 1
        printf 'session:%s' "${a#--resume=}"; return 0 ;;
    esac
    prev="$a"
  done
  return 1
}

# lock_guard_launch ARGS... -- the guard baton's INTERACTIVE dispatch calls
# just before handing ARGS to claude, on every path that can launch:
# `baton <account> ...`, plain auto-pick, `--fast` and `--next`. Silent and
# free when the argv implies no session.
#
# It EXITS rather than returning a code, so no call site can acquire, ignore
# the answer and launch anyway. That is the whole reason the criterion was
# unmet on main: the claim existed (in watch.sh) and the interactive path
# simply never asked.
#
# baton `exec`s, so the pid recorded here BECOMES the claude process and the
# lock stays live for exactly as long as the session does -- no trap to miss,
# no release to forget, and the process dying IS the release, which is the
# only kind that survives a host restart.
lock_guard_launch() {
  local subject rc
  subject="$(lock_subject_for_argv "$@")" || return 0
  [ -n "$subject" ] || return 0
  lock_claim "$subject"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && _lock_cni "$subject" claim-could-not-inspect
  exit "$rc"
}

# lock_report -- the `--locks` check: enumerate every subject the lock root
# actually holds a record for, and say how many that was.
#
# This exists because `--lock-status <subject>` can only ever answer about the
# ONE subject it was handed, so its `inspected` count is 0 or 1 and can never
# be evidence about the board. A caller that wants "the guard is installed and
# has subjects on disk" has to ask a question that enumerates, and the count
# has to be able to come back 0. Ported from PR #5's `lock_report`.
#
# Exit codes, and why "found nothing" and "could not look" are not one code:
#   0  inspected at least one subject
#   1  inspected the root successfully and found ZERO subjects
#   2  COULD NOT INSPECT the root at all
# Read-only on purpose: a reporter that reclaims what it reports cannot be
# trusted about what was there before it looked.
lock_report() {
  local root d subject n=0
  root="$(lock_dir)"
  if ! _lock_root_usable "$root"; then
    _lock_cni "(every subject)" lock-root-unusable
    return 2
  fi
  printf '%-52s %-18s %-10s %s\n' SUBJECT STATE HOLDER-PID PROV
  if [ -d "$root" ]; then
    for d in "$root"/*.lock; do
      [ -d "$d" ] || continue
      [ -e "$d/owner" ] || continue
      subject="$(basename "$d")"; subject="${subject%.lock}"
      lock_probe "$subject" >/dev/null 2>&1
      printf '%-52s %-18s %-10s %s\n' \
        "$subject" "$LOCK_STATE" "${LOCK_HOLDER_PID:--}" "${LOCK_HOLDER_PROV:--}"
      n=$((n + 1))
    done
  fi
  printf 'baton: inspected %s lock subject(s) under %s\n' "$n" "$root"
  [ "$n" -gt 0 ] || return 1
  return 0
}

# lock_kill_orphan UNIT -> 0 CONFIRMED gone | 2 could not confirm.
# Sets LOCK_KILLED=yes|no.
#
# The orphan-kill rule (baton#2 root cause 4): when a reconcile decides an
# `orphan-running` unit is to be REDONE rather than adopted, the matched
# orphan is killed and its death is confirmed by re-probing -- never assumed
# from the fact that a signal was sent. Otherwise the "fix" is exactly the
# duplicate the issue is about, with the operator's blessing.
#
# Two safety properties, in order of how badly they fail:
#   1. A pid whose fingerprint no longer matches the receipt is NOT signalled.
#      runs_alive already reads that as `no`, so a stranger who inherited the
#      number after a reboot is never killed by baton's reconcile.
#   2. `unknown` is exit 2, not a green light. If liveness cannot be
#      determined the replacement must not launch, because "I could not see
#      it" and "it is gone" are the two answers this whole mechanism exists
#      to keep apart.
lock_kill_orphan() {
  local unit="${1-}" start pid fp alive grace waited
  LOCK_KILLED=no
  [ -n "$unit" ] || return 2
  start="$(runs_dir)/$unit.start"
  # No start receipt means no pid of ours was ever recorded, so there is
  # nothing of ours to kill. That is a determinate answer, not a guess.
  [ -e "$start" ] || return 0
  [ -r "$start" ] || return 2

  pid="$(runs_field "$start" pid)"
  fp="$(runs_field "$start" fingerprint)"
  alive="$(runs_alive "$pid" "$fp")"
  case "$alive" in
    no)      return 0 ;;
    unknown) return 2 ;;
  esac

  grace="${BATON_LOCK_KILL_GRACE:-5}"
  kill -TERM "$pid" 2>/dev/null
  if _lock_await_death "$pid" "$fp" "$grace"; then LOCK_KILLED=yes; return 0; fi
  [ "$LOCK_AWAIT" = unknown ] && return 2

  kill -KILL "$pid" 2>/dev/null
  if _lock_await_death "$pid" "$fp" "$grace"; then LOCK_KILLED=yes; return 0; fi
  return 2
}

# _lock_await_death PID FP SECONDS -> 0 when a re-probe CONFIRMS the process
# is gone within the window. Sets LOCK_AWAIT to the last answer, so the
# caller can tell "still alive" from "could not ask".
_lock_await_death() {
  local pid="$1" fp="$2" limit="$3" waited=0
  while :; do
    LOCK_AWAIT="$(runs_alive "$pid" "$fp")"
    case "$LOCK_AWAIT" in
      no)      return 0 ;;
      unknown) return 1 ;;
    esac
    awk -v w="$waited" -v l="$limit" 'BEGIN{exit !(w>=l)}' && return 1
    sleep 0.1
    waited="$(awk -v w="$waited" 'BEGIN{printf "%.1f", w+0.1}')"
  done
}
