---
name: claude-spec-review
description: Use when Codex has finalized a design/spec document and needs an independent Claude review before writing an implementation plan.
---

# Claude Spec Review

Use this after a spec is written and self-reviewed, before `superpowers:writing-plans`.
Codex already wrote or accepted the spec; this adds a second-model review from
Claude while the work is still cheap to reshape.

## Target

1. If the user passed a spec path, use it.
2. Otherwise choose the newest spec-like file from the first existing location:
   `docs/superpowers/specs/`, `docs/specs/`, `docs/design/`, `.planning/`.
3. State the resolved path before running the review.

## Review Command

Inline the spec contents so the review is deterministic:

```bash
claude -p "$(cat <<'PROMPT'
You are an expert staff engineer reviewing a DESIGN SPEC before an implementation
plan is written. Be terse and specific. Do not rewrite the spec.

For each issue return:
- SEVERITY: critical, high, medium, or low
- LOCATION: spec section or line
- PROBLEM: what is wrong or missing
- FIX: concrete change to the spec

Review for:
- Ambiguous requirements or success criteria
- Missing constraints, non-goals, or edge cases
- Hidden dependencies on unavailable services, hardware, data, or credentials
- Missing validation strategy for the user-visible behavior
- Design choices that conflict with project AGENTS.md, CLAUDE.md, README, docs/PLAN.md, or conventions
- Scope that is too large for one implementation plan
- Security, safety, rollback, or data-loss risks that should be designed before planning

End with:
VERDICT: ship-as-is | minor-fixes | needs-rework

=== SPEC FILE: <path> ===
<spec contents>

=== OPTIONAL CONTEXT ===
<relevant AGENTS.md / CLAUDE.md / README / docs/PLAN.md excerpts>
PROMPT
)" </dev/null
```

Use `--permission-mode dontAsk --tools ""` if Claude tries to use tools instead
of reviewing the inline content.

## Report And Resolve

- Present Claude findings as a severity-sorted list.
- Verify findings against the spec before relaying them.
- Ask which fixes to apply; default is all non-low findings.
- Patch the spec only after user approval.
- Re-state Claude's verdict and whether the spec is ready for plan writing.

## Stop Conditions

- No spec file exists.
- The user declined second-model review.
- Claude cannot run locally; report the command failure and do not invent review findings.
