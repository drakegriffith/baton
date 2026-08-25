# baton

Multi-account launcher for [Claude Code](https://claude.com/claude-code) with
automatic failover when a session hits its usage limit.

You have two (or more) Claude subscriptions. Each one meters usage on its own
server-side clock, and nothing can pool them. What CAN be local is which
account a session launches under, and what happens when the account you are
using runs out mid-session. `baton` handles both:

- **Launch:** `baton` picks a live account (weighted round-robin, liveness
  probe) and starts `claude` under it.
- **Overnight (`baton --night`):** claude runs as a watched child. When the
  account hits its usage limit, baton marks it dead until the parsed reset
  time, kills the idle session, and relaunches the SAME session under the
  next live account with `--resume`. The work keeps going; you read the
  handoff log in the morning.

Each account's limits are fully enforced by Anthropic per account; baton just
moves the baton between subscriptions you already pay for.

## Install

```sh
git clone https://github.com/drakegriffith/baton
cd baton && cp baton lib -R /usr/local/lib/baton 2>/dev/null || true
# or put the checkout on PATH:
ln -s "$PWD/baton" /usr/local/bin/baton
```

Requires: bash 3.2+ (macOS default works), python3, the `claude` CLI.
`lib/` must sit beside the `baton` script (symlinking the script is fine; it
resolves its own path).

## Setup

```sh
baton --add work      # creates ~/.claude-accounts/work
baton work            # opens claude under it; run /login once
baton --add personal  # repeat per account
```

Account layout: each account is a directory under `~/.claude-accounts/<name>`
used as `CLAUDE_CONFIG_DIR`. `--add` symlinks the harness pieces (settings,
skills, hooks, projects, ...) back to your primary `~/.claude` so every
account runs one config and can resume each other's sessions; only
credentials and `.claude.json` stay per-account. If your primary `~/.claude`
should be an account too, symlink it (create the root first on a fresh
machine): `mkdir -p ~/.claude-accounts && ln -s ~/.claude ~/.claude-accounts/a`.

## Use

```sh
baton                   # auto-pick live account, launch claude
baton --night           # launch watched; auto-switch accounts on usage limit
baton -c                # anything baton doesn't recognize passes through to
                        # claude, so this continues your last session
baton <account> [...]   # force one account
baton --next            # mark last account dead 5h, pick another
baton --fast            # auto-pick without the liveness probe
baton --status          # accounts, weights, launches, dead-until
baton --dead [n] [dur]  # mark dead (90m / 5h / 3d)
baton --revive <name>   # clear a dead mark
baton --pickup          # what the last session left behind, as JSON
baton --login <name>    # log an account in, holding the machine-wide login
                        # lock so two OAuth flows can't overlap
baton --locks           # who currently holds which session lock
```

## Picking up after a crash (`baton --pickup`)

A `--night` child is a separate process group. When baton dies underneath it
-- a dropped connection, a closed terminal, a host restart -- the child is
reparented and keeps running, and nothing ever reattaches to it. Logging back
in does not resume it: `/login` only writes credentials, and `claude --resume`
restores a transcript, not a process.

So `--night` writes two receipts per child, under `~/.claude-accounts/.runs/`:
one at launch carrying the pid, the process fingerprint and the command, and
one at exit carrying the code `wait()` returned. `--pickup` reads them back,
re-probes each pid, and prints one JSON board:

| status | what it means | action |
|---|---|---|
| `done` | a completion receipt exists; its exit code is on disk | `none` |
| `orphan-running` | still alive under a matching fingerprint | `monitor` |
| `dead-partial` | started, never finished, pid confirmed gone | `reconcile` |
| `never-started` | no launch was ever recorded | `dispatch` |
| `unknown` | evidence missing or contradictory | `reconcile` |

Exit codes: `0` everything resolved, `1` something needs a decision, `2`
**could not inspect** -- no receipts were readable. A 2 is not a clean board.
A sweep that inspected zero units found nothing because it looked at nothing,
and treating that as success is how a second copy gets launched on top of a
live orphan.

Only `never-started` is safe to re-run automatically. The fingerprint is what
makes `orphan-running` trustworthy: a pid alone can be reused by an unrelated
process, so the recorded start time and command line are matched too.

### Handing a restarted agent the thread

One sentence, and nothing else, goes to an agent picking the work back up:

> Pick up &lt;task&gt;: run `baton --pickup`, act on its projection, spawn the
> forensic reader only where it says `needs_forensics`, then reconcile the
> terminals.

The sentence stays one sentence as the work grows because it carries only the
task name; everything else is reachable by convention from that name, and the
board it points at is size-capped when it is WRITTEN, not when it is read.

Two words in it are load-bearing:

- **projection, not files.** The agent reads the JSON board, not the pile
  behind it. Delegating that read to subagents does not save tokens -- each
  one carries a fixed context prefix of roughly 18k before it opens anything,
  so delegation buys a fresh context window, never a smaller bill. A board
  a script has already reduced is cheaper read directly. Reader subagents are
  the escalation path for `needs_forensics` entries, where a truncated log
  needs judgment about what is salvageable.
- **reconcile, not re-invoke.** Adopt the orphans, redo the dead, hold
  anything that touched the outside world until its effect is verified.
  Blind re-invocation is how a live orphan gets a duplicate.

Give a bigger plan more launches: `echo 3 > ~/.claude-accounts/big/.weight`.

### Night mode knobs (env, all optional)

| Var | Default | Meaning |
|---|---|---|
| `BATON_ACCOUNTS_ROOT` | `~/.claude-accounts` | accounts + state root |
| `BATON_WATCH_INTERVAL` | `5` | seconds between transcript polls |
| `BATON_MAX_HANDOFFS` | `3` | account switches per run before giving up |
| `BATON_SESSION_WAIT_SECS` | `30` | accepted and validated, but inert: the watcher now spots the running session by which transcript file grows, so it never waits for one to appear |

## One writer per session

Every account symlinks `projects/` back into your primary `~/.claude`. That is
the feature -- it is what lets account `b` resume a session account `a`
started. The cost is that a session id is a name *every* account can open, and
`claude` will not stop you opening one twice: it locks git worktrees, OAuth
refresh and its own storage stream, but nothing refuses a second
`--resume <id>`. Do it anyway and one process absorbs the session while the
other dies -- which is what happened here on 2026-08-25, after baton itself
printed two runnable relaunch lines into one terminal and both were run. The
printing is fixed separately; this is the guard that would have refused the
second launch however the two commands arrived.

So baton takes a lock first. Before any launch carrying `--resume <id>` -- the
interactive path, and each `--night` handoff -- it creates
`~/.claude-accounts/.locks/session-<id>/` with `mkdir` (atomic: the loser's
`mkdir` fails, so there is no test-then-write window) and records its own pid
and that pid's start time. A second launch of the same id refuses, names the
pid that holds it, and exits 3 without ever running `claude`:

```
$ baton --resume 0f3c...  # while another one is already open on it
baton: refusing to launch 'session-0f3c...': it is already held by pid 40021,
which is still running. Two processes on one session is what destroys it --
go back to pid 40021, or wait for it to exit. See: baton --locks
```

Because baton `exec`s `claude`, the pid in the lock *is* the claude process,
so the lock lasts exactly as long as the session and needs no cleanup step
that a crash could skip. A holder that died leaves a lock whose pid is gone
(or whose pid has been recycled into a process with a different start time);
either way the next launch reclaims it, so a crash cannot wedge baton.

`baton --locks` reports every lock and how many it inspected. It has three
answers, not two, and the third is the point:

| Exit | Meaning |
|---|---|
| 0 | inspected the lock root, found one or more subjects |
| 1 | inspected the lock root, found **zero** subjects |
| 2 | **could not inspect** -- the lock root is missing or unreadable |

2 is never a pass and never means "nothing is locked". A check that opened
nothing has cleared nothing, and a guard that reports success on a run where
it never executed is worse than no guard.

`baton --login <name>` launches an account holding a single machine-wide
`login` lock, so two `/login` flows can never overlap. They rotate each
other's OAuth refresh token when they do, which is the likeliest cause of the
three-account `auth` cascade this fix came out of; `claude`'s own
`.oauth_refresh.lock` sits next to *one* credentials store and cannot see a
second `CLAUDE_CONFIG_DIR` logging into the same Anthropic account.

Not covered: a cold start and `baton -c`. Neither carries a session id at
launch -- the id only becomes knowable once a transcript grows -- and a lock
keyed on a guess is worse than none.

## How the limit is detected

One shared classifier (`lib/detect.sh`) partitions every observation into
LIMIT / AUTH / UNKNOWN, used both by the launch-time probe and by the night
watcher tailing the session transcript. Unrecognized content is classified
UNKNOWN and never treated as a limit; a probe that cannot decide launches
anyway, because an outage affects every account equally. Reset times like
"resets 2:30pm (America/New_York)" are parsed so a dead mark expires exactly
when the account does.

## Tests

```sh
bash tests/run.sh
```

Hermetic: a fake `claude` on PATH, fake accounts under a temp root. The suite
never touches your real `~/.claude-accounts` or any credentials, and two
tests exist purely to fail if that ever changes.

## Design notes

The probe partition and the watcher's classification are deliberately total:
no outcome falls through silently. Exact remaining-percentage ranking across
accounts would require reading each account's OAuth token; baton never
touches credentials, so it asks the CLI instead and pays a few tokens per
probe. Full rationale lives in the script headers.
