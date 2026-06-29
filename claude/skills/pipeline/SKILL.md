---
name: pipeline
description: Run the full spec -> review -> plan -> review -> implement -> review delivery pipeline on a substantial task, driven by Superpowers and a second-model gate. Use when the user asks to "run the pipeline", "take this end to end", "spec-plan-implement this", or sets a /goal for a non-trivial feature/refactor. Codex gates are optional and auto-skipped when codex is absent (e.g. cloud). NOT for small/mechanical changes.
---

# Delivery Pipeline (Superpowers + second-model gate, /goal-driven)

A thin orchestrator over skills that already exist. It sequences them; it does
not reimplement them. Superpowers supplies the engine (worktree, brainstorming,
writing-plans, subagent-driven-development, TDD); a different model (Codex when
available, else a second Claude pass) supplies the review gates.

The native `/goal` command is the autonomy driver: set a goal, then run this
skill, and it walks the phases to a verified end state without per-step
prompting. This skill only defines WHAT the phases are and WHEN to skip them.

## The prime directive: cost must match task size

This pipeline replaced a prior orchestrator that applied full ceremony to every
task and turned 20-minute jobs into hour-long, million-token runs. Do not repeat
that. **Triage scope first and skip phases the task does not earn.** A skipped
phase is a feature, not a shortcut.

### Step 0 — Scope triage (always, before anything else)

Classify the task, state the classification in one line, then route:

- **Trivial** (typo, rename, one-liner, config tweak, <~20 lines, no new
  behavior): skip the pipeline entirely. Make the change, run the relevant
  test/lint, and (if review is wanted) a single `/code-review`. Say you are
  skipping the pipeline and why.
- **Small** (localized change, clear approach, 1-2 files, low risk): skip
  brainstorm + spec + plan. Go straight to implement (TDD) -> single review
  pass. No second-model gate unless the user asks.
- **Substantial** (new feature, cross-cutting refactor, risky migration,
  ambiguous approach): run the full pipeline below.

When unsure between two tiers, pick the lighter one and say so. Escalate only if
the work reveals it was bigger than it looked.

## Phase map (Substantial tasks)

Detect the second-model gate ONCE at the start and reuse the result:

```bash
command -v codex >/dev/null 2>&1 && echo "codex available" || echo "codex absent -> Claude-only gates"
```

| #   | Phase              | Skill                                           | Gate when codex present                   | Gate when codex absent (cloud)                |
| --- | ------------------ | ----------------------------------------------- | ----------------------------------------- | --------------------------------------------- |
| 1   | Isolate            | worktree (see below)                            | -                                         | -                                             |
| 2   | Brainstorm -> spec | `superpowers:brainstorming`                     | -                                         | -                                             |
| 3   | Spec review        | `codex-spec-review`                             | Codex reviews the spec                    | second Claude pass over the spec, same rubric |
| 4   | Plan               | `superpowers:writing-plans`                     | -                                         | -                                             |
| 5   | Plan review        | `codex-plan-review`                             | Codex reviews the plan                    | second Claude pass over the plan              |
| 6   | Implement          | `superpowers:subagent-driven-development` (TDD) | -                                         | -                                             |
| 7   | Final review       | `co-review`                                     | Claude `/code-review` + Codex in parallel | `/code-review` only                           |

### Phase 1 — Isolate

- Real machine: use the Superpowers worktree skill from the start (before the
  first edit), per the worktree default.
- **Ephemeral cloud container** (`CLAUDE_CODE_REMOTE=true`): the container is
  already an isolated, throwaway checkout on a dedicated branch. Do NOT nest a
  worktree inside it -- work directly on the session branch. State which you did.

### Phases 3 & 5 — Review gates, codex-optional

- Codex present: invoke `codex-spec-review` / `codex-plan-review` as written.
- Codex absent: do the SAME review with a fresh Claude pass focused only on the
  artifact (spec or plan) -- hunt ambiguity, missing acceptance criteria,
  ordering, missing tests, risk -- and fold approved fixes back into the
  artifact. Never block waiting on codex; never claim a codex pass happened when
  it did not. Say which gate ran.

### Phase 7 — Final review

Use `co-review` (it already degrades to Claude-only when codex is absent and
caps itself at 2 passes). Do not add review passes beyond what co-review does.

## Gating: human vs autonomous

- **Under an active `/goal`**: the user has opted into autonomy. Run gates
  inline -- apply approved review fixes and proceed to the next phase without
  pausing. Surface a one-line summary per gate so the goal log stays auditable.
- **No goal set** (manual invocation): keep the spec gate (after phase 3) and
  the plan gate (after phase 5) as HUMAN checkpoints -- present findings and
  wait for go/no-go before the next phase. This matches the standing rule that
  spec/plan reviews are human-gated outside the autonomous loop.

## Hard cost guardrails (non-negotiable)

- Triage at Step 0 is mandatory; never run phases 2-5 on Trivial/Small work.
- One review pass per gate. `co-review`'s single bounded re-review is the only
  allowed loop in the whole pipeline.
- Subagents (phase 6) get scoped, single-purpose briefs -- not "read the whole
  repo." Lean on agentic grep/glob search, not a pre-indexed context dump.
- If a phase is ballooning (repeated failed attempts, runaway token use), STOP
  and report where it stuck instead of grinding. A stuck pipeline reports; it
  does not burn the budget down.
- Record a baseline (test counts, lint state) before phase 6 and cite it at the
  close so regressions are visible.

## Close-out

Report: scope tier chosen, which phases ran vs skipped, which gate (codex vs
Claude) was used, baseline vs final test/lint state, and commit hashes. Name any
verification gap explicitly.
