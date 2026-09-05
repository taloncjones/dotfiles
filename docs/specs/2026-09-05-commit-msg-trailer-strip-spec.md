# Spec: Strip agent attribution lines in the commit-msg hook

Task: td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg
Branch-only artifact: dropped before merge (docs/specs is gitignored and
public-safety.test.sh rejects tracked planning files).

## Problem

Claude Code 2.1.259+ appends a co-author trailer and a session-URL trailer
to every commit by default. One `Claude-Session: https://claude.ai/code/...`
trailer reached `main` through a worker commit that PR #77 squashed (visible
in `git log -1 --format=%B 651a505`). PR #79 turned the trailers off in
`claude/settings.json.tmpl` (`attribution.commit` and `attribution.pr` set to
`""`, `attribution.sessionUrl` set to `false`), but that opt-out only holds
when `settings.json` actually loads. On 2026-09-04 a schema error made every
launch skip the file; cloud containers, a stale template, or a work config dir
that has not reconciled can miss it the same way.

The repo already ships a global `commit-msg` hook (`git/hooks/commit-msg`,
reached through `core.hooksPath = ~/.config/git/hooks`, which
`install/common/link.sh` symlinks to `git/hooks/`). Today that hook only
BLOCKS: it rejects `Co-Authored-By` lines naming an agent and inline
"Generated with" phrases, and it has no rule at all for `Claude-Session:`.
Blocking is the wrong shape for an injected trailer: the human never typed
it, an autonomous worker cannot always fix it, and the session-URL case is not
even detected.

## Goals

- G1: For any commit where git executes this installed hook and the
  `DOTFILES_SKIP_COMMIT_MSG_GUARD=1` bypass is not set, no line matching the
  strip rules R1-R3 below reaches the commit object, whether or not
  `settings.json` loaded. Commits made with `--no-verify`, in repos that
  override `core.hooksPath`, or by clients that do not run git hooks are
  outside this guarantee (the same reach the existing block rules have).
- G2: Every line that does not match R1-R3 survives byte-for-byte: subject,
  body, and every other trailer. The guarantee is syntactic, not about
  provenance: the hook cannot know who typed a line, so the accepted false
  positives are listed under "Accepted collisions" and each has a test.
- G3: A message with no matching line is not rewritten at all.
- G4: The strip pass works without `rg` (the existing block checks already
  skip themselves when `rg` is missing; the strip pass must not inherit that
  gap, since containers without `rg` are exactly where the settings opt-out
  is least reliable).
- G5: The PR-side story is documented: a squash merge composes its message
  from the PR body, which this hook never sees, so the `attribution.pr`
  opt-out in the settings template remains the only guard there.

## Non-goals

- No new hook file. Git runs exactly one `commit-msg` hook from
  `core.hooksPath`; the strip pass is added to the existing
  `git/hooks/commit-msg`.
- No change to the existing block rules, their `rg` dependency, or the emoji
  rule.
- No blank-line or whitespace normalization. The hook removes matched lines
  and nothing else; git's default `--cleanup=strip` already collapses
  consecutive blank lines and drops trailing ones when it builds the commit
  object.
- No PR-description scrubbing. GitHub composes the squash message from the PR
  body; that is outside git hooks and stays with the settings opt-out.
- No change to `claude/hooks/commit_guard.py` (the Claude-side Bash guard on
  `git commit` command text). It stays a first line of defense for interactive
  sessions; the git hook is the harness-agnostic backstop.
- No fix for the existing block rule's `ai\b` false positive (a human
  co-author whose name ends in "ai" is still rejected). Documented, not
  changed.
- No edit to the repo `CLAUDE.md`.

## Design

### Placement and order

`git/hooks/commit-msg` gains a strip pass that runs BEFORE the existing block
checks:

1. Existing early exits are unchanged: `DOTFILES_SKIP_COMMIT_MSG_GUARD=1`
   skips the whole hook; a missing or empty message-file argument exits 0.
2. Strip pass (new, no `rg`): remove lines matching R1-R3 from the message
   file. Runs under `LC_ALL=C` so the emoji bytes that prefix Claude's footer
   count as non-alphanumeric.
3. Existing block checks run on the stripped message exactly as today
   (including the `rg`-missing early exit and its stderr notice).

Stripping persists even when a later block check rejects the commit: the
message file on disk (for example `.git/COMMIT_EDITMSG`) holds the stripped
text, so a human who re-runs `git commit` after fixing the subject does not
re-fix the trailer. One test covers this mixed case.

Behavioral changes relative to today, stated fully:

- A message whose only offense was one or more R1-R3 lines now commits with
  those lines removed instead of being rejected.
- A message with an R1-R3 line plus a still-blocked offense is rejected as
  before, but with the R1-R3 lines already removed from the file.
- A `Claude-Session:` line, previously undetected, is now removed.

### Tool baseline

The strip pass uses only: `bash` (the hook's interpreter, via
`#!/usr/bin/env bash`), `awk`, `grep`, `sed`, `cat`, `mktemp`, `mv`, `rm`,
and the shell builtin `printf`. Supported userlands are macOS (BSD) and
Debian/Ubuntu (GNU); every regex below is POSIX ERE with bracket classes only
(no `\b`, no `\s`), so it means the same thing under both. `mktemp` is not in
POSIX but ships in both userlands; it is required, not optional.

