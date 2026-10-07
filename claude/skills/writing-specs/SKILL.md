---
name: writing-specs
description: Use after a design is approved in brainstorming, to write the PRD that the spec review gate checks and implementation works from.
---

# Writing Specs

Turn an approved design into one PRD: the single planning document an
independent reviewer approves or rejects on its own text and an implementer
works from directly. There is no separate step-by-step plan; the PRD carries
the scope, approach, file layout and acceptance mapping the implementer
needs. The PRD is where a wrong safety claim is cheapest to catch, so this
skill forces the questions review passes have caught late.

Announce at start: "I'm using the writing-specs skill to write the PRD."

## Where the PRD lives

Write to `docs/superpowers/specs/YYYY-MM-DD-<topic>-prd.md` in the MAIN
checkout: the parent of `git rev-parse --path-format=absolute --git-common-dir`.
Never write it inside a linked worktree; `docs/` is gitignored and the copy
dies at teardown. The spec review freezes it with `review.py artifact --repo
<main checkout> --kind spec --path docs/superpowers/specs/<file>`. Verify
code anchors against the implementation worktree, which may be ahead of the
main checkout.

## Ask the owner only what the repo cannot settle

While drafting, ask the owner with `AskUserQuestion` (one prose question in
Codex), recommendation first, only for a decision the repo, the task text
and recorded decisions cannot settle. Batch related questions into one
prompt. Under `/goal` or "be autonomous", never ask, even in a herdr
worker: decide, and record the decision with a one-line rationale under
Owner decisions. Otherwise a herdr plan worker may ask; the wait is a
wanted stop and the director surfaces the blocked pane.

## Required sections

1. Header: status, revision, task id, inputs (todos, prior specs), base
   commit sha.
2. Problem and intent: the outcome, who it is for, what success looks like.
3. **Smallest version**: the smallest change that solves the stated
   problem. Justify each mechanism beyond it, or move it to a follow-up
   todo. Two separable mechanisms are a slice-splitting signal.
4. Confirmed facts: each with the grep, file:line or command output that
   confirms it, verified now.
5. Requirements: numbered, each with a testable acceptance criterion.
6. Non-goals.
7. **Approach**: the chosen design, the alternatives considered and why each
   lost, and a diagram in a fenced block tagged `mermaid`, matched to the
   open question (as-is/to-be for a change to an existing system, an
   architecture plus data-flow view for new work, a sequence or state
   diagram for a hard lifecycle), drawn at implementation altitude.
8. **File layout**: every file created or modified, one line each on its
   responsibility. Follow the codebase's existing patterns.
9. **Test baseline**: suite -> pass/fail counts from an actual run before
   any change, with the command; expected counts after the change as
   arithmetic from the baseline, naming the cases added or removed.
10. **Acceptance mapping**: `| Acceptance criterion | Contract command (or
"human-verify: <evidence>") |`, one row per requirement. In a herdr task
    the commands are the verification contract's.
11. Evidence models, re-enable paths, interruption windows and recovery
    (checklist below).
12. Rollback, including machine state that reverting the commit does not
    restore.
13. **Owner decisions**: each question asked and its answer, or each
    decision made autonomously with its rationale.
14. Risks and accepted residuals.
15. Revision history (format below).

## Checklist

Answer every item in the PRD, even when the answer is "none". Each one is a
defect a second-model review caught late in this repo.

- **Evidence models.** Enumerate every set of durable artifacts the change
  introduces or newly consults for an authority decision, and say whether it
  duplicates one that already exists. More than one is a slice-splitting
  signal; either split or justify accepting it.
- **Re-enable paths.** For anything shipped disabled or retired, enumerate
  every path that could turn it back on: a restore, a hand-edit, a
  downgrade, a higher-precedence config layer, a process still running the
  old code. Mark each handled or an accepted residual.
- **Shape cross-check.** Check every record, schema and field against every
  requirement elsewhere in the same document. A timestamp field in a record
  that must be byte-identical across reruns is the classic miss.
- **Confirmed vs proposed.** Label each claim. A proposed property stated as
  a fact is how a false safety claim reaches review.
- **Interruption windows.** For each durable write or authority transition,
  the evidence that survives an interruption, every actor that can rewrite
  or delete it, and the recovery.
- **Anchors.** Never cite a symbol, file:line, test name, or count from memory or from a prior draft.
  Re-grep every anchor and re-run every baseline while writing.

This is the anchor rule other planning skills refer to.

## Self-review

Before handing off, reread the PRD once:

1. Placeholder scan: no "TBD", "TODO", or vague requirement.
2. Internal consistency: no two sections contradict; the approach meets
   every requirement.
3. Scope: the smallest version is stated and every extra mechanism is
   justified; otherwise split.
4. Ambiguity: any requirement readable two ways gets one reading made
   explicit.
5. Every requirement has an acceptance-mapping row.
6. The checklist above, item by item.

Fix issues inline.

## Revision history

End the PRD with:

```markdown
| Rev | Date | Reviewed artifact SHA-256 | Change and rationale |
```

Each revision after the first records the SHA-256 of the frozen artifact
the previous review saw, and why each change was made. An approval then
traces to the exact bytes reviewed.

## Handoff

Send the PRD to the runtime's spec review: `codex-spec-review` in Claude,
`claude-spec-review` in Codex. Fold findings into a new revision, noting any
you decline and why. That review is the only planning review.

- Interactive: ask the human to approve the reviewed PRD and pick the
  execution method (the `Workflow` tool with per-task review, or inline);
  wait.
- Autonomous: the spec review is the gate; proceed to implementation.
- Herdr plan phase: freeze the PRD and the contract, emit the completion
  record, and stop. The implement phase is a separate dispatch.

`writing-plans` runs only when the owner asks for a task-by-task plan.
