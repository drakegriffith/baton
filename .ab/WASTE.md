# Waste analysis -- diff against 173fd9e (seat2's failover implementation + tests)

Scope: `git diff 173fd9e -- . ':!.ab' ':!features'` (baton, lib/detect.sh,
lib/accounts.sh, lib/watch.sh, tests/**). Constraints: bash 3.2, no behavior
changes, Ousterhout bias against shattering deep functions into shallow
helpers, suite must stay green after every applied item.

Baseline before any change: `bash tests/run.sh` -> `TESTS: 27  PASS: 27  FAIL: 0`.

## Applied (3)

1. **Dead code -- four unused test helpers in `tests/fixtures/lib.sh`.**
   `wait_until()`, `file_has_lines()`, `append_transcript_line()`, and
   `night_stdout()` were defined but never called anywhere in
   `tests/scenarios/`, `tests/unit/`, or `tests/run.sh` (confirmed by
   grepping every function name across the whole tree). Leftover scaffolding
   from an earlier draft of the fixture library. Removed; no test referenced
   them, so removal is behavior-neutral. `transcript_file_of` and
   `cwd_slug`, which look similar, were kept -- they're used internally by
   `wait_for_transcript` and by each other, just never called directly from
   a scenario file, so they aren't dead.

2. **Duplication -- `fresh_root()` / `fresh_root_hardcoded_default()` in
   `tests/fixtures/lib.sh`.** The two functions were byte-for-byte identical
   except for one line (`BATON_ACCOUNTS_ROOT="$SCRATCH/accounts"` vs.
   `"$HOME/.claude-accounts"`), 13 duplicated lines carrying the same
   set-up-and-tear-down knowledge (temp HOME, symlinked primary account,
   alive marks) in two places that would need to change in lockstep.
   Collapsed into one `fresh_root()` that takes an optional `hardcoded` arg
   to pick the root path; `fresh_root_hardcoded_default()` is now a
   one-line call-through kept only so the 2 existing call sites (scenario
   12) don't need touching, and so the name that documents *why* that
   variant exists stays discoverable. This mirrors the pattern the coder
   already used for `classify_text` / `mark_dead_for_class` (one shared
   place a behavior is defined, callers pass what differs).

3. **Duplication -- the "no live account" die message, 3 literal copies.**
   The exact string `"no live account. baton --status to see dead marks;
   baton --revive <name> to override"` appeared verbatim in
   `lib/accounts.sh` (`auto_launch`) and twice in `lib/watch.sh`
   (`night_mode`'s initial pick and its post-rotation pick). Same failure
   mode DOC.md warns about for the classification regexes, just for an
   operator-facing message instead of a pattern: three copies that could
   silently drift in wording. Extracted to `die_no_live_account()` in
   `lib/accounts.sh` (next to `pick_live`, whose failure contract it
   spells out), called from all 3 sites. Updated the module-header
   "public surface" comments in both `accounts.sh` and `watch.sh` to name
   the new function, since those comments are exactly the place this kind
   of cross-file contract is supposed to be discoverable.

## Considered and rejected

- **Collapsing `tests/scenarios/01`..`14` into one parameterized loop.**
  There is real structural repetition across files (`fresh_root`,
  `write_behavior`, `start_night`, `wait_for_night_exit`,
  `scenario_check` ... `cleanup_root`), but `tests/fixtures/lib.sh`'s own
  header states the design goal directly: "matching the 1:1
  Gherkin-scenario-to-test mapping the coder assignment requires." Each
  file's name and content trace to one row of QA-DOC section 5. Merging
  them would trade away that traceability for a shorter file -- not a net
  win, and it's an explicit design decision already made by an earlier
  seat, not an accident. Left alone.

- **Splitting `run_watched()` (lib/watch.sh) into smaller helpers**
  (e.g. separate "watch the transcript" from "decide kill vs. natural
  exit"). The function's own comment already argues this explicitly: they
  "would just be two functions passing the same five pieces of state back
  and forth, i.e. a shallow module." That is precisely the failure mode
  the assignment's Ousterhout-bias constraint warns against. Left as one
  deep function.

- **Removing the D1-D7 / QA-DOC-section-N rationale comments as "comment
  noise."** These comments carry information the code can't: *why* a
  function lives in this file and not that one, *why* a regex or a message
  must stay single-sourced, *why* a test fixture picks one root path over
  another. That's interface documentation, not restated code. Cutting it
  would be a net loss of information, not a cleanup.

- **Extracting `fake_log()`, `signals_log_of()`, `invocation_count_file_of()`,
  `config_dir_of()` as "shallow pass-through helpers."** Each is one line,
  but each hides a piece of knowledge (which literal path an account's
  config dir or log file resolves to) that's reused across many scenario
  files. Inlining them would spread that knowledge back out into 5-20 call
  sites each. Kept.

- **Merging `probe()`'s ALIVE-detection branch into `classify_text()`.**
  `lib/detect.sh`'s header comment explicitly excludes ALIVE from
  `classify_text`'s contract: it only makes sense for a probe's own canary
  reply, and the watcher never sends one. Folding it in would change what
  the shared classifier means and risk the watcher misreading a stray "ok"
  in a transcript as an alive signal -- a behavior change, out of scope.

- **Renaming `PICKED`, `NIGHT_RESULT`, `NIGHT_CLASS`, etc. (global
  out-params set by a function instead of returned).** This matches the
  pre-existing convention (`PROBE_CLASS`, `PROBE_OUT`) already established
  in the un-diffed parts of `accounts.sh`. Renaming would make the new code
  inconsistent with the surrounding style for no behavioral or readability
  gain -- a bikeshed, not waste.

## Result

Applied: 3. Rejected: 6.
Suite after cleanup: `bash tests/run.sh` -> `TESTS: 27  PASS: 27  FAIL: 0`
(same 27 tests, same pass count, as the pre-cleanup baseline).
