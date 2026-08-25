#!/usr/bin/env bash
# runs -- durable receipts for launched children, and the liveness probe that
# reads them back after everything that wrote them is gone.
#
# Dependency direction (QA-DOC section 4): this file depends on no other
# baton module. It touches the process table and its own receipt directory,
# and nothing else -- never a credential file, never an account's private
# state (rule 4's forbidden edge).
#
# WHY RECEIPTS EXIST AT ALL: a background child is a separate process group.
# When the parent dies -- a dropped API connection, a host restart -- the
# child is reparented to launchd and keeps running, and nothing ever
# reattaches to it. In-memory bookkeeping dies with the parent, so at restart
# the same on-disk evidence has to answer three different questions: did this
# ever start, is it still running, and did it finish. One receipt at launch
# and one at exit answer all three; nothing else does.

# runs_dir -- where receipts live. Honors BATON_RUNS_DIR, then falls back
# under BATON_ACCOUNTS_ROOT so tests that override the accounts root stay
# hermetic (QA-DOC section 4 rule 6: no test depends on the real home).
runs_dir() {
  printf '%s\n' "${BATON_RUNS_DIR:-${BATON_ACCOUNTS_ROOT:-$HOME/.claude-accounts}/.runs}"
}

# _runs_ps_usable -- positive control for the probe itself. pid 1 exists on
# every machine this runs on, so if `ps` cannot describe pid 1 then `ps` is
# not answering questions at all and every "that process is gone" it reports
# is worthless. A probe that cannot inspect must say could-not-inspect, not
# report an empty board.
_runs_ps_usable() {
  ps -p 1 -o args= >/dev/null 2>&1
}

# runs_fingerprint PID -- the identity of the process currently under that
# pid: its start time and its full command line, whitespace-squashed. Two
# processes can share a pid over time but not a start time, which is what
# makes this the pid-reuse guard. Prints nothing if the pid is absent.
runs_fingerprint() {
  local pid="${1-}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  ps -p "$pid" -o lstart=,args= 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# runs_birth FINGERPRINT -- the start-time half of a fingerprint. `ps -o
# lstart=` is five whitespace-separated fields ("Tue Aug 25 17:16:01 2026"),
# and the rest of the fingerprint is the command line.
#
# This is the part of a process's identity that survives an `exec`, and it is
# the part that actually defeats pid reuse: two processes can share a pid over
# time but not a pid AND a start time. Prints nothing when the fingerprint is
# too short to carry one, which is how a truncated or planted record stays
# unmatchable rather than matching everything.
#
# CAVEAT, stated because "start time discriminates a reused pid" is not
# unconditional: `ps -o lstart` is SECOND-resolution. A pid reused inside the
# same wall-clock second by a process with the same argv would read as the
# original holder, so pid+start-time is strictly weaker than pid+argv for that
# one case. Not reachable in practice -- macOS allocates pids sequentially and
# wraps at 99998, so the reuse this guards against is a reboot, not a
# microsecond -- and the alternative is worse by a wide margin: pid+argv reads
# a child that merely exec'd as a corpse, which points straight at
# re-dispatching live work (the bug 3194623 fixed).
runs_birth() {
  local f="${1-}" restore=no
  case "$-" in *f*) : ;; *) restore=yes ;; esac
  # The command-line half is arbitrary user text and can contain a glob, so
  # field-splitting it without disabling pathname expansion would let a
  # recorded `*` become a directory listing.
  set -f
  set -- $f
  [ "$restore" = yes ] && set +f
  [ $# -ge 5 ] || return 0
  printf '%s %s %s %s %s' "$1" "$2" "$3" "$4" "$5"
}

