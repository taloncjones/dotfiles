# Spec: Strip agent attribution trailers in the commit-msg hook

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

- G1: An agent-injected trailer never survives into a commit object on a
  machine that has the dotfiles hooks installed, regardless of whether
  `settings.json` loaded.
- G2: Everything the human wrote survives byte-for-byte: subject, body,
  every non-agent trailer (including a human `Co-Authored-By`).
- G3: A message that contains nothing to strip is not rewritten at all.
- G4: The strip path works without `rg` (the existing block checks already
  skip themselves when `rg` is missing; the strip path must not inherit that
  gap, since containers without `rg` are exactly where the settings opt-out
  is least reliable).
- G5: The PR-side story is documented: a squash merge composes its message
  from the PR body, which this hook never sees, so the `attribution.pr`
  opt-out in the settings template remains the only guard there.

## Non-goals

- No new hook file. Git runs exactly one `commit-msg` hook from
  `core.hooksPath`; the strip pass is added to the existing
  `git/hooks/commit-msg`.
- No change to the existing block rules or their `rg` dependency, and no
  change to the emoji rule. The one intended behavioral change is that
  messages whose only offense was a strippable trailer now commit (stripped)
  instead of being rejected.
- No PR-description scrubbing. GitHub composes the squash message from the PR
  body; that is outside git hooks and stays with the settings opt-out.
- No change to `claude/hooks/commit_guard.py` (the Claude-side Bash guard on
  `git commit` command text). It stays a first line of defense for interactive
  sessions; the git hook is the harness-agnostic backstop.
- No fix for the existing block rule's `ai\b` false positive (a human
  co-author whose name ends in "ai" is still rejected). Documented, not
  changed.

## Design

### Placement and order

`git/hooks/commit-msg` gains a strip pass that runs BEFORE the existing block
checks:

1. Existing early exits are unchanged: `DOTFILES_SKIP_COMMIT_MSG_GUARD=1`
   skips the whole hook; a missing or empty message-file argument exits 0.
2. Strip pass (new, no `rg`): remove agent attribution lines from the
   message file in place. Implemented with POSIX tools only (`awk`, `grep`,
   `sed`, `printf`, `mktemp`), run under `LC_ALL=C` so the emoji bytes that
   prefix Claude's footer count as non-alphanumeric.
3. Existing block checks run on the stripped message exactly as today
   (including the `rg`-missing early exit and its stderr notice).

The strip pass writes back to the message file only when at least one line
was removed. When nothing matched, the file is not opened for writing, so a
clean message is byte-identical after the hook.

### Strip rules

All rules are case-insensitive, whole-line, and apply to line 2 onward. The
subject line (line 1) is never stripped: if the subject itself carries
attribution the existing block check rejects the commit, and stripping it
would leave an empty subject.

| Rule | Matches a line that | Example (stripped) |
|------|---------------------|--------------------|
| R1 agent co-author | starts with optional whitespace, then `Co-Authored-By:`, and anywhere later on the line contains one of `claude`, `anthropic`, `copilot`, `chatgpt`, `gpt`, `codex` | `Co-Authored-By: Claude <noreply@anthropic.com>` |
| R2 session-URL trailer | starts with optional whitespace, then a trailer key containing `session` (letters and hyphens only, e.g. `Claude-Session`, `Codex-Session`, `Session-URL`), a colon, and a value beginning `http://` or `https://`; OR starts with `Claude-Session:` with any value | `Claude-Session: https://claude.ai/code/session_01ABC` |
| R3 generated-with footer | starts with any run of non-alphanumeric bytes (emoji, brackets, whitespace, none), then `Generated with` or `Generated by`, whitespace, one of `claude`, `anthropic`, `copilot`, `chatgpt`, `gpt`, `codex`, `ai`, followed by a non-alphanumeric byte or end of line | `Generated with [Claude Code](https://claude.com/claude-code)` (with or without a leading emoji) |

Agent-name token list is the existing block rule's list (`claude`,
`anthropic`, `copilot`, `chatgpt`, `gpt`, `codex`) minus the bare `ai\b`
alternative, which is dropped from the strip rules on purpose: stripping is
silent and must not eat a human line on a two-letter substring. R3 keeps `ai`
because it is anchored to a `Generated with|by` prefix.

Lines that do NOT match: a human `Co-Authored-By: Jane Doe <jane@example.com>`;
`Reviewed-by:`, `Signed-off-by:`, `Fixes:`, or any other trailer; body
sentences that mention an agent inline (`Documents the codex-plan-review
skill`); a subject line of any content; a `Generated with` phrase that is not
at the start of a line (that case still hits the existing block check, which
is the intended outcome for inline attribution the hook cannot safely edit).

### Rewrite semantics

When at least one line is removed:

- Non-matching lines are kept in order, byte-for-byte.
- Runs of two or more consecutive blank lines that result from the removal
  are collapsed to one blank line, and trailing blank lines are dropped, so
  the message ends with the last content line plus a single newline. This
  matches what git's default `--cleanup=strip` would do anyway; the hook does
  it explicitly so the result is deterministic under every cleanup mode.
