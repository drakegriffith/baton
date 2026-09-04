#!/usr/bin/env bash
# observe -- WHERE the wave-wake observer supervisor lives and HOW to invoke
# it. Nothing here starts, watches or kills anything; it answers two questions
# (which file, which argv) for the two callers that ask them: watch.sh's
# night_observer_start, which spawns it alongside a night lane, and `baton
# --observe`, which runs the same command in the foreground for a terminal
# launched without PATHWAY_*.
#
# One file rather than a helper inside watch.sh, because --observe must NOT
# source watch.sh: a read-only "run the observer here" command must not be
# able to start a claude child (the same forbidden direction QA-DOC section 4
# rule 5 draws for the existing flags, and the reason --pickup keeps its
# distance too).
#
# THE MECHANISM IS NOT BATON'S. pathway's supervisor holds its own kernel
# flock inside the run dir and elects the one active process itself, so
# running one per terminal is correct and baton adds NO lock of its own. A
# second claim layer here would be a second staleness rule over the same
# fact, and the two would disagree at exactly the moment one of them matters.

# observe_target -- the supervisor to run. BATON_WAVE_WAKE_TARGET is a test
# seam, not an operator knob: it exists so the suite can pin a fake target and
# never depend on pathway being installed on the machine running it.
observe_target() { printf '%s\n' "${BATON_WAVE_WAKE_TARGET:-$HOME/code/pathway/pathway/wave_wake.py}"; }

# observe_argv RUN_DIR -> OBSERVE_ARGV, the exact command both callers run:
#   PYTHONPATH=<repo root> <target> observe --supervise --run-dir D --interval N
# Repo root is dirname(dirname(target)) -- the package lives one level under
# it, so that is the path that makes `import pathway` resolve.
#
# Spelled with `env` rather than an assignment prefix so the array IS the
# whole command: the background spawn needs $! to be the supervisor's own pid
# (env exec's it, keeping the pid), and the foreground path needs one exec.
#
# The interval is a constant, not a knob. A knob costs a validation rule and a
# reader, and night_knobs is where any --night knob has to be resolved once
# before a child launches; nothing yet asks for a second number here.
OBSERVE_INTERVAL=60
observe_argv() {
  local target root
  target=$(observe_target)
  root=$(dirname "$(dirname "$target")")
  OBSERVE_ARGV=(env "PYTHONPATH=$root" "$target" observe --supervise --run-dir "$1" --interval "$OBSERVE_INTERVAL")
}

# observe_main ARG -- the `baton --observe` body. ARG is a bare run id or a
# path: anything containing a slash is taken as written, a bare id resolves
# under the wave-wake state root. The directory must exist AND hold run.json,
# because "a directory that exists" is not evidence that it is a run -- a
# typo'd id that happens to name some other directory would otherwise start a
# supervisor over a run dir with nothing in it.
observe_main() {
  local arg="${1-}" dir target
  [ -n "$arg" ] || die "--observe <run-id-or-dir>"
  case "$arg" in
    */*) dir="$arg" ;;
    *)   dir="${CLAUDE_STATE_DIR:-$HOME/.claude/state}/wave-wake/$arg" ;;
  esac
  [ -d "$dir" ] && [ -f "$dir/run.json" ] \
    || die "--observe: '$dir' is not a wave-wake run directory (no run.json)"
  target=$(observe_target)
  [ -f "$target" ] || die "--observe: no observer at $target"
  observe_argv "$dir"
  exec "${OBSERVE_ARGV[@]}"
}
