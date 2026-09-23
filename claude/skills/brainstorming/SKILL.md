---
name: brainstorming
description: Use before creative or behavior-changing work - features, components, new behavior - to agree intent and design before any implementation.
---

# Brainstorming

Turn an idea into a design the human can recognize and correct, grounded in
what they want to accomplish. The output is an agreed design, not code.

## Establish shared understanding

1. Discover intent: the outcome, who it is for, what success looks like.
   When that is missing, ask one focused question about purpose before
   proposing features.
2. Write back your understanding in a short note: intended outcome,
   constraints, success criteria, and which parts are assumptions. Invite
   correction.
3. Carry that understanding into the design artifact and check each
   proposed choice against it.

When the request already states purpose and constraints, reflect them back
instead of asking again.

<HARD-GATE>
Take no implementation action -- no implementation skill, product code,
scaffolding, dependency install, or external project -- until the selected
path's prerequisites are complete:

- Spike: the human approves the question and the probe.
- Bounded: the human approves the short in-chat design.
- Architectural: the human approves the written spec, then reviews the
  written plan and picks its execution method. Approving the conversational
  design only permits writing the spec; approving the spec only permits
  writing the plan.

A reply approves the stage actually presented, nothing later. Read-only
exploration is allowed before approval.
</HARD-GATE>

## Classify first

Say the classification out loud so it can be overridden.

- **Spike** -- a feasibility question whose output is an answer, not kept
  code. State the question and the probe in 2-3 sentences, get a nod,
  investigate as cheaply as correctness allows, report a recommendation.
  Anything built is labeled throwaway.
- **Bounded** -- a well-scoped change to a flow that already exists in this
  repo: a flag, a small endpoint, a one-file fix. Ask the questions that
  matter, present a short design in chat (approach, files, tests), and stop
  until the human says yes. No spec file, no plan document.
- **Architectural** -- a new project or subsystem, or a change to how
  components fit together or to an interface others depend on. Full
  process below.

When unsure, take the heavier path. Complexity discovered mid-task upgrades
the path; nothing downgrades.

## Architectural path

1. Explore the project: files, docs, recent commits, and any PRD or prior
   spec (treat it as input, not as the spec). Code facts you cite follow the anchor rule in `writing-plans`.
2. Ask clarifying questions one at a time, multiple choice where possible.
   If the request spans independent subsystems, decompose first and design
   the first piece.
3. Propose 2-3 approaches with trade-offs, recommended one first.
4. Present the design in sections sized to their complexity (architecture,
   components, data flow, error handling, testing) and get approval per
   section.
5. Once the design is approved, invoke the `writing-specs` skill with it.
   That skill writes the spec file, runs its checklist, and sends it to the
   spec review. Brainstorming never writes the spec file itself.

Design for isolation: units with one purpose and a clear interface that can
be understood and tested alone. In an existing codebase, follow its
patterns; include a targeted improvement only where the current structure
gets in the way of this change.

## Autonomous mode

Under `/goal`, "be autonomous", or a herdr worker brief, no human answers
the gates. Classify and announce the path anyway, make each design decision
yourself with a one-line rationale, and record those decisions in the spec.
The runtime's review gate replaces each human gate: `codex-spec-review` or
`codex-plan-review` in Claude, `claude-spec-review` or `claude-plan-review`
in Codex. Surface a brief status at each gate without blocking on it.
