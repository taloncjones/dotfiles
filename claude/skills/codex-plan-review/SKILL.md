---
name: codex-plan-review
description: Use after finalizing an implementation plan (e.g. just after superpowers:writing-plans, before executing-plans) to get an independent Codex (different-model) review of the plan file before any code is written. Reviews docs/plans/*.md, surfaces gaps/ordering/missing-tests/risks, and folds approved fixes back into the plan.
---

# Codex Plan Review

Get a **second-model** review of a finalized implementation plan. The Superpowers
`writing-plans` flow already ran a Claude review pass, so this adds the only thing
missing: an independent reviewer (Codex / a non-Claude model) that catches what
Claude's own blind spots miss. This runs on the plan _document_, before any code.

## When to use

- Right after a plan is written (after `superpowers:writing-plans`), before
  `superpowers:executing-plans`.
- Whenever the user asks to "have Codex review the plan" or "second-opinion the plan".

Skip if there is no plan file, or the user explicitly declined an external review.

## Steps

1. **Resolve the plan file.**
   - If the user passed a path, use it.
   - Else pick the newest `*.md` from the first directory that exists, in order:
     `docs/plans/`, `docs/superpowers/specs/`, `~/.claude/plans/`.
   - Confirm the resolved path with the user in one line before spending tokens.

2. **Gather optional sibling context** (only what exists — all path-optional, so
   this stays project-agnostic):
   - The repo `docs/PLAN.md` (the living plan, if present).
   - Any spec the plan links to under `docs/` (`reference/`, `design/`, `specs/`).
   - The root `CLAUDE.md` for project conventions.

3. **Run Codex non-interactively** from inside the repo (it must be a git/trusted
   dir; `approval: never`, `sandbox: workspace-write` are already configured):

   ```bash
   codex exec "$(cat <<'PROMPT'
   You are an expert staff engineer reviewing an IMPLEMENTATION PLAN before any
   code is written. Be terse and specific. Do NOT rewrite the plan; list issues.

   For each issue return: SEVERITY (critical|high|medium|low), the plan
   section/line, the problem, and a concrete fix. Review for:
   - Gaps: steps that are missing, hand-waved, or assume work not in the plan.
   - Ordering / dependencies: steps that depend on later steps; unsafe sequencing.
   - Test coverage: missing tests, untestable steps, steps not written test-first.
   - Bite-size: steps too large to implement+verify in one pass.
   - Unstated assumptions and risks (data loss, migrations, irreversible ops).
   - Drift: contradictions with the project's PLAN.md / CLAUDE.md conventions.
   End with a one-line VERDICT: ship-as-is | minor-fixes | needs-rework.

   === PLAN FILE: <path> ===
   <plan contents>

   === CONTEXT (optional, may be absent) ===
   <PLAN.md / spec / CLAUDE.md excerpts>
   PROMPT
   )" -c model_reasoning_effort="high" </dev/null 2>&1
   ```

   - Pass file contents inline in the prompt (Codex can also read the repo, but
     inlining is deterministic).
   - Redirect `</dev/null` so Codex does not block reading stdin.
   - The useful output is the final `codex` message block (after the run header,
     before `tokens used`). Ignore any MCP/network warning lines.

4. **Present findings** as one deduped, severity-sorted list. Each item: severity,
   plan location, problem, proposed fix.

5. **Resolve (triage-first).** Ask which to apply; default is "all". Fold approved
   fixes into the plan file with Edit. Re-state the Codex VERDICT so the user knows
   whether to proceed to execution.

## Notes

- This is Codex-only by design. For reviewing _code changes_ with Claude **and**
  Codex in parallel, use the `co-review` skill instead.
- Keep it cheap: one `codex exec` call. Do not loop unless the user asks.
