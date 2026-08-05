# Claude Prompting and Model Tuning

Distilled from Anthropic's per-model prompting guides and cross-model
best-practices (platform.claude.com/docs/en/build-with-claude/prompt-engineering).
No `paths:` frontmatter, so this loads every session: it steers how we author
skills, subagent prompts, Workflow scripts, and reviews. It complements
`operating-principles.md` (model-agnostic discipline) -- that file already covers
the overlapping agentic habits (act-don't-overplan, ground claims against tool
results, confirm irreversible actions, minimal non-over-engineered solutions,
read-before-answer), so this file does not repeat them. Per-model deltas
(Opus 4.8 / Sonnet 5 / Fable 5), removed API surface, and the model-retirement
playbook live in the on-demand `model-tuning` skill; deep API mechanics
(pricing, migration, parameter reference) in the `claude-api` skill -- keep only
always-relevant, behavior-shaping facts here.

## Cross-model behaviors (Opus 4.8, Sonnet 5, Fable 5)

These hold across the current models; per-model exceptions are in the
`model-tuning` skill.

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
