---
description: Generate the next-slice kickoff brief and SAVE it to .claude/handoffs/ so a fresh session can auto-resume with /kickoff (no copy-paste). Not a session-state file -- see /save-session for that.
---

# Handoff Command

Produce a self-contained kickoff brief that a FRESH agent (no memory of this session)
can use to start the next slice of work, then SAVE it so `/kickoff` can resume from it
after `/clear`. The brief is a forward kickoff, not a status report or session dump.

`$ARGUMENTS` (optional): the target slice/phase (e.g. "SEC-01 edge mTLS"). If omitted,
infer the next pending slice from the plan docs.

## Step 1 -- Establish current state (read, do not change anything)

- Branch + whether the just-finished work is merged: `git log --oneline -5`,
  `git ls-remote origin main | head -1`, `gh pr list --state merged --limit 3`.
- What just completed this session (from the conversation + recent commits).
- `git worktree list` -- note any parallel/active worktrees.

## Step 2 -- Find the next slice

Use `$ARGUMENTS` if given. Otherwise discover the next pending unit from, in order:
`docs/PLAN.md` (roadmap/backlog -- first not-done item after the one just finished),
any `*-index.md` under `docs/plans/` (execution order), then the dated `docs/plans/` files.
Note whether the next slice's plan file ALREADY EXISTS or must be WRITTEN first.

## Step 3 -- Collect grounding + gotchas (so the fresh agent doesn't relearn them)

From the project `CLAUDE.md`, project memory (`MEMORY.md` + files), and the working tree:
real reference-doc paths to read first; exact branch base (commit/PR); verified in/out
scope (cite the source); environment hazards that cost time (parallel agents / shared-tree
races -> use a worktree; pre-commit hooks like fact-forcing gates or secret-path blocks;
commit-signing mechanics; the repo's failure mode, e.g. compile-green/runtime-red -> verify
live); and the workflow loop (e.g. Superpowers brainstorm -> writing-plans -> plan review ->
subagent-driven-development -> verification -> co-review -> merge), flagging if a design/
security pass is warranted before code.

## Step 4 -- Compose the kickoff brief

A tight, self-contained brief with this shape (omit inapplicable sections):

```
Start <next slice, one line>. <If it needs a plan/design pass first, say so.>

Context to read first (in order):
  - <real file paths from Steps 2-3>

Branch: create <branch-name> off main (main is at <commit/PR> which includes <what>).

IMPORTANT environment facts (cost real time last slice):
  - <parallel agents / worktree rule>
  - <hooks: fact-forcing gate, secret-path block, etc.>
  - <commit-signing handling for autonomous runs>

Scope (verified -- do not relitigate):
  - In: <...>
  - Out of scope (separate slice): <...>

Method:
  <project workflow loop; flag a security/design pass if relevant>

Verify against the live stack (not just a type/compile check) -- <runtime expectation>.
<test-DB / fixture isolation note>.

When green: <review + merge flow, e.g. requesting-code-review -> /co-review -> resolve -> merge>.
```

## Step 5 -- SAVE it (this is what makes /kickoff work)

- Resolve the MAIN repo root -- the same path from the main checkout OR any linked
  worktree, so `/kickoff` finds the handoff no matter where it later runs:

  ```bash
  GIT_COMMON=$(git rev-parse --git-common-dir)            # shared .git (points at main repo from a worktree)
  case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$(cd "$GIT_COMMON" && pwd)";; esac  # force absolute
  MAIN_ROOT=$(dirname "$GIT_COMMON")
  HANDOFF_DIR="$MAIN_ROOT/.claude/handoffs"
  ```

  Do NOT use `git rev-parse --show-toplevel` -- inside a worktree it returns the
  worktree root, and the handoff lands where `/kickoff` (run from main) won't look.

- Ensure `mkdir -p "$HANDOFF_DIR"`.
- Ignore it locally (do NOT commit handoffs): if `.claude/handoffs/` is not already in
  `"$MAIN_ROOT/.git/info/exclude"`, append it. (Worktrees share this file, so one entry
  covers every worktree.)
- Timestamp + slug: `TS=$(date +%Y-%m-%d-%H%M)`, slug = kebab-case of the slice name.
- Write the brief to BOTH `"$HANDOFF_DIR/$TS-$slug.md"` (history) and overwrite
  `"$HANDOFF_DIR/latest.md"` (the pointer `/kickoff` reads). Prepend a 3-line
  metadata header to each: `generated: <TS>`, `target: <slice>`, `branch-base: <commit/PR>`.

## Step 6 -- Tell the user (briefly)

One or two lines: the saved path, and "After `/clear`, run `/kickoff` to resume -- no
copy-paste." Then print the kickoff brief block once (so they can paste it too if they
prefer). Add one tweak hint, e.g. "say 'plan only' to stop before implementation."

## Rules

- The brief MUST stand alone: a fresh agent with zero context from this session must be
  able to execute it. Inline the facts; never "as discussed".
- Cite REAL paths/commits/PRs verified in Steps 1-3. Never invent file names.
- Prefer the user's conventions (worktrees, dual-reviewer/co-review, TDD, no AI attribution,
  no emojis).
