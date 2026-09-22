---
name: model-tuning
description: Cross-model behaviors and per-family tuning deltas for the current Claude families (Opus, Sonnet, Fable) plus the model-retirement playbook. Use when authoring or pruning skills, subagent prompts, Workflow scripts, or API calls that pin a model, set effort, budget tokens, or handle safety-classifier refusals or forced-tool-use errors - when prompting for code review, frontend work, or unattended agent runs - and when a model is added, retired, or an alias moves to a new model.
---

# Model Tuning

A three-line always-on core (effort lever, literal instruction following,
positive-example steering) lives in
`~/.claude/rules/personal/claude-prompting.md`; this skill holds the rest -
cross-model behaviors, per-family deltas, and the retirement playbook. Deep API
mechanics (pricing, migration, parameter reference) live in the on-demand
`claude-api` skill.

Each family section opens with the model ID it was verified for and the date.
When an alias resolves to a newer ID, re-verify that section against the
platform docs before trusting its deltas.

## Cross-model behaviors

These hold across the current families; per-family exceptions below.

- **Adaptive thinking** is the reasoning mode. On Opus and Fable it is always on
  and effort is the only lever; on Sonnet it is on by default. If it thinks more
  than you want, lower effort first. On Sonnet you can also steer down in the
  prompt: "think only when it materially improves the answer; otherwise respond
  directly."
- **Effort names do not transfer** across models or generations. Re-run an
  effort sweep on the new model instead of carrying a level over.
- **Unattended runs:** a turn that ends with text and no tool call is a report,
  not completion. Name the early stops to avoid in the brief from its first
  message -- a summary that announces the next step instead of taking it, an
  offer to continue, a list of decisions none of which blocks the work, a
  progress report at a milestone -- keep confirmation for risky actions, and cap
  automatic continuations at two or three. The herdr worker brief carries this
  in its `## Ground rules`.
- **Don't force interim-status scaffolding** ("summarize every 3 tool calls") --
  user-facing progress updates are well-calibrated now. Describe the desired
  shape only if it's off.
- **Parallel tool calls:** independent reads/searches/commands run in parallel
  by default and this is steerable; never use placeholder/guessed params, and
  call dependent tools sequentially.
- **Don't over-prompt tool use** ("if in doubt, use X") -- tools that
  undertriggered on older models now overtrigger. Describe when a tool genuinely
  helps instead.
- **Code review:** at the finding stage prompt for coverage, not filtering --
  report every issue with confidence + severity tags; rank/dedupe in a separate
  pass. Telling a current model "only high-severity" / "be conservative" makes it
  faithfully drop real bugs (lower recall). If self-filtering in one pass, define
  the bar concretely, not with words like "important".
- **Frontend:** current models settle into a default house style (warm cream /
  serif / terracotta editorial) -- good for editorial/hospitality, wrong for
  dashboards, fintech, healthcare, enterprise. For those, specify a concrete
  palette + type system, or ask it to propose several directions first and pick
  one. Generic "clean / minimal / no cream" just swaps to another fixed default;
  naming the specific patterns to avoid (cream background, italic accent words,
  numbered section labels, pill buttons) and iterating on what the first result
  used works better. A short anti-slop line suffices: avoid Inter/Roboto/system
  fonts, purple-on-white gradients, cookie-cutter layouts; use distinctive type,
  cohesive color, motion.

## API surface the API rejects

All current models return 400 for manual `budget_tokens` extended thinking and
non-default `temperature`/`top_p`/`top_k`, and reject prefill (sourced for Opus and
Fable; carried forward for Sonnet). Opus and Fable also
reject `thinking: {type: "disabled"}` (thinking is always on) and forced tool
use (`tool_choice` of type `any` or `tool`): keep `auto`, mark tools
`strict: true` or use Structured Outputs, and say in the prompt when the tool
applies. Steer via prompt, effort, and `max_tokens`; use Structured Outputs or
XML output tags where prefill was used. On Opus and Fable, thinking blocks are
bound to the conversation prefix: keep history append-only and change
instructions with mid-conversation system messages. Details in the `claude-api`
skill.

## Opus

Verified for `claude-opus-5-5` (platform docs, 2026-09-22). $4 / $20 per MTok.

- Effort **defaults to `medium`**. Per the vendor, `medium` matches or beats the
  prior Opus at `high` on coding and knowledge-work evals, and `low` comes close
  on several coding evals at much lower cost. Start at `medium`, set it
  explicitly, and sweep.
- At a given level it thinks more per turn than the prior Opus, most at
  `xhigh`/`max`. Reserve those for measured gains; a carried-over `xhigh` costs
  more than it used to.
- Adaptive thinking is **always on**: omit `thinking` (or send `adaptive`). For
  less thinking, lower effort -- that works more reliably than prompt
  instructions.
- Thinking counts toward `max_tokens`; leave room (128K, the maximum, worked for
  long agentic turns).
- Changing top-level `effort` between requests invalidates the prompt cache. To
  vary effort inside one conversation, use per-message effort (beta header
  `mid-conversation-output-config-2026-07-01`) or accept the miss. Herdr routes
  pick effort once per fresh session, so this bites only a script that varies
  effort mid-conversation.
- Text written between tool calls arrives as `thinking` blocks, empty at the
  default `display`; API clients that show progress set `display: "updates"`
  (beta).
- Ends some unattended turns with a text report; see the cross-model
  unattended-runs bullet.
