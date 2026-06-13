---
name: codex-spec-review
description: Use after finalizing a spec/PRD (e.g. just after superpowers:brainstorming or plan-prd, before superpowers:writing-plans) to get an independent Codex (different-model) review of the requirements before any plan is written. Reviews docs/specs/*.md (or PRD), surfaces ambiguity/contradictions/missing-acceptance-criteria/scope/unstated-assumptions, and folds approved fixes back into the spec.
---

# Codex Spec Review

Get a **second-model** review of a finalized spec/PRD, targeting the _requirements
themselves_ rather than the approach. This is the highest-leverage review point:
a spec defect is the cheapest to fix and the most expensive to miss, because it
propagates through plan -> code -> tests. This runs on the spec _document_, before
any plan is written.

The companion `codex-plan-review` skill anchors on the spec as fixed and judges
the _plan_. This skill does the opposite: it interrogates the spec and assumes
nothing is settled. Different artifact, different failure mode.

## When to use

- Right after a spec/PRD is finalized (after `superpowers:brainstorming` or
  `plan-prd`), before `superpowers:writing-plans`.
- Whenever the user asks to "have Codex review the spec" or "second-opinion the
  requirements".

Skip if there is no written spec artifact (informal in-chat requirements have
nothing to bite on — sharpen the plan review instead), or the user explicitly
declined an external review.

## Steps

1. **Resolve the spec file.**
   - If the user passed a path, use it.
   - Else pick the newest `*.md` from the first directory that exists, in order:
     `docs/specs/`, `docs/superpowers/specs/`, `docs/prd/`, `docs/requirements/`.
   - Confirm the resolved path with the user in one line before spending tokens.

2. **Gather optional sibling context** (only what exists — all path-optional, so
   this stays project-agnostic):
   - Any linked design/brainstorming doc under `docs/` (`design/`, `reference/`).
   - The repo `docs/PLAN.md` or product brief, if present.
   - The root `CLAUDE.md` for project conventions and constraints.

3. **Run Codex non-interactively** from inside the repo (it must be a git/trusted
   dir; `approval: never`, `sandbox: workspace-write` are already configured):

   ```bash
   codex exec "$(cat <<'PROMPT'
   You are an expert staff engineer / product reviewer reviewing a SPEC (the
   requirements) before any implementation plan is written. Do NOT propose an
   architecture or rewrite the spec; interrogate the requirements. Be terse and
   specific. Assume nothing in the spec is settled.

   For each issue return: SEVERITY (critical|high|medium|low), the spec
   section/line, the problem, and a concrete fix. Review for:
   - Ambiguity: requirements open to more than one reading; vague terms with no
     definition ("fast", "secure", "intuitive").
   - Completeness: missing requirements, unhandled states, gaps a builder would
     have to guess at.
   - Testability / acceptance: requirements with no measurable acceptance
     criteria; success conditions that cannot be verified.
   - Contradiction: requirements that conflict with each other or with stated
     constraints.
   - Scope: in/out-of-scope not delimited; scope creep; gold-plating.
   - Unstated assumptions and risks (data, privacy, migrations, irreversible ops,
     external dependencies).
   - Edge cases the spec never names (empty/null, limits, failure, concurrency,
     permissions).
   - Drift: contradictions with the project's CLAUDE.md / brief conventions.
   End with a one-line VERDICT: ready-to-plan | minor-fixes | needs-rework.

   === SPEC FILE: <path> ===
   <spec contents>

   === CONTEXT (optional, may be absent) ===
   <design / brief / CLAUDE.md excerpts>
   PROMPT
   )" -c model_reasoning_effort="high" </dev/null 2>&1
   ```

   - Pass file contents inline in the prompt (Codex can also read the repo, but
     inlining is deterministic).
   - Redirect `</dev/null` so Codex does not block reading stdin.
   - The useful output is the final `codex` message block (after the run header,
     before `tokens used`). Ignore any MCP/network warning lines.

4. **Present findings** as one deduped, severity-sorted list. Each item: severity,
   spec location, problem, proposed fix.

5. **Resolve (triage-first).** Ask which to apply; default is "all". Fold approved
   fixes into the spec file with Edit. Re-state the Codex VERDICT so the user knows
   whether to proceed to planning.

## Notes

- This is Codex-only by design, and it reviews the spec, not the plan or the code.
  - For reviewing a finalized _plan_, use `codex-plan-review`.
  - For reviewing _code changes_ with Claude **and** Codex in parallel, use
    `co-review`.
- Keep it cheap: one `codex exec` call. Do not loop unless the user asks.
