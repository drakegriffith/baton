# QA-DOC: system-test plan for automatic account failover

Companion to `.ab/DOC.md` and `features/failover.feature`. This is a plan, not
code: it defines the system surface, the fake-`claude` contract, the
module/dependency rules the coder must honor, and the exact assertions each
Gherkin scenario compiles down to. The coder creates `tests/run.sh` (named in
this plan as the focused suite) to execute this plan.

Focused test command: `cd /Users/christopherdrakegriffith/code/baton && bash
tests/run.sh` (does not exist yet -- the coder creates it and everything under
`tests/`).

## 1. System surface

`baton` is a single bash script with no library, no UI, no importable module
boundary today. There is nothing to unit-test in isolation without either (a)
`source`-ing the script, which pulls in argument dispatch and `set -u` side
effects, or (b) driving it as a real subprocess. This plan mandates (b):

**The system surface under test is the `baton` CLI executable, invoked as a
real subprocess, plus the filesystem and process state it reads and writes.**
Concretely, every test observes only:

- **argv/exit code/stdout/stderr** of running `baton <args...>` (and, for the
  `--night` flag, of the whole run until it terminates).
- **Filesystem state** under `$BATON_ACCOUNTS_ROOT` before and after:
  `.tally`, `.last`, `.dead/<name>`, `.alive/<name>`.
- **Transcript files** under `<config-dir-for-account>/projects/<slug>/*.jsonl`,
  which tests create, append to, and inspect.
- **The argv, env, and invocation-order log of every fake `claude` process**
  baton spawns (the fake executable writes its own audit trail; see Section 2).
- **Process tree shape** (parent/child vs. exec-replacement), inspected via
  `ps` for the one scenario that needs it (plain `baton` must still exec).

No test sources `baton` as a bash library, calls an internal function
directly, or asserts on internal variable names. If the coder factors the
script into `lib/*.sh` files (recommended -- see Section 4), those files are
implementation detail; the tests in this plan do not know they exist, except
indirectly through the dependency-isolation tests in Section 6, which observe
*effects* (files touched, messages printed), never source code.

This satisfies the environment constraint in DOC.md: a real limit cannot be
triggered, so every scenario is driven against a **fake `claude` on PATH**
plus **fake account dirs and fake transcripts under a temp root**.

## 2. Fake `claude` executable contract

One fake executable, `tests/fixtures/bin/claude`, placed first on `PATH` for
every test run. Since baton distinguishes accounts only via
`CLAUDE_CONFIG_DIR` (unset for the primary account), the fake must behave
differently per account and per invocation *within a single test run* without
any change to baton's own invocation pattern. Contract:

- On every invocation, the fake claude determines its "account identity" from
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` and reads a per-account behavior
  script from `<that-dir>/.fake-behavior` (a tiny shell-sourceable file the
  test fixture writes before running baton). This is the ONLY thing the fake
  reads from the account dir -- it must never read `.claude.json` or any
  credentials file, mirroring the real constraint that baton itself never
  touches credentials.
- The behavior file tells the fake, per invocation number (invocations are
  counted in `<that-dir>/.fake-invocations`, incremented atomically), what to
  do:
  - print given stdout/stderr text,
  - exit with a given code,
  - optionally create a transcript file at
    `<that-dir>/projects/<slug>/<session-id>.jsonl` before doing anything else
    (so baton's session-id discovery has something to find),
  - optionally block reading `stdin` (simulating the idle interactive case)
    until it receives `SIGTERM`, at which point it exits promptly with a
    fixed code (e.g. 143) so watcher-kill scenarios are fast and deterministic.
- Every invocation appends one line (argv, env's `CLAUDE_CONFIG_DIR`, cwd,
  timestamp) to a single shared log file at `$BATON_ACCOUNTS_ROOT/.fake-claude.log`
  so tests can assert exactly what baton launched, in what order, with what
  `--resume`/`-c` arguments, without depending on baton internals.
- `<slug>` is computed by the test fixture with the same rule DOC.md gives for
  the real CLI (absolute cwd, `/` and `.` replaced by `-`), so fixtures and
  baton agree on where transcripts live.

## 3. Env knobs the spec requires (see failover.feature D7)

| Var | Meaning | Default | Test usage |
|---|---|---|---|
| `BATON_ACCOUNTS_ROOT` | overrides accounts root | `$HOME/.claude-accounts` (unchanged) | every test sets this to a fresh temp dir; never left unset |
| `BATON_WATCH_INTERVAL` | seconds between watcher polls | 5 | tests set small (e.g. `0.2`) for speed |
| `BATON_MAX_HANDOFFS` | handoff cap per run | 3 | tests override to exercise the cap scenario |
| `BATON_SESSION_WAIT_SECS` | max wait for transcript file before falling back to `-c` | 30 | tests override small when exercising the fallback |

None of these change default behavior when unset -- a regression test (below)
runs a plain, pre-existing flag with zero new env vars set (other than
`BATON_ACCOUNTS_ROOT`, which is the one pre-existing knob DOC.md already
grants: "the script already honors `$HOME` for its root") and asserts
byte-identical output to today's script.

## 4. Module dependency rules

The coder should split the script (this plan does not mandate exact filenames,
but the dependency DIRECTION below is a hard requirement, independent of how
files are named):

```
detect      (pure: classify_text(), parse_reset_epoch())
   ^              ^
   |              |
