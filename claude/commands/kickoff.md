---
description: Resume the next work slice from the saved handoff (.claude/handoffs/latest.md) -- the no-copy-paste counterpart to /handoff. Re-verifies live git state before acting.
---

# Kickoff Command

Resume work from the kickoff brief that `/handoff` saved, after a `/clear`. Do NOT
blindly trust the file -- it was written in a prior session and the world may have
moved (main advanced, a parallel agent merged, the branch base changed). Re-verify,
reconcile, then execute.

## Step 1 -- Load the handoff

- Resolve the MAIN repo root the same way `/handoff` does, so the canonical location
  matches from the main checkout OR any linked worktree:

  ```bash
  GIT_COMMON=$(git rev-parse --git-common-dir)            # shared .git (points at main repo from a worktree)
  case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$(cd "$GIT_COMMON" && pwd)";; esac  # force absolute
  MAIN_ROOT=$(dirname "$GIT_COMMON")
  HANDOFF_DIR="$MAIN_ROOT/.claude/handoffs"
  ```

  Read `"$HANDOFF_DIR/latest.md"` -- this is the canonical pointer.

- **Fallback scan (safety net).** If `"$HANDOFF_DIR/latest.md"` is missing, a handoff
  written by older code (or from another tree) may be sitting in a worktree. `git worktree
list` already includes the main checkout as its first entry, so scanning it alone covers
  every tree. Pick the `latest.md` with the newest `generated:` header, and SAY which tree
  it came from before resuming:

  ```bash
  for d in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
    [ -f "$d/.claude/handoffs/latest.md" ] && echo "$d/.claude/handoffs/latest.md"
  done
  ```

- If no `latest.md` exists in ANY tree: stop and say so -- tell the user to run
  `/handoff` in the session that produced the work (or pass a path/paste the brief).
  Do nothing else.
- Read the brief in full, including its `generated/target/branch-base` header.

## Step 2 -- Re-verify live state (read-only)

- `git log --oneline -5`, current branch (`git branch --show-current`).
- `git fetch origin --quiet` then `git rev-parse origin/main` (or `git ls-remote origin main`).
- `git worktree list` -- detect active/parallel worktrees and which branch the shared
  tree is on.
- `git status --short` -- is the tree clean?
- Spot-check that the reference files the brief lists still exist.

## Step 3 -- Reconcile drift (report in 2-3 lines)

Compare the brief's assumptions to reality and state any divergence plainly:

- **branch-base moved** (origin/main != the brief's base) -> branch off CURRENT main; note it.
- **parallel worktree / shared tree on another branch** -> plan to work in an isolated
  worktree; never branch-switch the shared tree.
- **referenced plan/doc paths missing or renamed** -> surface before proceeding.
- **target already done** (e.g. a PR for it merged) -> stop and ask; don't redo it.

If anything material diverges or is ambiguous, summarize and ask the user before acting.
If it lines up cleanly, proceed.

## Step 4 -- Execute

Treat the brief's body as the task. Follow the project's workflow loop and conventions
named in it (worktree isolation, TDD, dual-reviewer/co-review, the live-stack verification
expectation). Honor the brief's "plan only" / scope hints if present. Begin.

## Rules

- The live repo wins on facts; the handoff is intent, not ground truth.
- Use an isolated worktree if any parallel agent / shared-tree contention exists.
- Do not delete the handoff file; leave it for reference (it is gitignored).
