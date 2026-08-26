#!/usr/bin/env python3
"""mutation-run.py -- the enumerator behind HARDEN.md's mutant table.

Why this exists instead of ~/.claude/skills/mutation-tests/: that skill's
engine (mutate.py) supports Python and JS/TS only and exits 2
("unsupported language") on a .sh file, and its enumerator
(changed_functions.py) classifies every file in this diff as `non_code`,
so crap-check.sh would inspect ZERO subjects and print a pass. A gate that
inspected zero subjects has not passed -- see HARDEN.md section 1. This
script is the bash-shaped replacement: same discipline (one behaviour
edit at a time, restore-and-verify-by-hash after every mutant, the repo's
own suite is the test), applied to the four shell files this story
changed.

Usage:
  python3 .ab/mutation-run.py             # run every mutant
  python3 .ab/mutation-run.py M07 M12     # run only these ids
  python3 .ab/mutation-run.py --list

A mutant is KILLED when the suite exits nonzero, SURVIVED when it exits 0.
The tree is restored from an in-memory byte copy after every mutant and
the restore is verified by sha256; a mismatch aborts the whole run rather
than leaving a mutant applied.
"""

import hashlib
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = ["bash", "tests/run.sh"]
SUITE_TIMEOUT = 420

# (id, file, function, provenance, description, from_literal, to_literal)
# provenance: NEW = introduced by this story, SHARED = pre-existing code the
# story put under a new caller (--night), so its behaviour is now load-bearing
# for paths that did not exist at 173fd9e.
MUTANTS = [
    # ---------------------------------------------------------- lib/detect.sh
    ("M01", "lib/detect.sh", "classify_text", "NEW",
     "reorder: AUTH tested before LIMIT (precedence flip)",
     """  if printf '%s' "$text" | grep -qiE 'hit your .*limit|usage limit|limit reached'; then
    echo LIMIT
  elif printf '%s' "$text" | grep -qiE 'not logged in|please run /login|invalid api key|authentication'; then
    echo AUTH""",
     """  if printf '%s' "$text" | grep -qiE 'not logged in|please run /login|invalid api key|authentication'; then
    echo AUTH
  elif printf '%s' "$text" | grep -qiE 'hit your .*limit|usage limit|limit reached'; then
    echo LIMIT"""),

    ("M02", "lib/detect.sh", "classify_text", "NEW",
     "drop case-insensitivity from the LIMIT regex (-qiE -> -qE)",
     """grep -qiE 'hit your .*limit|usage limit|limit reached'""",
     """grep -qE 'hit your .*limit|usage limit|limit reached'"""),

    ("M03", "lib/detect.sh", "classify_text", "NEW",
     "swap the total-partition fallback: UNKNOWN -> AUTH",
     """  else
    echo UNKNOWN
  fi""",
     """  else
    echo AUTH
  fi"""),

    ("M04", "lib/detect.sh", "parse_reset_epoch", "SHARED",
     "boundary flip: already-passed test `t <= nowt` -> `t >= nowt`",
     "if t <= nowt:", "if t >= nowt:"),

    ("M05", "lib/detect.sh", "parse_reset_epoch", "SHARED",
     "drop the roll-to-tomorrow step for an already-passed reset time",
     "    t += datetime.timedelta(days=1)", "    t = t"),

    ("M06", "lib/detect.sh", "parse_reset_epoch", "SHARED",
     "12-hour wrap boundary: `% 12` -> `% 24` (breaks 12:xxpm/12:xxam)",
     "h = int(m.group(1)) % 12", "h = int(m.group(1)) % 24"),

    # -------------------------------------------------------- lib/accounts.sh
    ("M07", "lib/accounts.sh", "parse_duration", "SHARED",
     "unit swap: `5h` parsed as 5*60 instead of 5*3600",
     """    *h) n="${1%h}"; mult=3600 ;;""",
     """    *h) n="${1%h}"; mult=60 ;;"""),

    ("M08", "lib/accounts.sh", "parse_duration", "SHARED",
     "drop the malformed-duration rejection (bad input reaches the arithmetic)",
     """  is_uint "$n" || die "bad duration '$1' (use 90m / 5h / 3d)\"""",
     """  :"""),

    ("M09", "lib/accounts.sh", "mark_dead_for_class", "NEW",
     "operator flip: parsed reset accepted only when in the PAST (-gt -> -lt)",
     """      [ "$reset" -gt "$(now)" ] 2>/dev/null || reset=$(( $(now) + $(parse_duration "$DEFAULT_DEAD") ))""",
     """      [ "$reset" -lt "$(now)" ] 2>/dev/null || reset=$(( $(now) + $(parse_duration "$DEFAULT_DEAD") ))"""),

    ("M10", "lib/accounts.sh", "mark_dead_for_class", "NEW",
     "AUTH dead duration 3600s -> 7200s",
     """      mark_dead "$name" "$(( $(now) + 3600 ))" auth""",
     """      mark_dead "$name" "$(( $(now) + 7200 ))" auth"""),

    ("M11", "lib/accounts.sh", "mark_dead", "SHARED",
     "dropped step: a dead mark no longer invalidates the ALIVE cache entry",
     """mark_dead() { mkdir -p "$DEADDIR"; echo "$2 ${3:-manual}" > "$DEADDIR/$1"; rm -f "$ALIVEDIR/$1"; }""",
     """mark_dead() { mkdir -p "$DEADDIR"; echo "$2 ${3:-manual}" > "$DEADDIR/$1"; }"""),

    ("M12", "lib/accounts.sh", "ranked", "SHARED",
     "ranking order reversed: `sort -n` -> `sort -rn` (busiest account first)",
     "  done | sort -n | awk '{print $2}'", "  done | sort -rn | awk '{print $2}'"),

    ("M13", "lib/accounts.sh", "probe", "NEW",
     "drop the canary check: any UNKNOWN probe reply is reported ALIVE",
     """      if printf '%s' "$out" | grep -qi "ok"; then""",
     """      if true; then"""),

    ("M14", "lib/accounts.sh", "set_envargs", "NEW",
     "swap the primary/non-primary branches (CONFIG_DIR + ENVARGS both)",
     """    ENVARGS=(env -u CLAUDE_CONFIG_DIR)
    CONFIG_DIR="$HOME/.claude"
  else
    ENVARGS=(env "CLAUDE_CONFIG_DIR=$ROOT/$1")
    CONFIG_DIR="$ROOT/$1\"""",
     """    ENVARGS=(env "CLAUDE_CONFIG_DIR=$ROOT/$1")
    CONFIG_DIR="$ROOT/$1"
  else
    ENVARGS=(env -u CLAUDE_CONFIG_DIR)
    CONFIG_DIR="$HOME/.claude\""""),

    ("M15", "lib/accounts.sh", "pick_live", "NEW",
     "UNKNOWN probe result skips the account instead of launching anyway",
     """      UNKNOWN) warn "unrecognized probe result for '$a' (network?); launching anyway: ${PROBE_OUT:0:120}"
               PICKED="$a"; return 0 ;;""",
     """      UNKNOWN) warn "unrecognized probe result for '$a' (network?); skipping: ${PROBE_OUT:0:120}" ;;"""),

    ("M16", "lib/accounts.sh", "alive_fresh", "SHARED",
     "freshness comparison inverted (-lt -> -gt): cache never trusted",
     """  [ $(( $(now) - m )) -lt "$ALIVE_TTL" ]""",
     """  [ $(( $(now) - m )) -gt "$ALIVE_TTL" ]"""),

    ("M17", "lib/accounts.sh", "bump", "SHARED",
     "dropped step: last-used account no longer recorded",
     """  echo "$1" > "$LAST"
}""",
     """  :
}"""),

    ("M18", "lib/accounts.sh", "launch", "SHARED",
     "exec -> fork+wait (plain baton grows an extra process generation)",
     """  exec "${ENVARGS[@]}" claude "$@\"""",
     """  "${ENVARGS[@]}" claude "$@\""""),

    ("M19", "lib/accounts.sh", "pick_live", "NEW",
     "drop the BATON_EXCLUDE pass-through from ranked()",
     """  for a in $(ranked "${BATON_EXCLUDE:-}"); do""",
     """  for a in $(ranked); do"""),

    # ----------------------------------------------------------- lib/watch.sh
    # M20 re-pointed post-review: find_new_jsonl no longer exists (the D6
    # amendment replaced new-file discovery with growth watching). Its
    # successor is the pre-launch size lookup -- the thing that keeps a
    # RESUMED transcript's existing content from being re-classified.
    ("M20", "lib/watch.sh", "launch_size", "NEW",
     "pre-launch size reported as 0: a resumed transcript is re-read from byte 0",
     """{ s=$1; sub(/^[0-9]+ /, "", $0); if ($0 == p) { print s; found=1; exit } }""",
     """{ s=$1; sub(/^[0-9]+ /, "", $0); if ($0 == p) { print 0; found=1; exit } }"""),

    # M21's literal re-pointed post-review (same behaviour edit, new line).
    ("M21", "lib/watch.sh", "run_watched", "NEW",
     "session id blanked on a live-transcript rotation (forces -c instead of --resume)",
     """            NIGHT_SESSION_ID=$(basename "$f" .jsonl)""",
     """        NIGHT_SESSION_ID=\"\""""),

    ("M22", "lib/watch.sh", "run_watched", "NEW",
     "post-exit probe: dropped condition, AUTH no longer rotates",
     """  case "$PROBE_CLASS" in
    LIMIT|AUTH)""",
     """  case "$PROBE_CLASS" in
    LIMIT)"""),

    ("M23", "lib/watch.sh", "run_watched", "NEW",
     "live transcript: dropped condition, AUTH line no longer kills the child",
     """      if [ "$class" = LIMIT ] || [ "$class" = AUTH ]; then""",
     """      if [ "$class" = LIMIT ]; then"""),

    ("M24", "lib/watch.sh", "run_watched", "NEW",
     "signal swap: SIGTERM -> SIGKILL (child loses its chance to clean up)",
     """        kill -TERM "$pid" 2>/dev/null""",
     """        kill -KILL "$pid" 2>/dev/null"""),

    ("M25", "lib/watch.sh", "transcript_dir_for", "NEW",
     "slug rule: only `/` replaced, `.` left intact",
     """  local slug; slug=$(printf '%s' "$PWD" | sed 's/[./]/-/g')""",
     """  local slug; slug=$(printf '%s' "$PWD" | sed 's|/|-|g')"""),

    ("M26", "lib/watch.sh", "night_mode", "NEW",
     "handoff cap off-by-one (-gt -> -ge): cap N allows only N-1 handoffs",
     """        if [ $((handoffs + 1)) -gt "$max_handoffs" ]; then""",
     """        if [ $((handoffs + 1)) -ge "$max_handoffs" ]; then"""),

    ("M27", "lib/watch.sh", "night_mode", "NEW",
     "handoff counter never incremented (cap unreachable)",
     """        handoffs=$((handoffs + 1))""",
     """        handoffs=$((handoffs))"""),

    ("M28", "lib/watch.sh", "night_mode", "NEW",
     "exit-code swap: child's real code replaced by 0",
     """        exit "$NIGHT_EXIT_CODE\"""",
     """        exit 0"""),

    ("M29", "lib/watch.sh", "night_mode", "NEW",
     "resume-mode test inverted (-n -> -z): known session id forces -c",
     """        if [ -n "$NIGHT_SESSION_ID" ]; then""",
     """        if [ -z "$NIGHT_SESSION_ID" ]; then"""),

    # M30 re-pointed post-review: the give-up flag it targeted is gone with
    # the D6 amendment. Its successor is the order of the two reasons a night
    # can end -- exhaustion vs. the handoff cap -- which is the F2 fix.
    ("M30", "lib/watch.sh", "night_mode", "NEW",
     "cap checked before exhaustion: the last account's limit is misreported as a cap hit",
     """        candidates_exist || die_no_live_account
        if [ $((handoffs + 1)) -gt "$max_handoffs" ]; then
          die "handoff cap ($max_handoffs) reached; raise it with BATON_MAX_HANDOFFS"
        fi""",
     """        if [ $((handoffs + 1)) -gt "$max_handoffs" ]; then
          die "handoff cap ($max_handoffs) reached; raise it with BATON_MAX_HANDOFFS"
        fi
        candidates_exist || die_no_live_account"""),

    # M31's literal re-pointed post-review (same behaviour edit, new line).
    ("M31", "lib/watch.sh", "run_watched", "NEW",
     "growth test relaxed (-gt -> -ge): unchanged file re-read every poll",
     """      if [ "$size" -gt "$offset" ]; then""",
     """      if [ "$size" -ge "$offset" ]; then"""),

    # --------------------------------------------------------------- baton
    ("M32", "baton", "dispatch --probe", "SHARED",
     "drop the account-exists guard on --probe",
     """    [ -n "${2:-}" ] && is_account "$2" || die "--probe <account>\"""",
     """    [ -n "${2:-}" ] || die "--probe <account>\""""),

    ("M33", "baton", "dispatch --pick", "SHARED",
     "--pick prints two candidates instead of one",
     """    ranked "${2:-}" | head -1; exit 0 ;;""",
     """    ranked "${2:-}" | head -2; exit 0 ;;"""),

    ("M34", "baton", "dispatch empty-accounts guard", "SHARED",
     "empty-accounts guard condition flipped (-eq 0 -> -gt 0)",
     """if [ ${#accounts[@]} -eq 0 ]; then""",
     """if [ ${#accounts[@]} -gt 0 ]; then"""),

    ("M35", "baton", "dispatch --dead", "SHARED",
     "drop the re-raise of parse_duration's die (subshell failure swallowed)",
     """    dur=$(parse_duration "${3:-$DEFAULT_DEAD}") || exit 1""",
     """    dur=$(parse_duration "${3:-$DEFAULT_DEAD}")"""),

    # M36 re-pointed at a5986fc: the --night block now sources runs.sh and
    # lock.sh ahead of watch.sh (baton#2's lock wiring landed since a2d951e),
    # so the old three-line anchor no longer matches. Same behaviour edit
    # (drop the `shift`), new surrounding lines.
    ("M36", "baton", "dispatch --night", "NEW",
     "--night no longer shifts its own flag off the claude args",
     """  --night)
    shift
    # runs.sh before lock.sh before watch.sh: the watcher records a receipt
    # the moment it has a pid and claims a session before resuming one, so
    # both the recorder and the arbiter have to be defined before the
    # launcher runs. lock -> runs is the only edge between the two.
    . "$SCRIPT_DIR/lib/runs.sh"
    . "$SCRIPT_DIR/lib/lock.sh"
    . "$SCRIPT_DIR/lib/watch.sh"
    night_mode "$@" ;;""",
     """  --night)
    # runs.sh before lock.sh before watch.sh: the watcher records a receipt
    # the moment it has a pid and claims a session before resuming one, so
    # both the recorder and the arbiter have to be defined before the
    # launcher runs. lock -> runs is the only edge between the two.
    . "$SCRIPT_DIR/lib/runs.sh"
    . "$SCRIPT_DIR/lib/lock.sh"
    . "$SCRIPT_DIR/lib/watch.sh"
    night_mode "$@" ;;"""),

    # ------------------------------------------ round 2: added after round 1
    # (M19 and M37-M46 target code that round 1's tree did not have, or that
    # round 1 showed nothing was watching.)
    ("M37", "lib/accounts.sh", "die_no_live_account", "NEW",
     "reword the exhaustion message the operator is told to act on (drops the accounts root)",
     """  die "no live account under $ROOT (BATON_ACCOUNTS_ROOT). baton --status to see dead marks; baton --revive <name> to override\"""",
     """  die "no live account\""""),

    ("M38", "lib/accounts.sh", "auto_launch", "SHARED",
     "drop the user's claude args on the plain launch path",
     """  pick_live "$mode" && launch "$PICKED" "$@\"""",
     """  pick_live "$mode" && launch "$PICKED\""""),

    ("M39", "lib/accounts.sh", "is_dead", "SHARED",
     "drop the empty-guard: a missing dead file reaches [ -gt ] as an empty string",
     """is_dead() { local u; u=$(dead_until "$1"); [ -n "$u" ] && [ "$u" -gt "$(now)" ]; }""",
     """is_dead() { local u; u=$(dead_until "$1"); [ "$u" -gt "$(now)" ]; }"""),

    ("M40", "lib/accounts.sh", "mark_dead_for_class", "NEW",
     "ignore the parsed reset time: every LIMIT takes the 5h fallback",
     """      reset=$(printf '%s' "$text" | parse_reset_epoch)""",
     """      reset=0"""),

    ("M41", "lib/accounts.sh", "is_account", "NEW",
     "accept every name (the guard always says yes)",
     """    [ "$a" = "$1" ] && return 0
  done
  return 1
}""",
     """    [ "$a" = "$1" ] && return 0
  done
  return 0
}"""),

    ("M42", "lib/accounts.sh", "is_uint", "NEW",
     "drop the digit-length cap (arithmetic overflow reachable again)",
     """is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 10 ]; }""",
     """is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }"""),

    ("M43", "lib/watch.sh", "night_knobs", "NEW",
     "drop the BATON_WATCH_INTERVAL validation",
     """  is_unum "$NIGHT_INTERVAL" || die "bad BATON_WATCH_INTERVAL '$NIGHT_INTERVAL' (want seconds, e.g. 5)\"""",
     """  :"""),

    ("M44", "lib/watch.sh", "night_knobs", "NEW",
     "cap validated with the decimal predicate, so 1.5 reaches [ -gt ]",
     """  is_uint "$NIGHT_MAX_HANDOFFS" || die "bad BATON_MAX_HANDOFFS '$NIGHT_MAX_HANDOFFS' (want a whole number, e.g. 3)\"""",
     """  is_unum "$NIGHT_MAX_HANDOFFS" || die "bad BATON_MAX_HANDOFFS '$NIGHT_MAX_HANDOFFS' (want a whole number, e.g. 3)\""""),

    ("M45", "lib/detect.sh", "parse_reset_epoch", "NEW",
     "ignore the message's timezone group (read the clock in local time)",
     """nowt = datetime.datetime.now(resolve_tz(m.group(4)))""",
     """nowt = datetime.datetime.now()"""),

    ("M47", "lib/accounts.sh", "is_unum", "NEW",
     "accept more than one decimal point (1.2.3 reaches sleep as a number)",
     """  case "${1:-}" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac""",
     """  case "${1:-}" in ''|*[!0-9.]*) return 1 ;; esac"""),

    ("M46", "lib/detect.sh", "parse_reset_epoch", "SHARED",
     "a message with no minutes defaults to :30 instead of :00",
     """mi = int(m.group(2) or 0)""",
     """mi = int(m.group(2) or 30)"""),
]


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run_suite():
    t0 = time.time()
    try:
        p = subprocess.run(SUITE, cwd=REPO, capture_output=True, text=True,
                           timeout=SUITE_TIMEOUT)
        out = p.stdout + p.stderr
        code = p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") + "\n[SUITE TIMEOUT]"
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        code = 124
    summary = ""
    fails = []
    for line in out.splitlines():
        if line.startswith("TESTS:"):
            summary = line.strip()
        if line.startswith("FAIL "):
            fails.append(line.strip().split(" -- ")[0][5:])
    return code, summary, fails, time.time() - t0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--list" in sys.argv:
        for m in MUTANTS:
            print(m[0], m[1], m[2], m[4])
        return 0
    selected = [m for m in MUTANTS if not args or m[0] in args]
    if args and len(selected) != len(args):
        sys.stderr.write("unknown mutant id in %r\n" % args)
        return 2

    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                           capture_output=True, text=True).stdout
    tracked_dirty = [l for l in dirty.splitlines()
                     if l[3:].split(" ")[0] in
                     ("baton", "lib/detect.sh", "lib/accounts.sh", "lib/watch.sh")]
    if tracked_dirty:
        sys.stderr.write("refusing to run: production files already modified:\n%s\n"
                         % "\n".join(tracked_dirty))
        return 2

    print("| id | file | function | prov | mutation | verdict | failing tests |")
    print("| -- | ---- | -------- | ---- | -------- | ------- | ------------- |")
    survivors = []
    for mid, rel, func, prov, desc, frm, to in selected:
        path = os.path.join(REPO, rel)
        with open(path, "rb") as fh:
            original = fh.read()
        before_hash = hashlib.sha256(original).hexdigest()
        src = original.decode()
        n = src.count(frm)
        if n != 1:
            print("| %s | %s | %s | %s | %s | **APPARATUS: %d matches, not 1** | - |"
                  % (mid, rel, func, prov, desc, n))
            survivors.append(mid + " (apparatus)")
            continue
        with open(path, "w") as fh:
            fh.write(src.replace(frm, to))
        try:
            code, summary, fails, secs = run_suite()
        finally:
            with open(path, "wb") as fh:
                fh.write(original)
            restored = sha(path) == before_hash
        if not restored:
            sys.stderr.write("FATAL: restore of %s failed; tree may be corrupt\n" % rel)
            return 3
        verdict = "killed" if code != 0 else "**SURVIVED**"
        if code == 124:
            verdict = "killed (suite timeout)"
        if code == 0:
            survivors.append(mid)
        shown = ", ".join(fails[:4]) if fails else ("-" if code == 0 else "(suite failed, no FAIL lines)")
        print("| %s | %s | `%s` | %s | %s | %s | %s |" % (mid, rel, func, prov, desc, verdict, shown))
        sys.stdout.flush()

    print()
    print("mutants run: %d   killed: %d   survived: %d %s"
          % (len(selected), len(selected) - len(survivors), len(survivors),
             ("(" + ", ".join(survivors) + ")") if survivors else ""))
    final = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                           capture_output=True, text=True).stdout
    print("git status --porcelain after run:")
    print(final if final.strip() else "(clean)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