- Leading blank lines and interior single blank lines are untouched.
- The hook prints one stderr line, `commit-msg: stripped N agent attribution
  line(s).`, so a human running `git commit` sees that the message changed.
  This is informational; the exit code is unaffected.

When no line is removed the file is not written, no stderr line is printed,
and the byte content is identical to the input.

The write uses a temp file next to the message file (`mktemp` in the same
directory) and `mv` over the original, so a failure mid-write cannot leave a
truncated message. Any failure in the strip pass (tool missing, temp file
unwritable) aborts the commit non-zero with a `commit-msg:` stderr line; the
hook must never fall through to "allow" on an error, because the whole point
is to be the backstop when other layers fail.

### Documentation

`README.md`, section "Global Git Hooks", gains a `commit-msg` entry next to the
existing `post-checkout` entry that states:

- what the hook strips (R1-R3 in one sentence each) and what it still blocks
  (inline attribution, emoji);
- that `DOTFILES_SKIP_COMMIT_MSG_GUARD=1` bypasses it;
- that a squash merge's message comes from the PR body, which no git hook
  sees, so the `attribution.pr = ""` opt-out in `claude/settings.json.tmpl`
  is the guard for PR descriptions and must stay.

The repo `CLAUDE.md` is unchanged (the hook is already covered by the
`git/hooks` wiring it describes).

### Tests

`git/hooks/commit-msg.test.sh` (run by `bin/dotfiles-tests` and CI) is
extended. It keeps its existing structure (`sh`, `PASS`/`FAIL` counters,
one-line labels) and its convention of building agent names from string
parts so the file never contains a literal attribution string. New assertions
compare the hook's output file to an expected file with `cmp`, not with
substring checks, so "untouched" means byte-identical.

Cases:

- T1 strips a `Co-Authored-By` line naming Claude; expected output is the
  message without that line and without a trailing blank line.
- T2 strips a `Claude-Session:` URL trailer.
- T3 strips a generic session-URL trailer with a different key
  (`Codex-Session: https://...`).
- T4 strips a `Generated with` footer that carries a leading emoji byte
  sequence (built with `printf` octal escapes, as the existing emoji test
  does).
- T5 strips a message carrying all three trailer kinds at once and keeps a
  `Reviewed-by:` trailer that sits between them; the result has exactly one
  blank line between body and the surviving trailer.
- T6 leaves a clean multi-paragraph message byte-identical, with no stderr
  output.
- T7 keeps a human `Co-Authored-By: Jane Doe <jane@example.com>` line.
- T8 leaves the subject line alone: a subject containing `Generated with
  <agent>` is still blocked (exit non-zero), and the file is unchanged.
- T9 the strip pass runs when `rg` is absent: the hook is invoked with a
  `PATH` that holds only the POSIX tools it needs (symlinks resolved via
  `command -v` into a temp dir) and no `rg`; an agent co-author line is still
  stripped and the hook exits 0.
- Existing assertions: "blocks AI coauthor" becomes "strips AI coauthor and
  allows" (exit 0, line gone); every other existing assertion is unchanged.

A committed test-runner change is not needed: the suite is already listed in
`bin/dotfiles-tests`.

## Acceptance criteria

- AC1: `sh git/hooks/commit-msg.test.sh` passes with T1-T9 present and the
  amended existing assertions.
- AC2: A message consisting of a subject, a body, and a `Co-Authored-By`
  line naming Claude commits with exit 0 and the line removed (T1).
- AC3: A `Claude-Session:` URL trailer is removed (T2), and a
  session-URL trailer with another agent key is removed (T3).
- AC4: A `Generated with` footer line, with a leading emoji, is removed (T4).
- AC5: Every non-agent trailer and every body line survives byte-for-byte
  when other lines are stripped, and blank-line collapse leaves one blank
  line between body and surviving trailers (T5).
- AC6: A message with nothing to strip is byte-identical after the hook and
  produces no stderr output (T6).
- AC7: A human `Co-Authored-By` line survives (T7).
- AC8: The subject line is never modified; inline attribution in the subject
  is still blocked (T8).
- AC9: Stripping works with `rg` absent from `PATH` (T9).
- AC10: `README.md` "Global Git Hooks" documents the `commit-msg` hook and
  states that the PR-body opt-out stays in `claude/settings.json.tmpl`.
- AC11: `bin/dotfiles-tests` exits 0 (no other suite regresses; in
  particular `public-safety.test.sh` still finds no tracked `docs/specs` or
  `docs/plans` files at merge time).

## Risks and assumptions

- R3 is a prefix match. A body paragraph whose first line begins
  `Generated with codex, this change...` would lose that line. Accepted: the
  phrase is the documented attribution footer form, and the existing block
  rule already rejected such lines outright, so the change is strictly more
  permissive than today.
- `Claude-Session:` is the observed key as of Claude Code 2.1.259+
  (confirmed in the leaked commit). If the key changes, R2's generic
  `*session*: https://` alternative is the catch; if the value stops being a
  URL, R2 needs an update.
- The hook runs only where `core.hooksPath` points at the dotfiles hooks dir.
  Repos that override `core.hooksPath` locally, and commits made through
  `--no-verify`, are outside its reach; that is the same reach the existing
  block rules have today.