accounts    watch
(state: ranked,   (child process control,
 dead/alive marks, transcript tailing,
 tally, probe())   kill-and-relaunch loop)
   ^              ^
   |              |
   +--- baton (CLI dispatch / orchestration) ---+
```

Rules:

1. **`detect` depends on nothing.** `classify_text(text)` is a pure string ->
   `LIMIT|AUTH|UNKNOWN` function; `parse_reset_epoch` is a pure string ->
   epoch function. Neither touches a file, an account, or a process. This is
   what makes the Section 6 detection-contract test possible as a same-input-
   same-output check usable from two call sites.
2. **`accounts` depends on `detect`**, never the reverse. `probe()` calls
   `classify_text()` on its own captured output; it must not be duplicated.
3. **`watch` depends on `detect`** (classifies transcript lines) **and on
   `accounts`'s public surface only** (`is_dead`, `mark_dead`, `ranked`,
   `probe`) -- never on `accounts`'s private state files directly. `watch`
   must never depend on `detect`less regex copies (no second LIMIT pattern
   anywhere in the codebase).
4. **`watch` never reads credentials.** Its only filesystem reads are: (a)
   transcript JSONL files under `.../projects/<slug>/`, and (b) files it owns
   for its own bookkeeping (e.g. a byte-offset cursor). It never opens
   `.claude.json`, any `credentials*` file, or anything under an account dir
   other than `projects/`. This is a **forbidden dependency**: watch -> raw
   credential files. Section 6 gives a test that fails the moment this edge
   appears.
5. **`baton` (CLI dispatch) depends on `accounts` and `watch`**; existing
   flags (`--status`, `--dead`, `--revive`, `--next`, `--add`, `--probe`,
   forced-account, plain auto-pick) depend on `accounts` only, exactly as
   today, and must not start pulling in `watch` (a forbidden dependency in
   the other direction: existing flags -> watch).
6. **Tests never depend on the real `$HOME/.claude-accounts`.** Every test
   sets `BATON_ACCOUNTS_ROOT` to a fresh temp dir. This is a forbidden
   dependency: test harness -> ambient home directory. Section 6 gives a test
   that fails if a code path ever falls back to the hardcoded default instead
   of honoring the override.

## 5. Scenario -> test mapping

Each row is one executable-in-principle test. "Fixture" = what `tests/run.sh`
sets up before invoking `baton`; "Assert" = what it checks after.

| # | Gherkin scenario | Fixture | Assert |
|---|---|---|---|
| 1 | Interactive limit hit, headline | fake claude for `a` writes transcript, blocks on stdin | append a LIMIT line to the transcript mid-run; assert fake-claude.log shows `a` invoked once then killed (SIGTERM), `.dead/a` has a future epoch, `.fake-claude.log`'s second entry is `b` with `--resume <id>` where `<id>` matches the transcript filename, run's final exit code is whatever the second fake claude for `b` was told to exit with |
| 2 | Reset time missing -> fallback | same as #1 but LIMIT line has no `resets` clause | `.dead/a`'s epoch equals (run start + 5h) within a small tolerance |
| 3 | Headless limit -> rotate | fake claude for `a` exits nonzero with limit text; behavior file makes the NEXT invocation for `a` (baton's post-exit probe) also answer with limit text | `.dead/a` set; `.fake-claude.log` shows exactly 2 invocations of the `a` identity (the original launch + the post-exit probe) before `b` launches |
| 4 | Headless auth -> rotate | same shape, "Not logged in" text | `.dead/a` has `until-epoch auth`-shaped content (1h out); `b` launches |
| 5 | Clean exit, no rotation | fake claude for `a` exits 0; post-exit probe answers "ok" | baton exit code 0; `.dead/a` absent; `.fake-claude.log` has exactly the launch + the probe, never a second launch |
| 6 | Nonzero non-limit exit | same, exit code 7, ordinary text; probe answers "ok" | baton exit code 7; `.dead/a` absent |
| 7 | All accounts limited | both `a` and `b` configured like #3 | baton exit nonzero; stderr contains the "no live account" guidance, naming the resolved accounts root and `BATON_ACCOUNTS_ROOT` (amended post-review: the Gherkin requires the root be named, so the message is no longer byte-identical to the pre-failover one); `.dead/a` and `.dead/b` both present with future epochs |
| 8 | Handoff cap | 3 accounts, `BATON_MAX_HANDOFFS=1`, `a` and `b` both limit like #3 | baton exit nonzero; stderr contains `1` and `BATON_MAX_HANDOFFS`; `.fake-claude.log` has zero entries for `c` |
| 9 | Unrecognized content -> UNKNOWN | fake claude for `a` blocks on stdin; append lines like "Here is the code..." | after `BATON_WATCH_INTERVAL * 3` seconds of polling, `.dead/a` still absent, no SIGTERM sent (fake claude's own log shows it never received one), stderr has no handoff text; THEN fixture makes fake claude exit 0 and asserts final exit code matches |
| 10 | Shared classification (outline) | no process at all -- Section 6 below gives the exact black-box double-check using only `--probe` and a transcript file, no separate "unit test" of an internal function | see Section 6 |
| 11 | Plain baton execs | fake claude for `a` exits 0 | `ps` snapshot taken inside the fake claude process (it writes its own PID and PPID to a file) shows PPID == the PPID baton itself had at launch (proof of `exec`, not fork); no `.fake-claude.log` "killed" marker; no watch-only stderr lines appear |
| 12 | Existing flags outline | none beyond Background | run each flag against current pre-failover behavior fixture and a post-change build; byte-diff stdout/stderr (excluding timestamps) |
| 13 | Watcher never reads credentials | as #1, plus `chmod 000` on `a`'s credentials sentinel file before run | run completes as #1; `stat -f '%m %a'`-equivalent (mtime+atime) on the sentinel file unchanged before/after; `grep -i "permission denied"` against combined stderr log is empty |
| 14 | Real accounts root untouched | run entire suite with real `$HOME` (not overridden) but `BATON_ACCOUNTS_ROOT` overridden | `find $HOME/.claude-accounts -newer <suite-start-marker>` (if that dir exists) returns nothing; if it doesn't exist, it still doesn't exist after |

## 6. The classification-contract test, precisely (dependency-safe, no unit test)

To honor "no internal function calls" while still proving `probe()` and the
watcher use the *same* classification, drive both call sites through the CLI:

1. For each `(text, class)` pair in the outline's Examples table, configure
   fake claude's next `-p` reply to be exactly `text`, run `baton --probe a`,
   and capture `PROBE_CLASS` from its printed `<name> <CLASS>` line.
2. Separately, launch `baton --night` against a blocking fake claude, append
   exactly `text` as one new transcript line, and observe whether a handoff
   happens (LIMIT/AUTH) or nothing happens (UNKNOWN) within one poll interval.
3. Assert step 1's class and step 2's observed behavior agree for every row.
   This is a genuine regression guard against "two drifting copies" of the
   limit regex (the exact failure mode DOC.md calls out) without reading a
   line of implementation.

**Disposition (amended post-review):** `tests/unit/detect_test.sh` sources
`lib/detect.sh` and calls `classify_text` directly, which this section's "no
separate unit test of an internal function" wording did not anticipate. It
stands as an *additive* test: `detect` is the one pure module (no state, no
process, no `set -u`/`ROOT` coupling), so sourcing it costs nothing and buys
rows the black-box path is too coarse to reach (multi-line transcript text,
case-insensitivity). The black-box contract test (scenario 10) remains the
cross-site guard, and the rule stands unchanged for every other file: no test
sources `baton`, `accounts` or `watch`.

## 7. Suite layout the coder creates

```
tests/
  run.sh                    # entry point: bash tests/run.sh
  fixtures/bin/claude       # the fake executable (Section 2)
  fixtures/lib.sh           # shared setup/teardown, temp root, assertions
  scenarios/01-interactive-limit.sh
  scenarios/02-reset-fallback.sh
  ...                       # one file per row in Section 5
```

`tests/run.sh` must: create a fresh temp dir per scenario (never reuse
state across scenarios), export `BATON_ACCOUNTS_ROOT` and `PATH` for that
scenario only, run the scenario, tear down, and report a pass/fail tally with
a nonzero exit if anything failed. It must never write to `$HOME` outside the
temp dir it creates (enforced by scenario 14).
