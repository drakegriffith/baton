# Feature: automatic account failover when a running session hits its usage limit
#
# Scope: this feature file covers ONLY the failover behavior added on top of
# the existing baton launcher (base commit 173fd9e). Publishing / README /
# night-night integration are out of scope (per .ab/DOC.md).
#
# Spec decisions made here because .ab/DOC.md left them open (flagged for the
# coder/reviewer, not hidden):
#   D1. New mode is invoked as `baton --night [claude args...]`. It always
#       auto-picks a starting account the same way plain `baton` does; it
#       does NOT support forcing a starting account (overnight = unattended).
#   D2. Detection contract (shared by probe() and the watcher) is exactly:
#         classify_text(TEXT) ->
#           LIMIT   if TEXT matches   hit your .*limit|usage limit|limit reached   (case-insensitive)
#           AUTH    else if TEXT matches  not logged in|please run /login|invalid api key|authentication  (case-insensitive)
#           UNKNOWN otherwise
#       This is a total partition: every TEXT maps to exactly one class, and
#       classify_text() has no knowledge of accounts, processes, or files
#       (pure function of a string). probe() layers its own extra ALIVE
#       outcome on top (checked only when classify_text() says UNKNOWN and the
#       probe reply contains "ok") -- ALIVE is a probe()-only concept and is
#       not part of the shared contract, because the watcher is never probing
#       for a canary reply, only watching for trouble.
#   D3. The watcher classifies the RAW transcript line text (the whole JSONL
#       line, undecoded), never a parsed sub-field -- the exact JSON shape of
#       a limit event is UNVERIFIED per .ab/DOC.md, so the contract is
#       deliberately schema-agnostic and reuses the exact same regex family
#       probe() already uses on raw claude stdout/stderr.
#   D4. AUTH is treated the same as LIMIT for rotation purposes in --night
#       mode (both post-exit probe and live-transcript watch): an
#       account that is logged out is exactly as useless overnight as one
#       that is rate-limited, so both drive a handoff. Only LIMIT and AUTH are
#       actionable; UNKNOWN is never actionable (never rotates, never kills,
#       never crashes).
#   D5. Post-exit detection re-probes the account fresh (reuses probe()
#       verbatim) rather than classifying the exited child's own output --
#       this matches DOC.md's wording ("child exits and its account
#       probes/reports LIMIT") and keeps one probe implementation.
#   D6. (amended post-review) Session-id for `--resume` is discovered by
#       watching "<config-dir-for-account>/projects/<cwd-slug>/*.jsonl" for a
#       file that GROWS after child launch -- existing file or new one. Only
#       the bytes appended after launch are classified; the size of every
#       transcript already present is snapshotted first. The file that grew
#       is the session that is running, and its basename is the id the next
#       handoff resumes. No id is ever invented.
#         Original wording was "a file that starts existing after child
#       launch; if none appears within $BATON_SESSION_WAIT_SECS, baton
#       relaunches with `-c` ... on every future handoff in that run". That
#       is wrong for the run this feature exists for: accounts share
#       projects/ through the harness symlink, so after the first handoff
#       `--resume <id>` re-opens a transcript that ALREADY exists, no new
#       file ever appears, and the second limit of the night is never seen.
#       Watching for growth subsumes the new-file case (a new file is one
#       that grew from nothing), so the wait no longer gates anything and the
#       "on every future handoff" clause is obsolete: each handoff decides
#       independently, `--resume <id>` when a transcript grew and `-c` when
#       the rotation came from the post-exit probe instead (D5), which has no
#       session to resume. $BATON_SESSION_WAIT_SECS is still accepted and
#       still validated (D7 knob, may already be exported), but no longer
#       changes behavior.
#   D7. New env knobs, all optional and all no-ops on default behavior when
#       unset (per DOC.md: "without changing default behavior"):
#         BATON_ACCOUNTS_ROOT   overrides the accounts root (default:
#                               $HOME/.claude-accounts, unchanged)
#         BATON_WATCH_INTERVAL  seconds between watcher polls (default: 5)
#         BATON_MAX_HANDOFFS    handoff cap per run (default: 3)
#         BATON_SESSION_WAIT_SECS  seconds to wait for the transcript file to
#                               appear before giving up on --resume (default:
#                               30; accepted and validated but inert since
#                               the D6 amendment above)
#   D8. Proactive ("soft") handoff, added on top of the reactive one above.
#       `--night` runs unmonitored, so an account nearly out of its five-hour
#       window is a session that will stop mid-work with nobody there. The
#       soft trigger hands the session on at a moment where handing it on is
#       cheap instead of waiting for the limit to arrive.
#
#       It fires only on the CONJUNCTION of three independent facts, checked
#       once per outer poll tick:
#         (a) a compaction checkpoint was seen in the bytes appended since
#             launch -- a literal substring match on "isCompactSummary":true,
#             schema-agnostic for D3's reason. A sighting only ARMS a
#             candidate; it NEVER kills on its own, because the bytes right
#             after a checkpoint are the start of the next turn (the mid-turn
#             orphan hazard of issues #2 and #12).
#         (b) usage_fraction(current account) is numeric and strictly greater
#             than BATON_SOFT_SWITCH_FRACTION.
#         (c) no watched transcript has grown for BATON_QUIET_SECS.
#       Deliberately NOT part of classify_text: D2's partition is over
#       TROUBLE classes and is total, and a compaction checkpoint is not
#       trouble. A fourth class there would change what UNKNOWN means for
#       every existing caller.
#
#       The usage signal is a NEW file, not the CLI's own state: the harness
#       statusline writes <CLAUDE_CONFIG_DIR>/.rate-limits.json on every
#       render, holding its .rate_limits object plus a `written_at` epoch.
#       watch.sh's standing rule (never open .claude.json or a credentials
#       file) is unchanged, and lib/usage.sh is the only reader.
#
#       FAIL CLOSED. usage_fraction answers the single token `unknown` when
#       the file is missing, unparseable, lacks five_hour.used_percentage,
#       holds a non-numeric value, or carries a `written_at` more than
#       BATON_USAGE_MAX_AGE seconds away from now IN EITHER DIRECTION -- and
#       `unknown` NEVER arms the trigger. The freshness window is two-sided:
#       a timestamp in the future is not fresh, it is unexplained (clock
#       skew, a timezone bug, a hand-edited file), and reading it as fresh is
#       the one wrong answer that arms the trigger. An old number about a
#       five-hour window is not a small error either; it is a statement about
#       a different window.
#
#       A soft handoff is a handoff in every other respect: it kills the
#       child exactly as the LIMIT path does, closes the unit with a
#       completion receipt, rotates through the same path with
#       `--resume <id>`, and COUNTS against BATON_MAX_HANDOFFS (so the cap
#       stop and its issue-#6 resume pointer, exit 75, are unchanged). The
#       dead mark it writes carries the reason word `soft` rather than
#       `limit`, dated from the signal's own five_hour.resets_at when that is
#       in the future and from BATON_SOFT_DEAD otherwise -- a morning reader
#       has to be able to tell "the server refused us" from "baton left while
#       it still worked". Nothing new prints a runnable command: stderr gets
#       a non-runnable notice and the durable line goes to the handoff log.
#
#       Knobs (validated once in night_knobs, before any child is launched):
#         BATON_SOFT_SWITCH          1/0, turns the trigger off (default: 1)
#         BATON_SOFT_SWITCH_FRACTION fraction of the 5h window above which a
#                                    checkpoint may hand off (default: 0.80)
#         BATON_QUIET_SECS           seconds of transcript silence required
#                                    before the cut (default: 20)
#         BATON_SOFT_DEAD            stand-down for a softly handed-off
#                                    account when its signal named no reset
#                                    (default: 5h)
#         BATON_USAGE_MAX_AGE        seconds after which the signal file is
#                                    stale, i.e. unknown (default: 600)
#         BATON_NIGHT_CTX_ARM        1/0 (default: 1). In --night mode ONLY,
#                                    export CLAUDE_CTX_ENFORCE=1,
#                                    CLAUDE_CTX_PARK=95000,
#                                    CLAUDE_CTX_CAP=100000 and
#                                    CLAUDE_CTX_ORCHESTRATOR=1 to the child
#                                    unless the operator already set
#                                    CLAUDE_CTX_ENFORCE, and append
#                                    `--autocompact 100k` unless the operator
#                                    passed their own. Plain `baton` is
#                                    untouched and stays a pure passthrough.
#
#       Premise on record (verifier B3, 2026-09-02): the premise is WEAKENED,
#       not established. Compaction frequency is decoupled from the five-hour
#       clock, reactive failover already loses nothing that would have
#       succeeded, and no handoff log on this machine shows any such loss.
#       The fact that would settle it is a handoff log from a real overnight
#       run showing a reactive handoff that lost identifiable in-flight work.
#       Until then BATON_SOFT_SWITCH=0 is the setting that costs nothing.
#
#
# System surface driven by every scenario below: the `baton` executable
# invoked as a real subprocess (argv in, stdout/stderr/exit-code out), a fake
# `claude` executable placed first on PATH, and the filesystem state under a
# temp accounts root ($BATON_ACCOUNTS_ROOT) plus temp transcript directories.
# See .ab/QA-DOC.md for the exact fake-claude and fixture contract.

