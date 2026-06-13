---
name: wrap
description: Use when the user is ending a session and wants the exit state verified instead of being asked "anything else?". Trigger on "good to exit", "are we done", "wrap up", "closing out", "done for the day".
---

# Wrap (session exit check)

Answer "good to exit?" with evidence, not a question back. Sweep, give a
verdict, offer one-shot fixes for anything left.

## Checks (read-only)

Run in parallel where possible, covering every repo/worktree touched this
session:

1. **Working tree** — `git status --short --branch --untracked-files=all`.
   Dirty files? Untracked files created this session? For whitelist-ignored
   dirs (e.g. `claude/skills/.gitignore`), run `git check-ignore` on files
   created this session — silently-ignored new files are a known trap.
2. **Unpushed work** — ahead-of-upstream count on every branch touched this
   session.
3. **Leftovers** — stale worktrees (`git worktree list`), `/tmp/coreview-*`
   dirs/logs, scratch refs (`refs/coreview/*`).
4. **Background work** — shells, tasks, or agents started this session that
   are still running.
5. **Session promises** — follow-ups stated in conversation but not done
   (deferred findings, "later", "next time"). Anything real gets filed per
   tracking rules (Jira for work, repo todos otherwise) — not left implicit.

## Verdict

- **All clean:** "Good to exit." plus one line of state (branch == origin,
  tree clean). Stop there — no questions.
- **Items found:** numbered list with a fix plan. Ask once, "fix all" default.
  Apply, re-verify, then give the verdict.

## Notes

- Read-only until fixes are approved — pushing is a fix, not a check.
- Keep the clean-path output under 5 lines. This skill exists to remove the
  "anything else?" round-trip, not add one.
- Scoped to the session, not the world: do not audit unrelated repos or
  long-standing drift (that's `reconcile`).