# runs_alive PID FINGERPRINT -> yes | no | unknown
#   yes      a live process IS the recorded one: same pid, and either the same
#            command line or the same start time (it exec'd)
#   no       CONFIRMED gone, or a stranger has since taken the pid
#   unknown  the question could not be asked
runs_alive() {
  local pid="${1-}" want="${2-}" got

  case "$pid" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || { printf 'unknown\n'; return 0; }
  # A truncated receipt left nothing to match against. Undetermined, not
  # false: reporting "no" here would license re-dispatching a live orphan.
  [ -n "$want" ] || { printf 'unknown\n'; return 0; }

  _runs_ps_usable || { printf 'unknown\n'; return 0; }

  got="$(runs_fingerprint "$pid")"
  if [ -z "$got" ]; then
    # ps works (control passed) and has nothing for this pid: reaped.
    printf 'no\n'
  elif [ "$got" = "$want" ]; then
    printf 'yes\n'
  elif [ -n "$(runs_birth "$want")" ] && [ "$(runs_birth "$got")" = "$(runs_birth "$want")" ]; then
    # Same pid, same START TIME, different command line: this IS the recorded
    # process. It exec'd.
    #
    # That is not a corner case here, it is the normal path. run_watched
    # launches `env -u CLAUDE_CONFIG_DIR claude ...` and records the
    # fingerprint the instant the pid exists, which RACES the child's own
    # exec: sometimes the recorded argv is `env -u ... claude` and sometimes
    # it is already the CLI. Measured 2026-08-25: 1 in 8 samples of that exact
    # shape caught the pre-exec image, and under the full QA workflow a live
    # orphan read as dead in 3 of 6 runs.
    #
    # Comparing the full command line therefore reported a living child as
    # gone, which is the worst direction for this probe to be wrong in:
    # `dead-partial` maps to action `reconcile`, so the wrong bucket pointed
    # straight at re-dispatching work that was still running -- the exact
    # duplicate receipts exist to prevent. Start time is both exec-stable and
    # the thing that actually discriminates a reused pid, so it is what
    # decides identity; the command line stays on the receipt for forensics.
    printf 'yes\n'
  else
    # Same number, different process. This is the pid-reuse case, and it is
    # a death for OUR unit however busy that pid looks now.
    printf 'no\n'
  fi
}

# _runs_write FILE CONTENT -- write-then-rename, so a reader at restart never
# sees a half-written receipt. A torn receipt would read back with missing
# fields, which the classifier can only call `unknown`.
_runs_write() {
  local dest="$1" body="$2" tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  printf '%s' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
}

# _runs_bypassed -- was the single-writer guard switched OFF when this receipt
# was written? Stamped on every receipt because BATON_LOCK_DISABLE is an
# exported env var: one `export` covers an entire night and every child in it,
# and the environment is gone by the time anyone reads the receipts back and
# asks why two of something ran. Reading an env var is not a dependency on
# lib/lock.sh -- the edge stays lock -> runs, one way, and this file still
# sources nothing.
_runs_bypassed() {
  if [ "${BATON_LOCK_DISABLE:-}" = 1 ]; then printf yes; else printf no; fi
}

# runs_record_start UNIT PID FINGERPRINT COMMAND -- written by the launcher
# at the moment the pid exists, because that is the only moment anything
# knows it. Every row carries prov=live|test so a self-test write can never
# be mistaken for a real run.
runs_record_start() {
  local unit="${1-}" pid="${2-}" fp="${3-}" cmd="${4-}"
  [ -n "$unit" ] || return 2
  _runs_write "$(runs_dir)/$unit.start" \
"unit=$unit
pid=$pid
pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ')
fingerprint=$fp
command=$cmd
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bypassed=$(_runs_bypassed)
prov=${BATON_RUNS_PROV:-live}
"
}

# runs_record_complete UNIT EXITCODE -- the only evidence that closes a unit.
# Written after wait(), so an exit code is real rather than assumed.
runs_record_complete() {
  local unit="${1-}" code="${2-}"
  [ -n "$unit" ] || return 2
  _runs_write "$(runs_dir)/$unit.complete" \
"unit=$unit
exit=$code
ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bypassed=$(_runs_bypassed)
prov=${BATON_RUNS_PROV:-live}
"
}

# runs_field FILE NAME -- read one field back. An absent file or an absent
# field is empty, never a neighbouring field's value (the match is anchored,
# so `pid` does not read `pgid`).
runs_field() {
  local file="${1-}" name="${2-}"
  [ -f "$file" ] || return 0
  [ -n "$name" ] || return 0
  sed -n "s/^${name}=//p" "$file" | head -1
}

# _json_str VALUE -- the two characters that would otherwise break out of a
# JSON string. A recorded command line is arbitrary user text and lands in
# this file verbatim, so it is escaped rather than trusted.
_json_str() {
  printf '%s' "${1-}" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'
}

