---
description: Resume the next work slice from the saved handoff (.claude/handoffs/latest.md) -- the no-copy-paste counterpart to /handoff. Re-verifies live git state before acting.
---

# Kickoff Command

Resume work from the kickoff brief that `/handoff` saved, after a `/clear`. Do NOT
blindly trust the file -- it was written in a prior session and the world may have
moved (main advanced, a parallel agent merged, the branch base changed). Re-verify,
reconcile, then execute.

## Step 1 -- Load the handoff

- Resolve where `/handoff` writes (the canonical location), for your drift report:

  ```bash
  GIT_COMMON=$(git rev-parse --git-common-dir)            # shared .git (points at main repo from a worktree)
  case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$(cd "$GIT_COMMON" && pwd)";; esac  # force absolute
  MAIN_ROOT=$(dirname "$GIT_COMMON")                      # canonical handoffs: $MAIN_ROOT/.claude/handoffs
  ```

- Pick the NEWEST handoff across ALL trees -- do NOT just trust the canonical path. A
  handoff written by older `/handoff` code (which saved into a worktree root) can be newer
  than a stale `latest.md` sitting at the main root; "newest `generated:` wins". `git worktree
list` already includes the main checkout as its first entry, so one scan covers the canonical
  location and every worktree:

  ```bash
  PICK=$(for d in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
    f="$d/.claude/handoffs/latest.md"
    [ -f "$f" ] && printf '%s\t%s\n' "$(awk -F': ' '/^generated:/{print $2; exit}' "$f")" "$f"
  done | sort -r | head -1 | cut -f2)
  ```

- If `PICK` is empty (no `latest.md` in ANY tree): stop and say so -- tell the user to run
  `/handoff` in the session that produced the work (or pass a path/paste the brief). Do
  nothing else.
- If `PICK` is NOT under `$MAIN_ROOT/.claude/handoffs` (it came from a worktree), SAY which
  tree it came from before resuming.
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
