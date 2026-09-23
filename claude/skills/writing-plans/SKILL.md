---
name: writing-plans
description: Use when a reviewed spec or clear requirements exist for a multi-step change, before touching code.
---

# Writing Plans

Write an implementation plan an engineer with no context for this repo can
execute task by task: which files each task touches, the code, the tests,
the commands and the expected output. DRY, YAGNI, test-first, frequent
commits.

Announce at start: "I'm using the writing-plans skill to create the
implementation plan."

## Where the plan lives

Save to `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md` in the MAIN
checkout: the parent of `git rev-parse --path-format=absolute --git-common-dir`.
`docs/` is gitignored, so a copy inside a linked worktree dies at teardown.
The plan review freezes it with `review.py artifact --repo <main checkout>
--path docs/superpowers/plans/<file>`; verify code anchors against the
implementation worktree.

## Scope check

If the spec covers independent subsystems, propose one plan per subsystem.
Each plan ends in working, testable software on its own.

## File structure first

Map every file created or modified and its single responsibility before
defining tasks. Follow the codebase's existing patterns; split a file only
when the one you must change has grown unwieldy.

## Task right-sizing

A task is the smallest unit with its own test cycle that a reviewer could
reject while approving its neighbor. Fold setup, config and docs into the
task whose deliverable needs them. Each step is one 2-5 minute action:
write the failing test, run it and see it fail, implement, run it and see it
pass, commit.

## Plan header

Every plan starts with:

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** execute task by task. In this repo: a herdr
> implement phase, the `Workflow` tool with per-task review, or inline in
> one session. Steps use checkbox (`- [ ]`) syntax.

**Goal:** [one sentence]

**Architecture:** [2-3 sentences]

**Tech Stack:** [key technologies]

**Spec:** [path to the spec this plan implements]

## Global Constraints

[The spec's project-wide requirements, one line each, values copied
verbatim. Every task implicitly includes them.]

## Review Focus

[The five inputs or failure modes the spec implies that no task's tests
exercise, most likely first. Then add the test that pins each one to the
task that owns the code.]

## Test Baseline

[Suite -> pass/fail counts from an actual run before any change, with the
command. Every expected post-change count is baseline plus or minus named
cases, shown as arithmetic.]
```

After the header, add a diagram in a fenced block tagged `mermaid`, matched
to the open question: as-is/to-be for a change to an existing system, an
architecture plus data-flow view for new work, a sequence or state diagram
for a component with a hard lifecycle. Draw it at implementation altitude.

When the task carries a herdr verification contract, add:

```markdown
## Acceptance Mapping

| Acceptance criterion | Contract command (or "human-verify: <evidence>") |
```

Every criterion maps to a command or to named human-verify evidence.

## Task structure

```markdown
### Task N: [Component]

**Files:**

- Create: `exact/path`
- Modify: `exact/path:start-end` (re-grepped when written)
- Test: `exact/test/path`

**Interfaces:**

- Consumes: [exact names and signatures from earlier tasks]
- Produces: [exact names and signatures later tasks rely on]

- [ ] **Step 1: Write the failing test** (full test code)
- [ ] **Step 2: Run it to see it fail** (command, expected failure)
- [ ] **Step 3: Implement** (full code)
- [ ] **Step 4: Run it to see it pass** (command, expected output)
- [ ] **Step 5: Commit** (exact `git add` paths and message)
```

## No placeholders

These are plan failures: "TBD", "TODO", "implement later"; "add error
handling" or "handle edge cases" without the code; "write tests for the
above" without the tests; "similar to Task N" (repeat it; tasks are read out
of order); a step that says what without showing how; a name no task
defines.

## Self-review

Run this yourself after writing the plan, with the spec open. Fix issues
inline.

1. Spec coverage: point to the task for every requirement; add a task for
   any gap.
2. Placeholder scan against the list above.
3. Name consistency: every function, file and field name matches across
   tasks.
4. Review Focus: every line has its pinning test in the owning task. An
   empty section means you checked and found none.
5. Anchors and counts. Never cite a symbol, file:line, test name, or count from memory or from a prior draft.
   Re-grep every anchor and re-run every baseline while writing. State each
   expected count as arithmetic from the recorded baseline, and name the
   cases added or removed.

This is the anchor rule other planning skills refer to.

## Plan review and handoff

Hand the saved plan to the runtime's plan review: `codex-plan-review` in
Claude, `claude-plan-review` in Codex. Fold findings back, keep a short
revision note in the plan, and re-freeze.

- Interactive: link the plan, ask the human to review it and choose the
  execution method (the `Workflow` tool with per-task review for several
  interdependent tasks, or inline for a small plan), and wait.
- Autonomous (`/goal`, "be autonomous"): the plan review is the gate; fold
  its findings and proceed.
- Herdr plan phase: freeze the final spec and plan, emit the completion
  record, and stop. The implement phase is a separate dispatch.
