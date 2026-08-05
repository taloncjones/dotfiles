---
name: model-tuning
description: Per-model tuning deltas for current Claude models (Opus 4.8, Sonnet 5, Fable 5) plus the model-retirement playbook. Use when authoring or pruning skills, subagent prompts, Workflow scripts, or API calls that pin a model, set effort or thinking mode, budget tokens, or handle safety-classifier refusals - and when a model is added, retired, or the default changes.
---

# Model Tuning (per-model deltas)

Cross-model behaviors live in the always-on `~/.claude/rules/personal/
claude-prompting.md`; this skill holds the churn layer - per-model deltas and
the retirement playbook. Deep API mechanics (pricing, migration, parameter
reference) live in the on-demand `claude-api` skill.

## Removed API surface (all current models)

All three models return 400 for: prefill, manual `budget_tokens` extended
thinking, and non-default `temperature`/`top_p`/`top_k`. Steer via prompt,
effort, and `max_tokens`; use Structured Outputs or XML output tags where
prefill was used. Details in the `claude-api` skill.

## Opus 4.8

- Effort: `xhigh` for coding/agentic, `high` minimum for intelligence-sensitive
  work. Effort matters more here than on any prior Opus.
- Thinking is **off** unless you set `thinking: {type: "adaptive"}`.
- Spawns **fewer** subagents by default -- a feature. Steer up for genuine fan-out
  (parallel reads, independent slices); don't spawn for work doable inline.
- At `xhigh`/`max` with subagents+tools, allow a large max output budget (~64k).

## Sonnet 5

- ~90% of Opus 4.8 guidance applies. Differences below.
- Effort **defaults to `high`**; use `xhigh` for the hardest coding/agentic tasks.
- Adaptive thinking is **on by default** (turn off with `thinking:{type:"disabled"}`).
- New tokenizer emits ~30% more tokens for the same text -- raise `max_tokens`
  budgets tuned for older models, and leave headroom so thinking doesn't crowd out
  the answer (symptom: near-all-thinking response truncated at `max_tokens`).
- More agentic out of the box; with thinking disabled it reaches for tools less --
  nudge explicitly if you rely on tool calls with thinking off.

## Fable 5

Designed for long-horizon, ambiguous, multi-hour/day autonomous work; apply it to
the hardest problems. Differs from Opus 4.8 enough to warrant scaffolding changes.

- Effort: `high` default, `xhigh` for the most capability-sensitive work; `low`/
  `medium` still beat prior models' `xhigh` on routine work.
- **Longer turns by default** -- single requests can run many minutes, autonomous
  runs for hours. Adjust client timeouts and prefer async check-ins over blocking.
- **Dispatches parallel subagents readily** (opposite of Opus 4.8). Use them
  frequently, communicate asynchronously, keep long-lived subagents for cache reuse.
- Excels at a **memory system** (one lesson per Markdown file) -- give it a place
  to record and reuse lessons across runs. (Progress-grounding and act-don't-
  overplan already live in `operating-principles.md`.)
- Strong instruction following: steer with a brief instruction rather than
  enumerating every case. Skills tuned for prior models are often too prescriptive
  and can degrade its output -- prune them.
- **Safety classifiers** target offensive-cyber, biology/life-sciences, and
  reasoning-extraction; benign work can trip them, returning `stop_reason:
  "refusal"`. Configure fallback to Opus 4.8. Do **not** instruct it to echo /
  transcribe / explain its own reasoning as response text -- that triggers the
  reasoning-extraction refusal; read structured `thinking` blocks instead.

## Model retirement playbook

Per-model deltas above are the churn layer; the cross-model rules file and
`operating-principles.md` are the durable layer. When a model departs, delete
its section and promote the fallback's defaults -- do not rewrite the file.

If Fable 5 departs and Opus 4.8 becomes the ceiling, scaffold back what Fable
does natively:

- **Thinking + effort:** set `thinking: {type: "adaptive"}` everywhere (Opus
  defaults it off) and run effort `xhigh` for agentic work -- the two levers
  that recover most of the critical-thinking gap.
- **Fan-out:** Opus under-spawns subagents. Make Workflow scripts and skills
  demand parallel dispatch and tiered routing explicitly (Opus plans/reviews,
  cheaper models execute) instead of trusting the model to reach for it.
- **Planning and self-critique:** lean harder on the pipeline gates
  (codex-spec-review / codex-plan-review / co-review) -- a second model
  compensates for weaker self-review, and `operating-principles.md`'s
  checklists force externally what a stronger model does internally.
- **Memory:** keep feeding lessons into files (handoff/kickoff, todos, skills);
  Opus benefits from explicit context even more than Fable.
- **Skills:** Fable wants terse steering; Opus benefits from prescriptive
  detail. When pruning skills for Fable, keep the removed detail recoverable
  (git history), don't rewrite it away.
