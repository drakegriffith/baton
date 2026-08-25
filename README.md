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
baton <account> [...]   # force one account
baton --next            # mark last account dead 5h, pick another
baton --fast            # auto-pick without the liveness probe
baton --status          # accounts, weights, launches, dead-until
baton --dead [n] [dur]  # mark dead (90m / 5h / 3d)
baton --revive <name>   # clear a dead mark
```

Give a bigger plan more launches: `echo 3 > ~/.claude-accounts/big/.weight`.

### Night mode knobs (env, all optional)

| Var | Default | Meaning |
|---|---|---|
| `BATON_ACCOUNTS_ROOT` | `~/.claude-accounts` | accounts + state root |
| `BATON_WATCH_INTERVAL` | `5` | seconds between transcript polls |
| `BATON_MAX_HANDOFFS` | `3` | account switches per run before giving up |
| `BATON_SESSION_WAIT_SECS` | `30` | accepted and validated, but inert: the watcher now spots the running session by which transcript file grows, so it never waits for one to appear |

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
