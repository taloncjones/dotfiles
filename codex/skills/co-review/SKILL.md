---
name: co-review
description: Use when reviewing a local code change or pull request with both Codex and Claude before fixing findings.
---

# Co-Review

Run an internal Codex review in the current session plus an external Claude
review over the same target, merge the findings, then resolve approved fixes
once.

## Target

- If the user passed a PR number or URL, review that PR.
- Otherwise review the local working diff. Include staged, unstaged, and
  untracked changes.
- If there is no local diff and no PR target, stop.

State the target in one line before running reviewers.

## Codex Review

Review the target yourself in the current Codex session using the normal code
review stance: findings first, ordered by severity, focused on bugs,
regressions, security risks, data loss, broken tests, and missing tests.

Do not launch `codex review` from inside Codex. That would create a redundant
nested Codex reviewer and can fail on local app-server/session state.

## Claude Review

Use Claude's native code review command:

```bash
# Local working diff
claude -p "/code-review" </dev/null

# PR mode
claude -p "/code-review <pr-number-or-url>" </dev/null
```

**ALWAYS call the native `/code-review`. NEVER hand Claude a generic review
prompt** (`claude -p "review this diff..."`) **or ask Claude to run its
`co-review` skill.** Native `/code-review` is a single-pass built-in that does
not call Codex back; a generic prompt or the co-review skill would bounce the
review back into Codex (a Codex -> Claude -> Codex loop). This mirrors the Claude
side, which calls Codex only via the dedicated `codex exec review` subcommand —
each orchestrator reviews natively and calls the partner's dedicated,
non-recursive review command, never a generic agent.

If `/code-review` is unavailable in the active Claude install, fall back to an
inline diff prompt using `git diff --cached`, `git diff`, and
`git ls-files --others --exclude-standard` for local context. For PRs, use
`gh pr diff` and `gh pr view` when available.

## Merge Findings

- Verify each finding against the code before reporting it.
- Dedupe by `file:line + issue`.
- Tag source as `[both]`, `[codex]`, or `[claude]`.
- Sort by severity; `[both]` first within a severity tier.
- Present findings first. If none, say so explicitly.

## Resolve

- Ask which findings to fix; default is all confirmed non-low findings.
- Apply approved fixes only after triage.
- Run relevant tests, lint, typecheck, or build.
- Do not post PR comments, push, or publish unless the user explicitly asks.

## Stop Conditions

- The diff is empty.
- Claude cannot run; report the command failure and continue with the internal
  Codex review unless the user asked to stop on external-review failure.
