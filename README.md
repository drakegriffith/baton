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

## Before you rely on this <!-- DRAFT: Drake decides whether this ships -->

baton launches the official `claude` CLI under accounts you own, one at a
time. It automates two things: which account a session starts under, and
relaunching that session under a different account of yours after one hits
its usage limit. It does not pool usage across accounts, does not share an
account between people, and does not circumvent the per-account metering
Anthropic enforces server-side. You are responsible for checking that
running baton this way fits the terms of each subscription it touches.

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
baton --pick            # print auto-pick's choice only (dead-filter + tally,
                        # no probe, no launch) -- for scripting/checking
baton --probe <name>    # probe one account now, print its class (ALIVE /
                        # LIMIT / AUTH / UNKNOWN), apply the resulting mark
baton --status          # accounts, weights, launches, dead-until
baton --dead [n] [dur]  # mark dead (90m / 5h / 3d)
baton --revive <name>   # clear a dead mark
baton --reset           # zero every account's launch tally
baton --pickup          # what the last session left behind, as JSON
baton --locks           # every lock subject on disk, with state and holder
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

## Only one writer per subject (`--locks`, `--lock-status`, `--claim`, `--redispatch`)

`--pickup` tells a restarted agent what was in flight. It deliberately does not
tell it whether someone else is already acting on that. The board is a
projection: reading it is idempotent by design, which is correct for a
projection and is exactly why the projection cannot be the thing that
arbitrates. Two terminals read the identical board and both re-dispatch the
same unit.

The arbiter is a lock with a **subject**, not a lockfile per feature. A session
id, a run unit and an account's login flow all want the same three things -- an
owner record with enough identity to survive a reboot, a staleness rule that
can reclaim without a human, and a refusal that names the holder -- so they are
one mechanism with a subject argument. The next lockable thing costs a string.

```sh
baton --locks                             # every subject on disk, with state and holder
baton --lock-status session:<id>          # free | held | stale-dead | stale-foreign | could-not-inspect
baton --claim unit:<name> -- <command>    # run the command, or refuse naming the pid that has it
baton --redispatch <unit> -- <command>    # kill the matched orphan, CONFIRM it, then replace it
```

You do not have to ask for it on the interactive path. `baton <account>
--resume <id>`, `baton --fast --resume <id>`, `baton --next --resume <id>` and
plain `baton --resume <id>` all claim `session:<id>` before they hand argv to
`claude`. Only an explicit `--resume` is guarded: a cold start has no session
id yet, and guarding it under a guessed key would serialize unrelated launches
onto one subject.

Five things are worth knowing before you rely on it:

- **A held lock names the pid that holds it.** Refusal is not "try later"; it
  is "pid 4242 is writing this right now". Ask `--lock-status` for the rest.
- **A dead owner never deadlocks a subject.** The owner record carries the
  pid *and* the process start time, so a pid that has exited is reclaimable,
  and a pid that some stranger inherited after a reboot is reclaimable too. A
  bare pid in a lockfile would let that stranger hold the subject forever.
  Start time is also what lets the lock survive `exec`: `baton <account>`
  replaces itself with `claude`, keeps its pid, and keeps its claim.
- **Could-not-inspect is exit 2, and it is not a free lock.** If the process
  table cannot be reached or the lock directory cannot be read, nothing is
  claimed and nothing is reclaimed. An unreachable `ps` would otherwise report
  every live holder as dead, which is precisely how the duplicate this exists
  to prevent gets launched.

- **"I found nothing" and "I could not look" are different answers, and the
  reporter and the acquirer give the same one.** `--locks` exits 0 when it
  found subjects, 1 when it inspected the root and found exactly zero, and 2
  when it could not inspect the root at all. `--lock-status <subject>` counts
  only the subject you named, so its `inspected` is 0 or 1 and can never be
  evidence about the board -- ask `--locks` for that.
- **The lock layer's own exit 2 is marked.** `--claim` returns the guarded
  command's exit code, which can also be 2, so a could-not-inspect from the
  lock layer itself puts `lock-result=could-not-inspect` on stderr. Present
  means nothing ran; absent means the code is the command's own.

`BATON_LOCK_DISABLE=1` turns every claim into a no-op. It exists because a
guard that can strand you with no way through is worse than the failure it
prevents; it is a knob, and the refusal message names it rather than handing
you a command line to paste.

It is not silent, because a bypass nobody can find afterwards is
indistinguishable from a guard that quietly did not work. Every bypassed claim
warns on stderr (every claim, not once per run -- the var is exported, so one
`export` covers a whole night), every receipt written under it carries
`bypassed=yes`, `--lock-status` answers `state=bypassed` rather than `free`,
and a line lands in `<lock root>/bypass.log`.

One cost of the login subject, stated because it will be noticed: it is
global, not per-account. The issue this came from says serialize login flows
"one at a time", and baton cannot see the `/login` you type inside the session
it launched, so it treats every `baton <account>` as one. Two forced launches
on different accounts therefore cannot run at once. The auto-pick paths
(`baton`, `baton --fast`) are unaffected.

The evidence layer never depends on the claim layer: `--pickup` works with no
lock root present at all, and never creates one.

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

## License

MIT, see LICENSE.