- Paces to an elapsed-time signal (`elapsed 340s / 1200s` appended to each
  message) in multi-agent harnesses; advisory, not a hard stop. Herdr passes
  none today.
- Resists injected instructions best when pasted text is fenced in
  `<pasted_content id="...">` tags plus a system note that such text may carry
  instructions the user did not write.
- **Safety classifiers:** bio, cyber, and `reasoning_extraction`. Do not ask it
  to reproduce its reasoning as response text; read `thinking` blocks
  (`display: "summarized"`). Server-side fallback does not retry
  `reasoning_extraction` refusals.
- Code review: early testers report more bugs caught and fewer false alarms
  than the prior Opus; the coverage-not-filtering rule above still applies.
- Whether it dispatches subagents unprompted is not documented; the vendor
  shows it running long tasks with parallel subagents where the harness
  provides them. Where a Workflow or skill depends on parallel dispatch, ask
  for it explicitly.

## Sonnet

Verified for `claude-sonnet-5` (platform docs, 2026-09-22).

- Effort **defaults to `high`**; use `xhigh` for the hardest coding/agentic tasks.
- Adaptive thinking is **on by default** (turn off with `thinking:{type:"disabled"}`).
- Its tokenizer emits ~30% more tokens than Sonnet 4.6 for the same text --
  raise `max_tokens` budgets tuned for older models, and leave headroom so
  thinking doesn't crowd out the answer (symptom: near-all-thinking response
  truncated at `max_tokens`).
- More agentic out of the box; with thinking disabled it reaches for tools less --
  nudge explicitly if you rely on tool calls with thinking off.

## Fable

Verified for `claude-fable-5-1` (platform docs, 2026-09-22). $10 / $50 per MTok;
cache reads $0.25.

Designed for long-horizon, ambiguous, autonomous work; apply it to the hardest
problems.

- Effort: `high` default, `xhigh`/`max` for the most capability-sensitive work.
  `medium` roughly matches the prior Fable at lower cost; `low` is often
  competitive with Opus and Sonnet on cost per task while scoring higher. At
  `xhigh`/`max` it may draft a long deliverable in thinking and then write it
  again -- run long-deliverable requests at `high` unless a gain is measured.
- **Longer turns by default** -- single requests can run many minutes, autonomous
  runs for hours. Adjust client timeouts and prefer async check-ins over
  blocking. (Carried forward; not restated for this model.)
- **Dispatches parallel subagents readily.** Use them, and let the lead keep
  working while they run: a subagent tool that returns immediately, results
  delivered in a later message, and a separate tool to wait. Keep long-lived
  subagents for cache reuse. (Ready dispatch carried forward; the non-blocking
  lead is current guidance.)
- Writes fewer progress updates than the prior Fable during long tool chains;
  ask for them in human-in-the-loop work.
- In coding loops it may issue implied independent tool calls one per turn; a
  one-sentence nudge to batch them fixes it.
- Calls search less at `low`; raise effort for those turns or tell it to verify
  names from fast-moving areas before answering.
- May widen scope (nearby fixes, extra committed tests); say what to leave out.
- Stops early on async work unless told it is operating autonomously; see the
  cross-model unattended-runs bullet.
- Excels at a **memory system** (one lesson per Markdown file) -- give it a place
  to record and reuse lessons across runs. (Carried forward; progress-grounding
  and act-don't-overplan already live in `operating-principles.md`.)
- Strong instruction following: steer with a brief instruction rather than
  enumerating every case. Skills tuned for prior models are often too
  prescriptive and can degrade its output -- prune them. (Carried forward.)
- **Safety classifiers** (cyber, bio, reasoning extraction) trip less often than
  on the prior Fable, but benign work can still return `stop_reason: "refusal"`.
  Known triggers: compile-check phrasing (ask "are there bugs?" instead of "does
  this compile?"), lesser-known languages without context, base64 in tool
  output. Configure fallback: `fallbacks: "default"` (beta) or an Opus retry. Do
  **not** instruct it to echo / transcribe / explain its own reasoning as
  response text -- that triggers the reasoning-extraction refusal; read
  structured `thinking` blocks instead.

## Model retirement playbook

Per-family deltas above are the churn layer; the cross-model section and
`operating-principles.md` are the durable layer. When a model departs, delete
its section and promote the fallback's defaults -- do not rewrite the file.
When an alias moves to a new model ID within a family, re-verify that section
against the platform docs and update its verified-for line; change
`description:` only when a family is added or removed.

If Fable departs and Opus becomes the ceiling, scaffold back what Fable does
natively:

- **Effort:** Opus thinking is always on, so effort is the lever. Raise it from
  Opus's `medium` default to `high` or `xhigh` for the agentic work Fable
  carried, where a measured gain justifies the cost.
- **Fan-out:** Fable's ready parallel dispatch is documented; Opus's is not.
  Make Workflow scripts and skills demand parallel dispatch and tiered routing
  explicitly (Opus plans/reviews, cheaper models execute) instead of trusting
  the model to reach for it.
- **Planning and self-critique:** lean harder on the pipeline gates
  (codex-spec-review / codex-plan-review / co-review) -- a second model
  compensates for weaker self-review, and `operating-principles.md`'s
  checklists force externally what a stronger model does internally.
- **Memory:** keep feeding lessons into files (handoff/kickoff, todos, skills);
  Opus benefits from explicit context even more than Fable.
- **Skills:** Fable wants terse steering; Opus benefits from prescriptive
  detail. When pruning skills for Fable, keep the removed detail recoverable
  (git history), don't rewrite it away.
