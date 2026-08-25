# HARDEN.md -- seat 4 (hardener) on the failover story

Subject: the diff from `173fd9e` (import) through `2f26c2f` (seat 3) --
`baton`, `lib/detect.sh`, `lib/accounts.sh`, `lib/watch.sh`.
Suite: `bash tests/run.sh`. Baseline inherited from seat 3: `TESTS: 27
PASS: 27  FAIL: 0`.

Three things were done, in this order: mutation testing (what does the suite
actually notice?), adversarial input probing (what happens at each boundary
the diff touches?), and a complexity/CRAP read (what is hard to be sure
about?). Sections 1-3. Section 4 is the revert audit.

---

## 0. Why the mutation-tests skill's scripts are not the apparatus here

`~/.claude/skills/mutation-tests/` was tried first, as instructed, and it
cannot inspect this repo. Both of its entry points were run and both said
so; the outputs are pasted rather than summarised, because "the tool was
run" is not the same claim as "the tool inspected something".

`mutate.py`, the engine, on the file with the smallest function in the diff:

```
$ python3 ~/.claude/skills/mutation-tests/mutate.py --file lib/detect.sh \
      --function classify_text --emit /tmp/mut-trial
mutate.py: unsupported language for lib/detect.sh (python, js, ts only)
$ echo $?
2
```

Exit 2 is that script's own "could not run ... Never treat 2 as a pass".

`changed_functions.py`, the enumerator `crap-check.sh` drives, over the exact
story range:

```
$ python3 ~/.claude/skills/mutation-tests/changed_functions.py \
      --repo . --base 173fd9e --head HEAD
  "counts": {"files_changed": 26, "code_files": 0, "non_code": 26,
             "deleted": 0, "unsupported": 0, "unparsed": 0},
  "functions_found": 0,
  "functions": [],
  "skipped": [... {"file": "baton", "reason": "non_code"},
                  {"file": "lib/accounts.sh", "reason": "non_code"},
                  {"file": "lib/detect.sh", "reason": "non_code"},
                  {"file": "lib/watch.sh", "reason": "non_code"} ...]
$ echo $?
0
```

Exit 0 with `functions_found: 0`. Every shell file in the diff is classified
`non_code`, so `crap-check.sh` driven off this enumeration would inspect zero
subjects and exit 0 -- a green verdict from a gate that looked at nothing.
That is the failure this repo's own doctrine names: a gate that inspected
zero subjects has not passed.

So the apparatus here is `.ab/mutation-run.py`, written for this run and
committed alongside this file, keeping the same discipline the skill
enforces: one behaviour-changing edit at a time, inside one named function,
the repo's own suite as the test, and the file restored from an in-memory
byte copy and re-verified by sha256 after every single mutant (a restore
mismatch aborts the whole run instead of continuing on a corrupted tree).
It also refuses to start when any of the four production files is already
modified, so a mutant can never be stacked on a dirty tree -- that refusal
fired once during this run, when the hardening edits were still uncommitted,
and the run was redone after committing them.

Re-derive any number below with:

```
python3 .ab/mutation-run.py            # all mutants, prints the table
python3 .ab/mutation-run.py M09 M26    # just these
python3 .ab/complexity.py              # the complexity table
```

---

## 1. Mutation testing

