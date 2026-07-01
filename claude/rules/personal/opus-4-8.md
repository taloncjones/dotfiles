# Opus 4.8 Operating Guidance

Model-specific tuning distilled from Anthropic's Opus 4.8 prompting guide
(platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-4-8).
This file has no `paths:` frontmatter, so it loads every session. It complements
`operating-principles.md` (model-agnostic discipline); this file is the
model-specific layer. Revisit when the default model changes.

## Effort is the primary lever

Effort matters more on 4.8 than on any prior Opus. Reach for it before prompting.

- Coding / agentic work: `xhigh`.
- Intelligence-sensitive work: `high` minimum.
- `medium`: cost-sensitive work that can trade some capability.
- `low`: short, scoped, latency-bound tasks only.
- 4.8 respects `low`/`medium` strictly and scopes to exactly what was asked --
  so complex work at low effort risks under-thinking. If reasoning looks
  shallow, RAISE effort rather than adding "think harder" prose.
- Effort also drives tool-use and subagent volume: raise it when you want more
  searching / tool calls (e.g. agentic search, knowledge work).
- At `xhigh`/`max` with subagents and tools, allow a large max output budget
  (start ~64k tokens) so there is room to think and act.

## Thinking

- Off unless explicitly enabled (`thinking: {type: "adaptive"}`). Enable it for
  genuine multi-step reasoning; expect added latency.
- If it over-thinks on large/complex prompts, steer down: think only when it
  will materially improve the answer; otherwise respond directly.

## Instruction literalism

- 4.8 follows instructions literally and does NOT silently generalize from one
  item to another or infer requests you did not make. State scope explicitly:
  "apply to every section, not just the first", "all files, not only changed
  ones".
- Upside is precision and low thrash. Front-load complete, well-specified tasks
  (especially in interactive coding) to maximize autonomy and token efficiency;
  ambiguous prompts spread over many turns cost more and perform worse.

## Verbosity and tone

- 4.8 calibrates length to task complexity on its own. Keep concise-by-default
  guidance and prefer positive examples over "don't do X" lists.
- Default prose is direct and opinionated with little validation-forward
  phrasing. Add a warmth/voice instruction only where a surface needs it.

## Subagents

- 4.8 spawns fewer subagents by default -- this is a feature, not a regression.
  Do not add interim-status scaffolding ("summarize every 3 tool calls"); its
  user-facing progress updates are already well-calibrated.
- Spawn for real fan-out (parallel file reads, independent slices), not for work
  doable inline in a single response.

## Code review harnesses

- At the FINDING stage, prompt for coverage, not filtering: report every issue
  including low-severity and uncertain ones, each tagged with confidence and
  severity. Rank / dedupe / filter in a SEPARATE pass.
- Do NOT tell 4.8 "only high-severity" or "be conservative" at finding time --
  it now obeys faithfully and drops real bugs, lowering recall. If you must
  self-filter in one pass, define the bar concretely: "bugs that cause incorrect
  behavior, a test failure, or a misleading result; omit pure style/naming."

## Frontend defaults

- 4.8's house style trends warm cream (~#F4F1EA), serif display type, and a
  terracotta/amber accent -- strong for editorial / hospitality / portfolio,
  wrong for dashboards, dev tools, fintech, healthcare, or enterprise.
- For those, either specify a concrete palette and type system, or ask it to
  propose several distinct directions first and pick one (this also replaces
  `temperature` for variety). Generic "clean / minimal / no cream" just swaps to
  another fixed default.
- 4.8 needs less anti-slop prompting than prior models. A short line is enough:
  avoid generic AI aesthetics (Inter/Roboto/system fonts, purple-on-white
  gradients, cookie-cutter layouts); use distinctive type, cohesive color, and
  purposeful motion.
