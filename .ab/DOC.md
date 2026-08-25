# Story: automatic account failover when a running session hits its usage limit

## The human request (Drake, 2026-08-24, verbatim)

"We currently have a feature where I type CCX, and it takes from the Claude
account that has the most credits. But what I want the system to do is,
whenever I'm working overnight, instead of saying that it hit my session
limit, I want it to automatically switch to the other account."

The tool has been renamed ccx -> baton (done, base commit). This story is
ONLY the failover feature. Publishing/README/night-night integration are out
of scope for this story.

## Facts about the environment (constraints, not design)

- `baton` (repo root) currently selects an account only at launch time:
  probe classes ALIVE / LIMIT / AUTH / UNKNOWN, dead-marks with reset-time
  parsing, then `launch()` ends in `exec ... claude "$@"` so baton leaves the
  process tree and can never observe the session again. That exec is the gap
  this story closes.
- Accounts live under `~/.claude-accounts/<name>`, selected via
  CLAUDE_CONFIG_DIR (primary account must launch with the var UNSET; see the
  measured note in the script header). Non-primary accounts symlink the
  harness including `projects/` back into `~/.claude`, so ANY account can
  resume a session started by another account. `claude --resume <session-id>`
  and `claude -c` (continue most recent session in cwd) are the resume
  surfaces.
- Headless mode (`claude -p ...`): on a usage limit the CLI prints a message
  matching the same family probe() already parses ("hit your ... limit",
  "usage limit", "limit reached", often with "resets <time>") and EXITS.
- Interactive mode: on a usage limit the CLI shows the limit message and the
  PROCESS STAYS ALIVE waiting for input. Overnight nobody is typing, so the
  session just sits there. Claude Code appends every session event to a
  transcript JSONL at `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`
  (cwd-slug = absolute cwd with `/` and `.` replaced by `-`). The EXACT text
  a limit event leaves in the transcript is UNVERIFIED; the detection
  contract must therefore be a total partition like probe()'s, where
  unrecognized content is classified, never silently dropped, and the limit
  regex family is one shared definition, not two drifting copies.
- A real limit cannot be triggered in tests. Tests must drive the tool
  against a fake `claude` executable placed first on PATH plus fake account
  dirs and fake transcripts under a temp HOME-like root. The script already
  honors `$HOME` for its root; tests may need an env override for the
  accounts root and for timing knobs.

## Desired behavior

1. A new failover mode (flag name is the specifier's call, e.g.
   `baton --night` or `baton run`) launches claude as a CHILD instead of
   exec, under the auto-picked account.
2. While the child runs, baton watches for a usage-limit hit:
   - child exits and its account probes/reports LIMIT, or
   - the session transcript gains a limit-classified event while the child
     is still alive (the unattended interactive case).
3. On a limit hit: mark that account dead until its parsed reset time
   (existing mechanism), pick the next live account, and relaunch the SAME
   session there (`--resume <session-id>`, falling back to `-c`), so the
   overnight work continues instead of stopping. Announce each handoff on
   stderr.
4. The loop ends when: the child exits without a limit (normal quit -> exit
   with the child's code), or no live account remains (-> die with the
   existing "no live account" guidance, non-zero).
5. Runaway protection: a bounded number of handoffs per run (small default,
   env-overridable) so two exhausted accounts cannot ping-pong kill/relaunch
   all night.
6. Existing behaviors (launch-time pick, probes, --status, --dead, --revive,
   --next, --add, forced account) are unchanged; plain `baton` still execs.

## Acceptance sketch (make these real scenarios)

- Overnight interactive session hits limit -> baton kills the idle child,
  marks the account dead with the parsed reset time, relaunches the same
  session id under the next account, and the session keeps going.
- Headless child exits with a limit message -> same rotation.
- Child exits cleanly -> baton exits with the same code, no rotation.
- All accounts limited -> non-zero exit, "no live account" message, dead
  marks all carry reset times.
- Handoff cap reached -> non-zero exit naming the cap and the env override.
- Unrecognized transcript content -> classified (UNKNOWN), never treated as
  a limit, never crashes the watcher.