**Enumerator.** 47 mutants, each an exact literal replacement inside one
named function: operator flips (`-gt`/`-lt`/`-ge`, `<=`/`>=`, `-n`/`-z`),
boundary shifts (`% 12` -> `% 24`, `* 3600` -> `* 60`), dropped conditions
(`LIMIT|AUTH` -> `LIMIT`, guards deleted), dropped steps (the ALIVE-cache
removal, the handoff increment, the `.last` write), reordered steps
(LIMIT/AUTH precedence), swapped identifiers (`ranked` sort direction,
SIGTERM -> SIGKILL, `is_uint` -> `is_unum`) and swapped exit codes (the
child's real code -> 0). Every changed function in the diff carries at least
one mutant; the count per function is in the CRAP table in section 3.

`prov` column: NEW = introduced by this story, SHARED = code that existed at
`173fd9e` but that the story put under a new caller (`--night`), so its
behaviour is now load-bearing for a path that did not exist before.

**Round 1** (against seat 3's tree, `2f26c2f`, 35 mutants -- the other 11
target code that did not exist yet):

    mutants run: 35   killed: 21   survived: 14
    survivors: M01 M04 M05 M06 M08 M11 M15 M17 M25 M26 M31 M32 M35 M36

**Round 2** (against the hardened tree, all 47 -- M47 was added after the
round started, so it was run in the same way immediately afterwards and its
row is appended to the same table): see the table below.

### Round 2 table (all 47 mutants)

| id | file | function | prov | mutation | verdict | failing tests |
| -- | ---- | -------- | ---- | -------- | ------- | ------------- |
| M01 | lib/detect.sh | `classify_text` | NEW | reorder: AUTH tested before LIMIT (precedence flip) | killed | unit:classify_text:auth-phrase-first |
| M02 | lib/detect.sh | `classify_text` | NEW | drop case-insensitivity from the LIMIT regex (-qiE -> -qE) | killed | unit:classify_text:multiline-json-line |
| M03 | lib/detect.sh | `classify_text` | NEW | swap the total-partition fallback: UNKNOWN -> AUTH | killed | unit:classify_text:ordinary-chatter, unit:classify_text:empty-string, unit:classify_text:limit-word-not-alone, unit:classify_text:whitespace-only |
| M04 | lib/detect.sh | `parse_reset_epoch` | SHARED | boundary flip: already-passed test `t <= nowt` -> `t >= nowt` | killed | unit:parse_reset_epoch:one-hour-ahead-is-today, unit:parse_reset_epoch:one-hour-past-rolls-to-tomorrow, unit:parse_reset_epoch:noon-boundary-1230pm, unit:parse_reset_epoch:midnight-boundary-1215am |
| M05 | lib/detect.sh | `parse_reset_epoch` | SHARED | drop the roll-to-tomorrow step for an already-passed reset time | killed | unit:parse_reset_epoch:one-hour-past-rolls-to-tomorrow, unit:parse_reset_epoch:midnight-boundary-1215am |
| M06 | lib/detect.sh | `parse_reset_epoch` | SHARED | 12-hour wrap boundary: `% 12` -> `% 24` (breaks 12:xxpm/12:xxam) | killed | unit:parse_reset_epoch:noon-boundary-1230pm |
| M07 | lib/accounts.sh | `parse_duration` | SHARED | unit swap: `5h` parsed as 5*60 instead of 5*3600 | killed | 02-reset-fallback, 15-adversarial-durations |
| M08 | lib/accounts.sh | `parse_duration` | SHARED | drop the malformed-duration rejection (bad input reaches the arithmetic) | killed | 15-adversarial-durations |
| M09 | lib/accounts.sh | `mark_dead_for_class` | NEW | operator flip: parsed reset accepted only when in the PAST (-gt -> -lt) | killed | 02-reset-fallback, 07-exhaustion, 20-parsed-reset-honored |
| M10 | lib/accounts.sh | `mark_dead_for_class` | NEW | AUTH dead duration 3600s -> 7200s | killed | 04-headless-auth-rotate |
| M11 | lib/accounts.sh | `mark_dead` | SHARED | dropped step: a dead mark no longer invalidates the ALIVE cache entry | killed | 16-dead-mark-invalidates-alive-cache |
| M12 | lib/accounts.sh | `ranked` | SHARED | ranking order reversed: `sort -n` -> `sort -rn` (busiest account first) | killed | 01-interactive-limit-headline, 02-reset-fallback, 03-headless-limit-rotate, 04-headless-auth-rotate |
| M13 | lib/accounts.sh | `probe` | NEW | drop the canary check: any UNKNOWN probe reply is reported ALIVE | killed | 10-classification-contract-outline, 23-unknown-probe-launches-anyway |
| M14 | lib/accounts.sh | `set_envargs` | NEW | swap the primary/non-primary branches (CONFIG_DIR + ENVARGS both) | killed | 01-interactive-limit-headline, 03-headless-limit-rotate, 04-headless-auth-rotate, 07-exhaustion |
| M15 | lib/accounts.sh | `pick_live` | NEW | UNKNOWN probe result skips the account instead of launching anyway | killed | 23-unknown-probe-launches-anyway |
| M16 | lib/accounts.sh | `alive_fresh` | SHARED | freshness comparison inverted (-lt -> -gt): cache never trusted | killed | 02-reset-fallback, 03-headless-limit-rotate, 06-nonzero-exit-no-rotation, 08-handoff-cap |
| M17 | lib/accounts.sh | `bump` | SHARED | dropped step: last-used account no longer recorded | killed | 22-last-used-tracking |
| M18 | lib/accounts.sh | `launch` | SHARED | exec -> fork+wait (plain baton grows an extra process generation) | killed | 11-plain-baton-execs, 12-existing-flags-outline, 23-unknown-probe-launches-anyway |
| M19 | lib/accounts.sh | `pick_live` | NEW | drop the BATON_EXCLUDE pass-through from ranked() | killed | 21-baton-exclude-regression |
| M20 | lib/watch.sh | `find_new_jsonl` | NEW | membership test inverted: returns a PRE-EXISTING transcript, not the new one | killed | 02-reset-fallback, 10-classification-contract-outline, 13-watcher-never-reads-credentials, 20-parsed-reset-honored |
| M21 | lib/watch.sh | `run_watched` | NEW | session id blanked on a live-transcript rotation (forces -c instead of --resume) | killed | 01-interactive-limit-headline, 24-cwd-with-dot-in-name |
| M22 | lib/watch.sh | `run_watched` | NEW | post-exit probe: dropped condition, AUTH no longer rotates | killed | 04-headless-auth-rotate |
| M23 | lib/watch.sh | `run_watched` | NEW | live transcript: dropped condition, AUTH line no longer kills the child | killed | 10-classification-contract-outline |
| M24 | lib/watch.sh | `run_watched` | NEW | signal swap: SIGTERM -> SIGKILL (child loses its chance to clean up) | killed | 01-interactive-limit-headline, 10-classification-contract-outline, 24-cwd-with-dot-in-name |
| M25 | lib/watch.sh | `transcript_dir_for` | NEW | slug rule: only `/` replaced, `.` left intact | killed | 24-cwd-with-dot-in-name |
| M26 | lib/watch.sh | `night_mode` | NEW | handoff cap off-by-one (-gt -> -ge): cap N allows only N-1 handoffs | killed | 08-handoff-cap |
| M27 | lib/watch.sh | `night_mode` | NEW | handoff counter never incremented (cap unreachable) | killed | 08-handoff-cap |
| M28 | lib/watch.sh | `night_mode` | NEW | exit-code swap: child's real code replaced by 0 | killed | 01-interactive-limit-headline, 06-nonzero-exit-no-rotation, 19-arg-passthrough |
| M29 | lib/watch.sh | `night_mode` | NEW | resume-mode test inverted (-n -> -z): known session id forces -c | killed | 01-interactive-limit-headline, 24-cwd-with-dot-in-name |
| M30 | lib/watch.sh | `run_watched` | NEW | give-up flag test inverted: session discovery never runs | killed | 02-reset-fallback, 10-classification-contract-outline, 13-watcher-never-reads-credentials, 20-parsed-reset-honored |
| M31 | lib/watch.sh | `run_watched` | NEW | growth test relaxed (-gt -> -ge): unchanged file re-read every poll | **SURVIVED** | - |
| M32 | baton | `dispatch --probe` | SHARED | drop the account-exists guard on --probe | killed | 17-account-name-boundary |
| M33 | baton | `dispatch --pick` | SHARED | --pick prints two candidates instead of one | killed | 12-existing-flags-outline, 21-baton-exclude-regression |
| M34 | baton | `dispatch empty-accounts guard` | SHARED | empty-accounts guard condition flipped (-eq 0 -> -gt 0) | killed | 01-interactive-limit-headline, 02-reset-fallback, 03-headless-limit-rotate, 04-headless-auth-rotate |
| M35 | baton | `dispatch --dead` | SHARED | drop the re-raise of parse_duration's die (subshell failure swallowed) | killed | 15-adversarial-durations |
| M36 | baton | `dispatch --night` | NEW | --night no longer shifts its own flag off the claude args | killed | 19-arg-passthrough |
| M37 | lib/accounts.sh | `die_no_live_account` | NEW | reword the exhaustion message the operator is told to act on | killed | 07-exhaustion |
| M38 | lib/accounts.sh | `auto_launch` | SHARED | drop the user's claude args on the plain launch path | killed | 16-dead-mark-invalidates-alive-cache, 19-arg-passthrough, 23-unknown-probe-launches-anyway |
| M39 | lib/accounts.sh | `is_dead` | SHARED | drop the empty-guard: a missing dead file reaches [ -gt ] as an empty string | killed | 12-existing-flags-outline |
| M40 | lib/accounts.sh | `mark_dead_for_class` | NEW | ignore the parsed reset time: every LIMIT takes the 5h fallback | killed | 20-parsed-reset-honored |
| M41 | lib/accounts.sh | `is_account` | NEW | accept every name (the guard always says yes) | killed | 11-plain-baton-execs, 16-dead-mark-invalidates-alive-cache, 17-account-name-boundary, 19-arg-passthrough |
| M42 | lib/accounts.sh | `is_uint` | NEW | drop the digit-length cap (arithmetic overflow reachable again) | killed | 15-adversarial-durations |
| M43 | lib/watch.sh | `night_knobs` | NEW | drop the BATON_WATCH_INTERVAL validation | killed | 18-night-env-knobs |
| M44 | lib/watch.sh | `night_knobs` | NEW | cap validated with the decimal predicate, so 1.5 reaches [ -gt ] | killed | 18-night-env-knobs |
| M45 | lib/detect.sh | `parse_reset_epoch` | NEW | ignore the message's timezone group (read the clock in local time) | killed | unit:parse_reset_epoch:one-hour-ahead-is-today, unit:parse_reset_epoch:one-hour-past-rolls-to-tomorrow, 20-parsed-reset-honored |
| M46 | lib/detect.sh | `parse_reset_epoch` | SHARED | a message with no minutes defaults to :30 instead of :00 | killed | unit:parse_reset_epoch:no-minutes-means-zero |
| M47 | lib/accounts.sh | `is_unum` | NEW | accept more than one decimal point (1.2.3 reaches sleep as a number) | killed | 18-night-env-knobs |

    mutants run: 47   killed: 46   survived: 1 (M31, equivalent -- proof below)
    apparatus: every literal matched exactly once; every restore verified by sha256


### The 14 round-1 survivors, and what kills each one now

| mutant | what it changed | why nothing noticed | test added |
| ------ | --------------- | ------------------- | ---------- |
| M01 | `classify_text` tests AUTH before LIMIT | no fixture line carried both families of phrase, so the precedence was never exercised | `unit:classify_text:limit-and-auth-one-line`, `:auth-phrase-first` |
| M04 | `t <= nowt` -> `t >= nowt` | every reset fixture was a fixed clock time asserted only as "nonzero" / "in the future" | `unit:parse_reset_epoch:one-hour-ahead-is-today`, `:one-hour-past-rolls-to-tomorrow` |
| M05 | the roll-to-tomorrow step deleted | same | same two rows (the past-time row goes negative without it) |
| M06 | `% 12` -> `% 24` | no fixture used a 12:xx time, the one hour where the modulo matters | `unit:parse_reset_epoch:noon-boundary-1230pm`, `:midnight-boundary-1215am` |
| M08 | `parse_duration` stops rejecting malformed input | scenario 12 only ever passes `90m` | scenario 15 (8 malformed durations) |
| M11 | `mark_dead` stops clearing the ALIVE cache entry | `ranked` filters dead accounts anyway, so the stale entry only matters AFTER the mark expires -- which no test spanned | scenario 16 |
| M15 | UNKNOWN probe result skips the account instead of launching | scenario 10 pins what `--probe` PRINTS for unknown text, not what `pick_live` DOES with it | scenario 23 |
| M17 | `bump` stops writing `.last` | scenario 12 gives each invocation a fresh root, so old and new baton both read an empty `.last` and agree | scenario 22 |
| M25 | slug rule replaces `/` but not `.` | every other scenario runs from a checkout path with no dot in it | scenario 24 (runs `--night` from `my.project.v2/`) |
| M26 | handoff cap `-gt` -> `-ge` (cap N allows N-1) | scenario 8 asserts the cap trips and that the third account is untouched; both hold when the cap trips one handoff too early | scenario 8, two added checks (b must have run) |
| M31 | growth test `-gt` -> `-ge` | **equivalent mutant** -- see below | none (excluded from the denominator) |
| M32 | `--probe` stops checking the account exists | nothing exercised `--probe` with a bad name | scenario 17 |
| M35 | `--dead` stops re-raising `parse_duration`'s die | the die message still prints (from the subshell), and no test asserted the exit code or the absence of a raw arithmetic error | scenario 15 (exit code + no-shell-error-leak checks) |
| M36 | `--night` stops shifting its own flag off the args | no test asserted what argv reaches claude | scenario 19 |

**M31 is an equivalent mutant, with proof.** `[ "$size" -gt "$offset" ] ||
continue` guards a read of the bytes appended since the last poll. With
`-ge`, the one extra case reached is `size == offset`, which then runs
`tail -c "+$((offset + 1))"` on a file that is exactly `offset` bytes long:

```
$ printf 'abcd' > tf; tail -c +5 tf | wc -c
       0
```

Zero bytes, so the `while read` body never executes and `offset="$size"` is a
no-op. The two versions differ only in wasted work, never in an observable
decision, so no test can distinguish them. It is counted as equivalent, not
as a survivor -- and it is left in the table rather than deleted, so the
claim can be checked.

**Final: 47 mutants, 46 killed, 1 equivalent, 0 survivors.**

---

## 2. Adversarial inputs

Every boundary the diff touches, probed by hand before any fix, with the
observed behaviour recorded. "Fails INTO the contract" means baton's own
`die`/`warn` path with a nonzero exit and no corrupt state left behind;
"fails PAST it" means the input got through and something else broke.

### 2.1 Durations (`--dead <dur>`, `parse_duration`)

| input | observed BEFORE | disposition |
| ----- | --------------- | ----------- |
| `abc`, `5x` | `baton: bad duration ...`, exit 1 | already contracted |
| `-5h` | **exit 0**, "dead until <a time in the past>", mark written and inert | FIXED -- `is_uint` rejects the leading `-` |
| `12.5h` | exit 0, `$(( 12.5 * 3600 ))` -> shell error, mark half-written | FIXED |
| `1e3m` | exit 1 but with a raw `lib/accounts.sh: line 44: 1e3: value too great for base` at the operator | FIXED -- baton's own message now |
| `99999999999999999999h` | **exit 0**, arithmetic overflow, `date: invalid time`, "dead until " with an empty date | FIXED -- 10-digit cap |
| `5 h` | exit 0, silently parsed as 5h | FIXED -- refused (the space is not a digit) |
| `0` | exit 0, dead-until == now, i.e. not dead | already contracted (a zero-second mark is a no-op by construction, and the message states the time) |
| `` (empty) | falls back to the documented 5h default | already contracted -- that is what `${3:-$DEFAULT_DEAD}` means |
| `300` (bare seconds) | 300s | already contracted |

### 2.2 Account names (`--probe`, `--dead`, `--revive`, forced launch)

The account list is enumerated with `"$ROOT"/*/`, which never matches a
dotted name. Every name-taking path used `[ -d "$ROOT/$name" ]` instead,
which is a different and much larger set.

| input | observed BEFORE | disposition |
| ----- | --------------- | ----------- |
| `--probe nosuch` | dies "--probe <account>", exit 1 | already contracted |
| `--probe ..` | **probed**, `CLAUDE_CONFIG_DIR` one level ABOVE the accounts root, and printed `rm: "." and ".." may not be removed` from the mark cleanup | FIXED -- `is_account` |
| `--probe .alive` | **probed the alive-cache directory as an account** (`.alive ALIVE`) | FIXED |
| `--dead .alive 90m` | **exit 0**, dead mark written for the state directory | FIXED |
| `--revive nosuch` | exit 0, "revived" (no check at all) | FIXED -- "no account", exit 1 |
| `--revive ../a` | **exit 0**, ran `rm -f "$ROOT/.dead/../a"`, i.e. deleted the primary account's SYMLINK | FIXED -- the destructive one |
| `baton .alive` (forced launch) | launched claude with the state dir as its config dir | FIXED -- a non-account first arg is now claude's argument, as it always was for any other non-account word |
| `a/b`, `a b`, `-x`, `` | refused | already contracted |

### 2.3 `--night` env knobs

| input | observed BEFORE | disposition |
| ----- | --------------- | ----------- |
| `BATON_WATCH_INTERVAL=abc` | **`sleep abc` failed on every poll**: measured 87,132 bytes of shell usage errors on stderr in 3 seconds and ~12% CPU on an idle machine, for the length of the run | FIXED -- dies before launching a child |
| `BATON_WATCH_INTERVAL=-1`, `1.2.3` | same class of failure | FIXED |
| `BATON_WATCH_INTERVAL=0` | `sleep 0` per poll: a hot loop, but no error and exactly what was asked for | accepted, documented (not a contract violation) |
| `BATON_WATCH_INTERVAL='0.2; touch /tmp/PWNED'` | refused by the value check; and it never was an injection risk -- `sleep "$interval"` is quoted, `/tmp/PWNED` was never created | already contracted, now also refused earlier |
| `BATON_MAX_HANDOFFS=abc` | **`[ 1 -gt abc ]` leaked `lib/watch.sh: line 156: [: abc: integer expression expected` and then answered false forever** -- the cap silently stopped existing, so the run rotated until accounts ran out | FIXED |
| `BATON_MAX_HANDOFFS=1.5` | same leak (a decimal never reaches `[ -gt ]` cleanly) | FIXED -- `is_uint`, not `is_unum` |
| `BATON_MAX_HANDOFFS=0` / `-1` | dies "handoff cap (0) reached" on the first rotation -- honest, and 0 is a meaningful value | 0 accepted; `-1` now refused |
| `BATON_MAX_HANDOFFS=` (empty) | 3, the documented default | already contracted |
| `BATON_SESSION_WAIT_SECS=abc` | **silent**: the awk give-up comparison compares a number against a string, never fires, so the documented `--resume` -> `-c` fallback stopped existing and the watcher waited forever for a transcript | FIXED |
| `BATON_SESSION_WAIT_SECS=0` | valid boundary: never wait, always fall back to `-c` | already contracted, now pinned by scenario 18 |
| `BATON_EXCLUDE=a` | **silently ignored** -- the knob worked at `173fd9e` and was dropped when `pick_live` was extracted from `auto_launch` | FIXED (restored) + scenario 21 |

### 2.4 Transcript lines and reset strings (`classify_text`, `parse_reset_epoch`)

| input | observed | disposition |
| ----- | -------- | ----------- |
| empty line, `   `, a lone tab | UNKNOWN | already contracted (total partition), now pinned |
| 20,000-character line | UNKNOWN, no error | already contracted, now pinned |
| a line carrying BOTH a limit phrase and an auth phrase | LIMIT (first test wins) | already contracted; the precedence is now a stated, tested promise |
| `resets 25:99pm`, `resets 9 (UTC)`, `12345`, whitespace | 0 -> caller uses the 5h fallback | already contracted, now pinned |
| `resets 9pm (Mars/Phobos)`, `resets 9pm (` | unknown/unterminated zone falls back to local time, clock time still used | already contracted, now pinned and now stated in `resolve_tz` |
| `resets 12:30pm (UTC)` | noon-thirty (not hour 24) | already contracted, now pinned |
| a line torn across a poll boundary (half written when the watcher reads) | the two fragments each classify UNKNOWN, so that one line is missed | **known bounded gap, not fixed.** The offset advances past the fragment, so the line is lost -- but the failover is delayed, not lost: when the child exits, `run_watched`'s post-exit probe re-asks the CLI and rotates on LIMIT/AUTH (the D5 path, scenario 03). Fixing it means not advancing the offset past an unterminated tail, inside the function that is already the most complex in the tree; the trade was judged not worth it and is recorded here instead of being silently skipped. |

---

## 3. Complexity and CRAP

There is no McCabe counter for bash on this machine (section 0), so the
counting rule is stated and applied mechanically by `.ab/complexity.py`
rather than eyeballed:

> CC = 1 + one per `if`/`elif` + one per `while`/`until`/`for` + one per
> `case` pattern arm (`a|b)` counts 2, a bare `*)` catch-all counts 0) + one
> per `&&`/`||`. Comments and quoted text are excluded. The python program
> embedded in `parse_reset_epoch` is counted as its own units, with `except`,
> `and`, `or` added to the rule.

CRAP uses the mutation-based form `crap-check.sh` documents:
`comp^2 * (1 - kill_ratio)^3 + comp`, kill ratio measured per function from
section 1's table. Every function that has a mutant has a kill ratio of 1.0
(with M31 excluded from its denominator as an equivalent mutant), so the
coverage penalty term is zero for all of them and CRAP equals CC -- which is
the point of measuring both: nothing here is complex AND unwatched. The
three functions with no mutant are the three the story did not touch; they
get a CC and no CRAP, because a coverage claim with no measurement behind it
is a guess wearing a number.

| function | file | CC | mutants | killed | CRAP | disposition |
| -------- | ---- | -- | ------- | ------ | ---- | ----------- |
| `classify_text` | detect.sh | 3 | 3 | 3 | 3 | ok |
| `parse_reset_epoch` (shell) | detect.sh | 2 | 5 for the function as a whole | 5 | 2 | ok |
| `parse_reset_epoch` py: `resolve_tz` | detect.sh | 4 | (M45) | 1 | 4 | **the program was 9 as one piece** -- the timezone lookup is now its own unit (see below) |
| `parse_reset_epoch` py: main | detect.sh | 6 | (M04 M05 M06 M46) | 4 | 6 | ok |
| `is_uint` | accounts.sh | 3 | 1 | 1 | 3 | new |
| `is_unum` | accounts.sh | 5 | 1 | 1 | 5 | new |
| `is_account` | accounts.sh | 3 | 1 | 1 | 3 | new |
| `count_of` | accounts.sh | 1 | 0 | -- | -- | not in the diff: no mutant, so no coverage claim is made for it |
| `weight_of` | accounts.sh | 2 | 0 | -- | -- | not in the diff: no mutant, no claim |
| `bump` | accounts.sh | 2 | 1 | 1 | 2 | ok |
| `dead_until` | accounts.sh | 1 | 0 | -- | -- | not in the diff: no mutant, no claim |
| `is_dead` | accounts.sh | 2 | 1 | 1 | 2 | ok |
| `mark_dead` | accounts.sh | 1 | 1 | 1 | 1 | ok |
| `parse_duration` | accounts.sh | 5 | 2 | 2 | 5 | was 5, restructured (validation added without adding CC) |
| `mark_dead_for_class` | accounts.sh | 4 | 3 | 3 | 4 | ok |
| `set_envargs` | accounts.sh | 3 | 1 | 1 | 3 | ok |
| `alive_fresh` | accounts.sh | 2 | 1 | 1 | 2 | ok |
| `probe` | accounts.sh | 6 | 1 | 1 | 6 | **was 7** -- redundant guard removed (see below) |
| `ranked` | accounts.sh | 4 | 1 | 1 | 4 | ok |
| `pick_live` | accounts.sh | 8 | 2 | 2 | 8 | **over the bar, covered not simplified** |
| `launch` | accounts.sh | 1 | 1 | 1 | 1 | ok |
| `die_no_live_account` | accounts.sh | 1 | 1 | 1 | 1 | ok |
| `auto_launch` | accounts.sh | 2 | 1 | 1 | 2 | ok |
| `night_knobs` | watch.sh | 4 | 2 | 2 | 4 | new |
| `transcript_dir_for` | watch.sh | 1 | 1 | 1 | 1 | ok |
| `find_new_jsonl` | watch.sh | 5 | 1 | 1 | 5 | ok |
| `run_watched` | watch.sh | 18 | 6 | 5 + 1 equivalent | 18 | **over the bar, covered not simplified** |
| `night_mode` | watch.sh | 8 | 4 | 4 | 8 | **over the bar, covered not simplified** |
| `baton` top-level dispatch | baton | 34 | 5 | 5 | 34 | **over the bar, covered not simplified** |

**Simplified (2).**

- `parse_reset_epoch`'s embedded program was CC 9 in one piece. "Turn the
  `(TZ)` group of a CLI message into a tzinfo or None" is a separable
  question from "read a clock time", and it carries its own two failure
  modes (no `zoneinfo` module, unknown zone name). Extracted as
  `resolve_tz`: 4 and 6, both under the bar, and the fallback rule now has
  somewhere to be written down.
- `probe` was CC 7. `[ -n "$out" ] && echo "$out" | grep -qi "ok"` -- the
  `-n` test cannot change the answer, because an empty string cannot match
  the canary grep either. Removing a condition that no input can make matter
  is a simplification, not a behaviour change: CC 6.

**Over the bar, covered not simplified (4).** `pick_live` (8), `night_mode`
(8), `run_watched` (18), the dispatch `case` (34). All four have a kill ratio
of 1.0, so the CRAP coverage term is zero: these are watched, not dark.
The reason they are not split:

- `run_watched` -- `WASTE.md` already considered and rejected exactly this
  split, on the function's own stated grounds ("two functions passing the
  same five pieces of state back and forth, i.e. a shallow module"). Getting
  it to 6 needs four extractions, and the three obvious ones (`start_child`,
  `discover_session`, `scan_transcript`) all read or write the loop's
  carried state (`newfile`, `offset`, `elapsed`, `gave_up_looking`, `pid`),
  so the state would move to globals. Overturning a prior seat's documented
  design decision at the end of the pipeline, to move a number, is a worse
  trade than reporting the number.
- `pick_live` and `night_mode` -- each one's complexity IS its contract: a
  closed set of four probe outcomes, and a two-outcome watch result. The one
  candidate extraction in `night_mode` (the whole ROTATE arm) writes three
  of the loop's own locals, so it lands in the same shallow-module trap.
- the dispatch `case` -- it is a CLI flag table. Each arm is one flag; the
  count is the number of flags baton has, and splitting it into per-flag
  functions moves the same 34 edges behind 11 names.

The honest summary: the completion bar of "all <= 6" is met for every
function this story ADDED except `run_watched` and `night_mode`, and the
inherited dispatch and `pick_live` sit above it too. Flagged for the
conductor rather than fixed by force: if the bar is the binding constraint,
the change to make is the `run_watched` split, and it should be its own
ticket with `WASTE.md`'s rejection reversed on the record, not a quiet edit
in a hardening commit.

---

## 4. Revert audit

Every mutant is applied to the working tree and then restored from an
in-memory copy of the file's original bytes, with the restore verified by
sha256 before the next mutant starts; a mismatch aborts the run (`FATAL:
restore of <file> failed`, exit 3) instead of continuing. That check never
fired in either round.

`git status --porcelain` printed by the runner itself at the end of each
round, after the last revert:

- round 1: `?? .ab/complexity.py`, `?? .ab/mutation-run.py` -- i.e. only this
  seat's new, untracked artifacts; no `M` line for any of the four
  production files.
- round 2: `?? .ab/HARDEN.md`, `?? .ab/complexity.py`, `?? .ab/mutation-run.py` --
  again only this seat's own artifacts, and no `M` line for `baton`,
  `lib/detect.sh`, `lib/accounts.sh` or `lib/watch.sh`. The same held after
  the separate M47 run.

One contamination did occur and is recorded because it shows the guard
working: a scratch copy of the tree taken with `cp -R` DURING round 1 picked
up the `kill -KILL` mutant that happened to be applied at that second. The
copy was in `/tmp`, never a source of truth, and the apparatus caught it
immediately (the literal for that mutant no longer matched exactly once in
the copy). The repository tree itself is protected by the hash-verified
restore, not by luck -- but the rule stands: do not copy a tree while a
mutation run is live.

Suite at the end of this seat, verbatim:

    TESTS: 53  PASS: 53  FAIL: 0

(27 inherited + 10 new scenario files + 16 new unit rows, all green.)