### Strip rules

All rules are case-insensitive and whole-line, and apply to line 2 onward.
The subject line (line 1) is never stripped: stripping it would leave an empty
subject. Whatever the existing block rules catch in the subject (inline
`Generated with <agent>`, an agent co-author line) is still rejected; a
subject shaped like a session trailer is not detected by either layer and is
out of scope (no tool emits one).

| Rule | Matches a line that | Example (stripped) |
|------|---------------------|--------------------|
| R1 agent co-author | starts with optional whitespace, then `co-authored-by:`, and anywhere later on the line contains one of the agent tokens `claude`, `anthropic`, `copilot`, `chatgpt`, `gpt`, `codex` | `Co-Authored-By: Claude <noreply@anthropic.com>` |
| R2 session trailer | EITHER starts with optional whitespace, then `claude-session:` (any value, including empty); OR starts with optional whitespace, then a key made of letters and hyphens that contains `session`, a colon, optional whitespace, and `http://` or `https://` | `Claude-Session: https://claude.ai/code/session_01ABC`; `Codex-Session: https://example.invalid/s/1` |
| R3 generated-with footer | starts with any run of non-alphanumeric bytes (emoji, brackets, whitespace, or none), then `generated`, whitespace, `with` or `by`, then any run of non-alphanumeric bytes (so a markdown `[` is allowed), then one of `claude`, `anthropic`, `copilot`, `chatgpt`, `gpt`, `codex`, `ai`, followed by a non-alphanumeric byte or end of line | `Generated with [Claude Code](https://claude.com/claude-code)`, with or without a leading emoji; `Generated by AI` |

Agent token list is the existing block rule's list (`claude`, `anthropic`,
`copilot`, `chatgpt`, `gpt`, `codex`) minus its bare `ai\b` alternative,
which is dropped from R1 on purpose: stripping is silent and must not eat a
human line on a two-letter substring. R3 keeps `ai` because it is anchored to
a `generated with|by` prefix, and the trailing boundary keeps `Aiden` from
matching.

Lines that do NOT match: a human `Co-Authored-By: Jane Doe <jane@example.com>`;
`Reviewed-by:`, `Signed-off-by:`, `Fixes:`, or any other trailer; a body
sentence that mentions an agent inline (`Documents the codex-plan-review
skill`); a `generated with` phrase that is not at the start of a line (that
case still hits the existing block check, which is the intended outcome for
inline attribution the hook cannot safely edit); the subject line, whatever
it contains.

### Accepted collisions

The rules match syntax, so these human-written lines are also removed. Each
is accepted, and each is pinned by a test so the behavior is deliberate
rather than accidental:

- A body line that begins `Generated with codex, this change ...` (R3 is a
  prefix match). Today the block rule rejects the whole commit for the same
  line, so this is strictly more permissive.
- A human co-author whose name or address contains an agent token, for
  example `Co-Authored-By: Claude Martin <cm@example.com>` (R1).
- A human-written `Claude-Session:` trailer with any value, or any
  `*session*:` trailer whose value is a URL (R2).

### Rewrite semantics

When at least one line matches:

- Every non-matching line is written back in order, byte-for-byte, including
  blank lines. No collapsing, trimming, or newline normalization.
- The hook prints one stderr line, `commit-msg: stripped N agent attribution
  line(s).`, so a human running `git commit` sees that the message changed.
  This is informational; the exit code is unaffected.
- The write is atomic: `mktemp` creates a temp file in the message file's
  directory, the kept lines are written there, and `mv` replaces the
  original.

When no line matches, the file is not opened for writing, no stderr line is
printed, and the byte content is identical to the input.

Failure handling (fail closed): any failure in the strip pass (a required
tool missing, temp file creation or write failing) exits non-zero with a
stderr line starting `commit-msg:`, leaves the original message file
unchanged, and leaves no temp file behind (a `trap` removes it). The hook
must never fall through to "allow" on an error, because its whole purpose is
to be the backstop when other layers fail.

### Documentation

`README.md`, section "Global Git Hooks":

- The sentence "The hook is a no-op for repos that do not use `.todos/` or
  `.planning/`" is reworded to name `post-checkout`, since the section now
  documents two hooks.
- A `commit-msg` entry is added next to `post-checkout` that states: what the
  hook strips (R1-R3, one sentence each) and what it still blocks (inline
  attribution, emoji); that `DOTFILES_SKIP_COMMIT_MSG_GUARD=1` bypasses it;
  and that a squash merge's message comes from the PR body, which no git hook
  sees, so the `attribution.pr = ""` opt-out in `claude/settings.json.tmpl`
  is the guard for PR descriptions and must stay.

### Tests

`git/hooks/commit-msg.test.sh` (run by `bin/dotfiles-tests` and CI) is
extended. It keeps its existing structure (`sh`, `PASS`/`FAIL` counters,
one-line labels) and its convention of building agent names from string
parts so the file never contains a literal attribution string. New
assertions compare the hook's output file to an expected file with `cmp`,
not with substring checks, so "untouched" means byte-identical. Each case is
one explicit assertion line; a helper takes (label, input, expected) and
reports exit code plus byte equality.

