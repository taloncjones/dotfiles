---
name: claude-plan-review
description: Use when Codex has finalized an implementation plan and needs an independent Claude review before code execution begins.
---

# Claude Plan Review

Use this after `superpowers-writing-plans` and before `superpowers-executing-plans`.
Codex already wrote or accepted the plan; this adds a second-model review from
Claude before implementation starts.

## Target

1. If the user passed a plan path, use it.
2. Otherwise choose the newest plan-like file from the first existing location:
   `docs/plans/`, `docs/superpowers/specs/`, `.planning/`, `~/.claude/plans/`.
3. State the resolved path before running the review.

## Review Command

Inline the plan contents so the review is deterministic:

```bash
claude -p "$(cat <<'PROMPT'
You are an expert staff engineer reviewing an IMPLEMENTATION PLAN before code is
written. Be terse and specific. Do not rewrite the plan.

For each issue return:
- SEVERITY: critical, high, medium, or low
- LOCATION: plan section or line
- PROBLEM: what is wrong or missing
- FIX: concrete change to the plan

Review for:
- Missing or hand-waved steps
- Unsafe ordering or hidden dependencies
- Missing test-first coverage
- Steps too large to implement and verify in one pass
- Unstated assumptions, rollback gaps, migration/data-loss risks
- Drift from project AGENTS.md, CLAUDE.md, README, or plan conventions

End with:
VERDICT: ship-as-is | minor-fixes | needs-rework

=== PLAN FILE: <path> ===
<plan contents>

=== OPTIONAL CONTEXT ===
<relevant AGENTS.md / CLAUDE.md / README / spec excerpts>
PROMPT
)" </dev/null
```

Use `--permission-mode dontAsk --tools ""` if Claude tries to use tools instead
of reviewing the inline content.

## Report And Resolve

- Present Claude findings as a severity-sorted list.
- Verify findings against the plan before relaying them.
- Ask which fixes to apply; default is all non-low findings.
- Patch the plan only after user approval.
- Re-state Claude's verdict and whether the plan is ready for execution.

## Stop Conditions

- No plan file exists.
- The user declined second-model review.
- Claude cannot run locally; report the command failure and do not invent review findings.
