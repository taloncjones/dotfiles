---
name: writing-specs
description: Use after a design is approved in brainstorming, to write the spec that the spec review gate checks.
---

# Writing Specs

Turn an approved design into a written spec that an independent reviewer can
approve or reject on its own text. The spec is where a wrong safety claim is
cheapest to catch, so this skill forces the questions review passes have
caught late.

Announce at start: "I'm using the writing-specs skill to write the spec."

## Where the spec lives

Write to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` in the MAIN
checkout: the parent of `git rev-parse --path-format=absolute --git-common-dir`.
Never write it inside a linked worktree; `docs/` is gitignored and the copy
dies at teardown. The spec review freezes it with `review.py artifact --repo
<main checkout> --path docs/superpowers/specs/<file>`. Verify code anchors
against the implementation worktree, which may be ahead of the main checkout.

## Required sections

1. Header: status, revision, task id, inputs (PRD, todos, prior specs), base
   commit sha.
2. Intent: the outcome, who it is for, what success looks like.
3. Confirmed facts: each with the grep, file:line or command output that
   confirms it, verified now.
4. Requirements: numbered, each with a testable acceptance criterion.
5. Non-goals.
6. Evidence models (checklist below).
7. Disabled-state re-enable paths (checklist below).
8. Interruption windows and recovery: for each durable write or authority
   transition, the evidence that survives an interruption, every actor that
   can rewrite or delete it, and the recovery.
9. Rollback, including machine state that reverting the commit does not
   restore.
10. Risks and accepted residuals.
11. Revision history (format below).

## Checklist

Answer every item in the spec, even when the answer is "none". Each one is a
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
- **Anchors.** Grep-verify every cited symbol, path and line now. See the anchor rule in `writing-plans`.

## Self-review

Before handing off, reread the spec once:

1. Placeholder scan: no "TBD", "TODO", or vague requirement.
2. Internal consistency: no two sections contradict; the design matches the
   requirements.
3. Scope: small enough for one implementation plan, or decomposed.
4. Ambiguity: any requirement readable two ways gets one reading made
   explicit.
5. The checklist above, item by item.

Fix issues inline.

## Revision history

End the spec with:

```markdown
| Rev | Date | Reviewed artifact SHA-256 | Change and rationale |
```

Each revision after the first records the SHA-256 of the frozen artifact
the previous review saw, and why each change was made. An approval then
traces to the exact bytes reviewed.

## Handoff

Send the spec to the runtime's spec review: `codex-spec-review` in Claude,
`claude-spec-review` in Codex. Fold findings into a new revision, noting any
you decline and why.

- Interactive: ask the human to review the written spec; wait for approval.
- Autonomous or a herdr plan phase: the spec review is the gate.

Then invoke the `writing-plans` skill.
