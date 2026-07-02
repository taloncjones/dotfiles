# Claude Prompting and Model Tuning

Distilled from Anthropic's per-model prompting guides and cross-model
best-practices (platform.claude.com/docs/en/build-with-claude/prompt-engineering).
No `paths:` frontmatter, so this loads every session: it steers how we author
skills, subagent prompts, Workflow scripts, and reviews. It complements
`operating-principles.md` (model-agnostic discipline) -- that file already covers
the overlapping agentic habits (act-don't-overplan, ground claims against tool
results, confirm irreversible actions, minimal non-over-engineered solutions,
read-before-answer), so this file does not repeat them. Deep API mechanics
(pricing, migration, parameter reference) live in the on-demand `claude-api`
skill -- keep only behavior-shaping facts here. Revisit when a model is added,
retired, or the default changes (see Model retirement playbook).

## Cross-model behaviors (Opus 4.8, Sonnet 5, Fable 5)

These hold across the current models; per-model exceptions are in the deltas below.

- **Effort is the primary lever.** It trades intelligence vs latency/cost. Prefer
  raising effort over "think harder" prose. `low`/`medium` are respected strictly
  (the model scopes to exactly what was asked) -- good for cost, but complex work
  at low effort risks under-thinking. Effort also drives tool-use and subagent
  volume. Per-model defaults differ (see deltas).
- **Verbosity self-calibrates** to task complexity -- short on lookups, long on
  open analysis. Keep concise-by-default guidance; steer with positive examples
  ("communicate like X"), not "don't do Y" lists.
- **Adaptive thinking** is the reasoning mode. If it thinks more than you want on
  large/complex prompts, steer down: "think only when it materially improves the
  answer; otherwise respond directly."
- **Literal instruction following.** The model does not generalize an instruction
  across items or infer unrequested work. State scope explicitly ("every section,
  not just the first"; "all files, not only the changed ones").
- **Don't force interim-status scaffolding** ("summarize every 3 tool calls") --
  user-facing progress updates are well-calibrated now. Describe the desired shape
  only if it's off.
- **Parallel tool calls:** independent reads/searches/commands run in parallel by
  default and this is steerable; never use placeholder/guessed params, and call
  dependent tools sequentially.
- **Don't over-prompt tool use** ("if in doubt, use X") -- tools that undertriggered
  on older models now overtrigger. Describe when a tool genuinely helps instead.
- **Removed API surface** (all three models return 400; details in the
  `claude-api` skill): prefill, manual `budget_tokens` extended thinking, and
  non-default `temperature`/`top_p`/`top_k`. Steer via prompt, effort, and
  `max_tokens`; use Structured Outputs or XML output tags where prefill was used.
- **Code review:** at the finding stage prompt for coverage, not filtering --
  report every issue with confidence + severity tags; rank/dedupe in a separate
  pass. Telling a current model "only high-severity" / "be conservative" makes it
  faithfully drop real bugs (lower recall). If self-filtering in one pass, define
  the bar concretely, not with words like "important".
- **Frontend:** current models settle into a default house style (warm cream /
  serif / terracotta editorial) -- good for editorial/hospitality, wrong for
  dashboards, fintech, healthcare, enterprise. For those, specify a concrete
  palette + type system, or ask it to propose several directions first and pick
  one. Generic "clean / minimal / no cream" just swaps to another fixed default. A
  short anti-slop line suffices: avoid Inter/Roboto/system fonts, purple-on-white
  gradients, cookie-cutter layouts; use distinctive type, cohesive color, motion.

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

Per-model deltas above are the churn layer; the cross-model section and
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
