---
name: voice
description: Use before posting any outward-facing text an agent wrote (PR title or body, PR comment, Jira title, description, or comment, code comment or docstring) to run an independent voice pass with Codex. Trigger on "voice pass", "de-generify this", "make this sound human", "check this PR body". Returns a rewrite plus what changed and why; never posts, edits, or commits on its own.
---

# Voice (independent prose pass)

This skill sends the text to a fresh Codex session (`gpt-6-astra`) with the
shared style rules and shows the before/after for a human to approve. It
works from Claude or Codex; an Astra author gets a separate context, which
does not provide different-model independence. The script never posts.

## Usage

```bash
V="${CODEX_HOME:-$HOME/.codex}/skills/voice/scripts/voice.py"
if [ ! -f "$V" ]; then
  V="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/voice/scripts/voice.py"
fi
python3 "$V" lint    --kind pr-body --file body.md          # mechanical checks only, no model
python3 "$V" rewrite --kind pr-body --file body.md          # Codex rewrite + report
python3 "$V" rewrite --pr 123                               # title and body via gh pr view
python3 "$V" rewrite --kind code-comment --range src/x.py:40-52
printf '%s' "$TEXT" | python3 "$V" rewrite --kind jira-comment --stdin
```

The resolver uses the installed Codex skill when present, then the selected
Claude config directory. Both runtimes use the same script and rules. When
reading a source checkout directly, use its loaded skill directory instead.
The child preserves the caller's selected `CODEX_HOME`.

Kinds: `pr-title`, `pr-body`, `pr-comment`, `jira-title`, `jira-description`,
`jira-comment`, `code-comment`. Flags: `--effort high|xhigh` (default high),
`--dry-run` (print the prompt, do not call Codex), `--json` (array of report
objects). Exit `0` nothing to change, `1` rewrite proposed, `2` error.

## Steps

1. Pick the kind from the table above. For Jira fields, fetch the text via
   the MCP Jira tools (`getJiraIssue` for summary/description) and pipe it
   in with `--stdin`; the script has no Jira access by design.
2. Run `rewrite`. Show the report verbatim: diff, numbered changes with
   rules, protected lines, and the `Apply with` block.
3. Ask for approval in one line. Do not apply without a yes.
4. Apply with the printed command (`gh pr edit ...`, the MCP update call,
   or paste the after block). For `code-comment`, apply the line
   replacements with Edit, one line at a time.
5. `unchanged`: say so in one line and post the original.
6. Exit `2` with `invariant violated`: Codex dropped a URL, ticket key,
   code span, or protected line. Do not hand-merge; re-run once, then
   post the original and say the pass was skipped.

## What it protects

- URLs and ticket keys always; fenced blocks for comments and bodies;
  inline code spans for bodies and descriptions.
- Code lines and load-bearing comments in a `--range`: a comment whose
  text appears elsewhere in the repo, or a docstring the repo reads via
  `__doc__`, `getdoc(`, or `.doc`, is sent as `protected` and must come
  back byte-identical. The report names the evidence so you can overrule.

## Call sites

Wiring is a follow-up task. Each row is one edit: before the outward
write, run `rewrite --kind <k>` on the text, show before/after, wait for
approval.

| call site                                                                 | kind                         | text fed                       |
| ------------------------------------------------------------------------- | ---------------------------- | ------------------------------ |
| `claude/commands/pr.md`, before `gh pr create`                            | pr-title, pr-body            | the title and the heredoc body |
| `claude/commands/jira.md`, `comment`                                      | jira-comment                 | the comment text               |
| `claude/skills/ship/SKILL.md`, step 4 summary and any PR comment it posts | pr-comment                   | the comment body               |
| `claude/skills/post-merge/SKILL.md`, step 4 resolution comment            | jira-comment                 | the resolution comment         |
| Herdr reviewer brief findings summary (the `co-review` report comment)    | pr-comment                   | the findings summary           |
| Jira ticket creation (`/start`, `reconcile` backfill)                     | jira-title, jira-description | summary and description        |

## Notes

- Runs Codex in an empty scratch dir with a read-only sandbox and no
  approvals; the prompt names no tools or skills, so it cannot recurse
  into a Claude shell-out. Confirm on first live use: the `codex.log`
  path printed on failure (or `--json` event output) should show no
  command execution.
- `lint` alone is deterministic and free; use it in a hurry.
- Each `rewrite` keeps its prompt, schema, Codex log, and any body file
  under a `$TMPDIR/voice.*` directory so the printed paths stay valid
  after the run. Nothing cleans them up; `rm -rf "${TMPDIR:-/tmp}"/voice.*`
  when they pile up.
- Tests: `bash claude/skills/voice/scripts/tests/voice_test.sh` (fakes
  replace Codex and gh; no network).