# runs_project -- the compact board a restarted orchestrator reads INSTEAD of
# the raw pile. Depends on pickup_classify (lib/pickup.sh), which the caller
# sources first; the edge runs -> pickup is one-way, the same shape as
# accounts -> detect.
#
# Exit codes are the contract, and they are three-valued on purpose:
#   0  every unit is resolved (done, or confirmed never-started)
#   1  at least one unit needs a decision before anything is re-dispatched
#   2  COULD NOT INSPECT -- no receipts were readable. This is not a clean
#      board. A sweep that inspected zero subjects found nothing because it
#      looked at nothing, and reporting that as success is exactly how a live
#      orphan gets a duplicate launched on top of it.
runs_project() {
  local dir units unit u_start u_complete has_start has_complete alive bucket
  local pid fp cmd code line
  local n_done=0 n_dead=0 n_orphan=0 n_never=0 n_unknown=0 inspected=0
  local rows="" forensics="" verdict rc cap=200 dropped=0
  dir="$(runs_dir)"

  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    _project_emit "$dir" 0 could-not-inspect "" "" 0 0 0 0 0 0
    return 2
  fi

  # BSD sed has no \| alternation in a basic regex, so this is two anchored
  # substitutions rather than one clever pattern. `grep -e` first keeps a
  # stray file in the directory from being read back as a phantom unit.
  units="$(ls -1 "$dir" 2>/dev/null | grep -e '\.start$' -e '\.complete$' \
    | sed -e 's/\.start$//' -e 's/\.complete$//' | sort -u)"
  if [ -z "$units" ]; then
    _project_emit "$dir" 0 could-not-inspect "" "" 0 0 0 0 0 0
    return 2
  fi

  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    u_start="$dir/$unit.start"; u_complete="$dir/$unit.complete"
    [ -f "$u_start" ] && has_start=yes || has_start=no
    [ -f "$u_complete" ] && has_complete=yes || has_complete=no

    if [ "$has_start" = yes ]; then
      pid="$(runs_field "$u_start" pid)"
      fp="$(runs_field "$u_start" fingerprint)"
      cmd="$(runs_field "$u_start" command)"
      alive="$(runs_alive "$pid" "$fp")"
    else
      # No start receipt means no pid was ever recorded, so there is no
      # process of ours to be alive. That is a confirmed absence rather than
      # an unprobed guess ONLY because the receipt is written the instant the
      # pid exists and lands by atomic rename. The residual gap is real and
      # named: a child forked microseconds before the host died, whose
      # receipt never landed, is invisible here and will look never-started.
      pid=""; fp=""; cmd=""; alive=no
    fi

    bucket="$(pickup_classify "$has_start" "$has_complete" "$alive")"
    code=""
    [ "$has_complete" = yes ] && code="$(runs_field "$u_complete" exit)"
    inspected=$((inspected + 1))

    case "$bucket" in
      done)           n_done=$((n_done + 1)) ;;
      dead-partial)   n_dead=$((n_dead + 1)) ;;
      orphan-running) n_orphan=$((n_orphan + 1)) ;;
      never-started)  n_never=$((n_never + 1)) ;;
      *)              n_unknown=$((n_unknown + 1)) ;;
    esac

    if [ "$inspected" -le "$cap" ]; then
      line="    {\"unit\": \"$(_json_str "$unit")\", \"status\": \"$bucket\""
      line="$line, \"action\": \"$(_project_action "$bucket")\""
      line="$line, \"pid\": \"$(_json_str "$pid")\", \"exit\": \"$(_json_str "$code")\""
      line="$line, \"command\": \"$(_json_str "$cmd")\"}"
      rows="${rows}${line}
"
    else
      dropped=$((dropped + 1))
    fi

    case "$bucket" in
      dead-partial|unknown)
        forensics="${forensics}    \"$(_json_str "$u_start")\"
" ;;
    esac
  done <<EOF
$units
EOF

  if [ "$((n_dead + n_orphan + n_unknown))" -gt 0 ]; then
    verdict=needs-reconcile; rc=1
  else
    verdict=resolved; rc=0
  fi

  _project_emit "$dir" "$inspected" "$verdict" "$rows" "$forensics" \
    "$n_done" "$n_dead" "$n_orphan" "$n_never" "$n_unknown" "$dropped"
  return "$rc"
}

# _project_action BUCKET -- what the reader may do without asking. Only two
# buckets carry an automatic action; the rest hold, because re-dispatching a
# live orphan or a half-finished side effect is the failure this exists to
# prevent.
_project_action() {
  case "${1-}" in
    done)           printf 'none' ;;
    never-started)  printf 'dispatch' ;;
    orphan-running) printf 'monitor' ;;
    *)              printf 'reconcile' ;;
  esac
}

_project_emit() { # dir inspected verdict rows forensics done dead orphan never unknown dropped
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "prov": "%s",\n' "${BATON_RUNS_PROV:-live}"
  printf '  "runs_dir": "%s",\n' "$(_json_str "$1")"
  printf '  "inspected": %s,\n' "$2"
  printf '  "verdict": "%s",\n' "$3"
  printf '  "counts": {"done": %s, "dead-partial": %s, "orphan-running": %s, "never-started": %s, "unknown": %s},\n' \
    "$6" "$7" "$8" "$9" "${10}"
  # A cap that silently truncated would read as "this is the whole board".
  printf '  "units_omitted_by_cap": %s,\n' "${11}"
  printf '  "units": [\n%s  ],\n' "${4-}"
  printf '  "needs_forensics": [\n%s  ]\n' "${5-}"
  printf '}\n'
}