Feature: Automatic account failover when a running session hits its usage limit

  Background:
    Given a temp root is used for HOME and for BATON_ACCOUNTS_ROOT
    And a fake "claude" executable is first on PATH
    And account "a" exists as the primary account (its dir resolves to $HOME/.claude)
    And account "b" exists as a non-primary account
    And accounts "a" and "b" are both alive and undead
    And BATON_WATCH_INTERVAL is set to a small value so polling is fast and deterministic

  # --- 1. Interactive overnight limit hit (the headline scenario) ---------

  @failover
  Scenario: Unattended interactive session hits its limit and the run continues on the next account
    Given fake claude for account "a" starts, writes a transcript file for a known session id, and then blocks waiting on stdin without exiting
    When I run "baton --night -- some-project-args"
    And the transcript file for account "a" gains a line matching the shared LIMIT pattern while the child is still alive
    Then baton kills the still-running child for account "a"
    And account "a" is marked dead until the reset time parsed from that transcript line
    And baton announces the handoff on stderr naming account "a" and account "b"
    And baton relaunches fake claude under account "b" with argv containing "--resume" and the session id captured from account "a"'s transcript file
    And the run keeps going under account "b" instead of stopping

  @failover
  Scenario: Reset time missing from the transcript line falls back to the default dead duration
    Given fake claude for account "a" starts, writes a transcript file for a known session id, and then blocks waiting on stdin without exiting
    When I run "baton --night"
    And the transcript file for account "a" gains a LIMIT-matching line with no parseable "resets <time>" clause
    Then account "a" is marked dead for the same default duration probe() uses when it cannot parse a reset time

  # --- 2. Headless limit hit -------------------------------------------

  @failover
  Scenario: Headless child exits after hitting its limit and the run rotates to the next account
    Given fake claude for account "a" is configured to exit immediately with a usage-limit message and a nonzero exit code
    And a fresh probe of account "a" after that exit is configured to report LIMIT
    When I run "baton --night"
    Then account "a" is marked dead until the reset time from the post-exit probe
    And baton announces the handoff on stderr naming account "a" and account "b"
    And baton relaunches fake claude under account "b"
    And the run keeps going under account "b" instead of exiting with the child's exit code

  @failover @detection
  Scenario: Headless child exits after an auth failure and the run rotates to the next account
    Given fake claude for account "a" is configured to exit immediately with a "Not logged in" message
    And a fresh probe of account "a" after that exit is configured to report AUTH
    When I run "baton --night"
    Then account "a" is marked dead for 1 hour with reason "auth"
    And baton relaunches fake claude under account "b"

  # --- 3. Clean exit: no rotation ---------------------------------------

  @failover
  Scenario: Child exits cleanly and baton exits with the same code, no rotation
    Given fake claude for account "a" is configured to exit with code 0 and ordinary output
    And a fresh probe of account "a" after that exit is configured to report ALIVE
    When I run "baton --night"
    Then baton exits with code 0
    And account "a" is not marked dead
    And baton never launches a second claude process

  @failover
  Scenario: Child exits with a nonzero non-limit code and baton propagates it, no rotation
    Given fake claude for account "a" is configured to exit with code 7 and ordinary output
    And a fresh probe of account "a" after that exit is configured to report ALIVE
    When I run "baton --night"
    Then baton exits with code 7
    And account "a" is not marked dead
    And baton never launches a second claude process

  # --- 4. Exhaustion -----------------------------------------------------

  @failover
  Scenario: All accounts are limited and baton dies with the no-live-account message
    Given fake claude for account "a" is configured to exit immediately with a usage-limit message
    And a fresh probe of account "a" after that exit is configured to report LIMIT
    And fake claude for account "b" is configured to exit immediately with a usage-limit message
    And a fresh probe of account "b" after that exit is configured to report LIMIT
    When I run "baton --night"
    Then baton exits nonzero
    And baton prints the existing "no live account" message on stderr, naming BATON_ACCOUNTS_ROOT and --revive
    And account "a" is marked dead with a reset time
    And account "b" is marked dead with a reset time

  # --- 5. Handoff cap -----------------------------------------------------

  @failover
  Scenario: Handoff cap is reached before every account is exhausted
    Given a third account "c" also exists, alive and undead
    And BATON_MAX_HANDOFFS is set to 1
    And fake claude for account "a" is configured to exit immediately with a usage-limit message
    And a fresh probe of account "a" after that exit is configured to report LIMIT
    And fake claude for account "b" is configured to exit immediately with a usage-limit message
    And a fresh probe of account "b" after that exit is configured to report LIMIT
    When I run "baton --night"
    Then baton exits nonzero
    And baton prints a message on stderr naming the cap "1" and the env override "BATON_MAX_HANDOFFS"
    And account "c" is never probed and never launched

  # --- 6. Total partition: unrecognized content is safe -------------------

  @failover @detection
  Scenario: Unrecognized transcript content is classified UNKNOWN and never treated as a limit
    Given fake claude for account "a" starts, writes a transcript file for a known session id, and then blocks waiting on stdin without exiting
    When I run "baton --night"
    And the transcript file for account "a" gains several lines of ordinary assistant chatter matching neither the LIMIT nor the AUTH pattern
    Then baton does not kill the child
    And account "a" is not marked dead
    And baton does not exit and does not print any handoff or crash message
    And when the child later exits cleanly, baton exits with the child's code

  @detection
  Scenario Outline: The same shared classification function backs both detection paths
    Given a text sample "<text>"
    When the sample is classified by the shared detection contract
    Then the classification is "<class>"
    And a probe() call whose raw output is exactly that text produces the same classification
    And a transcript line whose raw text is exactly that text produces the same classification

    Examples:
      | text                                                        | class   |
      | You've hit your usage limit. resets 2:30pm (America/New_York) | LIMIT   |
      | usage limit reached for this account                        | LIMIT   |
      | Not logged in. Please run /login                             | AUTH    |
      | Invalid API key                                              | AUTH    |
      | Here is the code you asked for...                            | UNKNOWN |
      | (empty string)                                               | UNKNOWN |

  # --- 7. Existing behavior is unchanged ----------------------------------

  @regression
  Scenario: Plain baton still execs and never watches
    Given fake claude for account "a" is configured to exit with code 0
    When I run "baton"
    Then the fake claude process replaces the baton process (exec, not a child)
    And no transcript watching occurs
    And no handoff-related output appears on stderr

  @regression
  Scenario Outline: Existing flags are unaffected by the --night addition
    Given the accounts fixture from the Background
    When I run "baton <flags>"
    Then the output matches the same behavior as the pre-failover baton for those flags

    Examples:
      | flags               |
      | --status            |
      | --pick              |
      | --dead a 90m        |
      | --revive a          |
      | --next              |
      | --fast              |
      | a                   |

  # --- 8. Dependency-flow constraint made observable ----------------------

  @dependency
  Scenario: The watcher never reads account credentials
    Given account "a" has a credentials sentinel file made unreadable (mode 000)
    And fake claude for account "a" starts, writes a transcript file for a known session id, and then blocks waiting on stdin without exiting
    When I run "baton --night"
    And the transcript file for account "a" gains a line matching the shared LIMIT pattern while the child is still alive
    Then the handoff to account "b" completes as in the headline scenario
    And the credentials sentinel file's access and modify times are unchanged by the run
    And no "Permission denied" message referencing that file appears anywhere in baton's stderr

  @dependency
  Scenario: Tests never touch the real accounts root
    Given BATON_ACCOUNTS_ROOT points at a temp directory distinct from $HOME/.claude-accounts
    And a snapshot of the real $HOME/.claude-accounts directory (if any) is taken before the run
    When I run the full scenario suite in this feature
    Then the real $HOME/.claude-accounts directory is byte-for-byte, mtime-for-mtime unchanged after the run