Strip cases (exit 0, output equals expected):

- T1 `Co-Authored-By` line naming Claude, after a body: line removed, the
  blank line that preceded it kept.
- T2 `Claude-Session:` with a URL value.
- T3 `Codex-Session:` with a URL value (generic R2 branch).
- T4 `Generated with [Claude Code](...)` footer with a leading emoji byte
  sequence (built with `printf` octal escapes, as the existing emoji test
  does).
- T5 all three kinds at once with a `Reviewed-by:` trailer between them: the
  human trailer and every blank line survive; only the three lines go.
- T11 lowercase `co-authored-by: claude <...>` (case-insensitivity).
- T12 leading whitespace before `Co-Authored-By:` (optional whitespace).
- T13 `Generated by AI` (R3 `by` branch and `ai` token).
- T14 `Claude-Session:` with a non-URL value (R2 any-value branch).
- T15 accepted collision: a body line beginning `Generated with codex,`.
- T16 accepted collision: `Co-Authored-By: Claude Martin <cm@example.com>`.

Pass-through cases (exit 0, output byte-identical to input, empty stderr):

- T6 clean multi-paragraph message with two trailers and a double blank
  line.
- T7 human `Co-Authored-By: Jane Doe <jane@example.com>`.
- T17 `Generated with Aiden's help` in the body (token boundary: `ai`
  followed by an alphanumeric byte does not match).
- T18 a body line mentioning an agent inline, not at line start.

Block cases (exit non-zero):

- T8 subject `scope: Generated with <agent>`: rejected, file unchanged.
- T19 mixed offense: subject with inline attribution plus a Claude
  co-author trailer: rejected, and the file on disk has the trailer removed
  but the subject intact.

Environment cases:

- T9 `rg` absent: the hook is invoked with `PATH` set to a temp dir holding
  symlinks (resolved with `command -v`) to exactly `bash`, `awk`, `grep`,
  `sed`, `cat`, `mktemp`, `mv`, `rm`, and no `rg`; an agent co-author line
  is still stripped and the hook exits 0, and stderr contains the existing
  `rg not found` notice (proving the block checks were reached and skipped).
- T10 failure path: the message file lives in a directory made read-only
  (`chmod 500`), so `mktemp` cannot create the temp file; the hook exits
  non-zero, stderr contains a line starting `commit-msg:`, the original file
  is byte-identical, and the directory contains no file other than the
  original. The case is skipped with a visible `SKIP` line when the test runs
  as root (root ignores directory permissions).

Existing assertions: "blocks AI coauthor" becomes a strip-and-allow case
(it is T1); every other existing assertion is unchanged.

No test-runner change is needed: the suite is already listed in
`bin/dotfiles-tests`.

## Acceptance criteria

- AC1: `sh git/hooks/commit-msg.test.sh` passes with every case T1-T19
  present and the amended existing assertions.
- AC2: An agent `Co-Authored-By` line after a body is removed and the commit
  is allowed (T1, T11, T12).
- AC3: `Claude-Session:` lines are removed with URL and non-URL values (T2,
  T14), and a session-URL trailer with another key is removed (T3).
- AC4: A `Generated with [Claude Code](...)` footer with a leading emoji is
  removed (T4), and `Generated by AI` is removed (T13).
- AC5: When lines are stripped, every other line, blank lines included,
  survives byte-for-byte (T5).
- AC6: A message with nothing to strip is byte-identical after the hook and
  produces no stderr output (T6, T7, T17, T18).
- AC7: A human `Co-Authored-By` line without an agent token survives (T7).
- AC8: The subject line is never modified; inline attribution in the subject
  is still blocked (T8), and stripping persists on a mixed-offense rejection
  (T19).
- AC9: Stripping works with `rg` absent from `PATH` (T9).
- AC10: A strip-pass failure exits non-zero, reports on stderr, leaves the
  original unchanged, and leaves no temp file (T10).
- AC11: The accepted collisions strip as documented (T15, T16).
- AC12: `README.md` "Global Git Hooks" documents the `commit-msg` hook,
  names `post-checkout` in the no-op sentence, and states that the PR-body
  opt-out stays in `claude/settings.json.tmpl`.
- AC13: `bin/dotfiles-tests` exits 0 (no other suite regresses; in
  particular `public-safety.test.sh` still finds no tracked `docs/specs` or
  `docs/plans` files at merge time).

## Risks and assumptions

- `Claude-Session:` is the observed key as of Claude Code 2.1.259+
  (confirmed in the leaked commit). If the key changes, R2's generic
  `*session*: http(s)://` alternative is the catch. If the key changes AND
  the value stops being a URL, R2 needs an update.
- The hook's reach is bounded by G1: `--no-verify`, a local `core.hooksPath`
  override, and clients that skip hooks are not covered, exactly as today.
- T10 depends on directory permissions being enforced, which is true for the
  non-root CI runner and for local runs; the root skip keeps the suite green
  elsewhere.
