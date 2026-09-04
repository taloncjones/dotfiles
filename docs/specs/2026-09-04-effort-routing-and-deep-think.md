# Effort routing and a deep-think escalation path for the orchestrator

Task: `td-2026-09-04-add-effort-routing-and-a-deep-think-escalation-pat`
Base: origin/main @ 8a377cc (verification contracts merged, #78), designed
against the mech-tier branch
`talon/td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical/cheap-model-tier`
(unmerged at spec time; this work lands after it and reuses its machinery).
Status: spec, revision 1 (branch-only; dropped before merge per repo
convention).

## Problem

1. **Effort is unrouted.** The section-8 routing table names an effort per
   role (plan high, review high, impl default, orchestrator low/med) but the
   launch recipe never passes `--effort`. Workers ran at the account default
   until the orchestrator began adding the flag by hand. Policy lives in one
   session's habits, not in the skill or the core.
2. **No escalation path for orchestrator-level judgment.** The orchestrator
   (deliberately medium effort) meets decisions the pipeline does not cover:
   ambiguous backlog triage, milestone/epic decomposition on large project
   repos, incident response with no playbook. Today it decides inline at
   medium or improvises a delegate. As the pattern extends to complex
   multi-milestone repos this becomes load-bearing.
3. **Workflow-tool fan-outs are unrouted.** The Claude Code `Workflow` tool
   runs scripted multi-agent fan-outs whose `agent()` calls accept per-agent
   `model` and `effort`. The user's standing orders call for tiered routing
   there, but nothing ties those parameters to `resolve-model` and the
   capabilities map, and nothing says when a Workflow is the right substrate
   versus a pane worker or `run-mech`.

## Goals

1. Per-role effort resolved deterministically by the core (`resolve-effort`),
   config-overridable like `models`, passed on every interactive worker
   launch, recorded in the task record, and verified from the launch banner.
2. A bounded, read-only deep-think escalation (`run-think`) the orchestrator
   can launch for a defined set of triggers, with a fixed input and output
   contract, composing with the mech-tier caps and result handling.
3. A routing story for the `Workflow` tool: when to use it, how a script
   gets its models and efforts, how its results feed back into task state,
   and how its use traces to explicit user opt-in.
4. Every existing gate (contract pin, contract gate, review, post-rebase
   merge check) is untouched.

## Non-goals

- Automatic escalation. A trigger makes escalation *eligible*; the
  orchestrator still names the escalation in its report, and any state
  change that follows goes through the existing verbs on the orchestrator's
  own judgment. The thinker never acts.
- Effort tuning for the orchestrator itself. Its effort is fixed at session
  launch (advisory row only, as with its model).
- Verifying effort structurally for headless launches. The print-mode result
  JSON carries no effort field (verified, see below); headless effort is
  recorded as requested, labelled as such, and re-checked if a future CLI
  exposes it.
- Spend tracking for interactive workers or Workflow runs. Unchanged from
  the mech spec: interactive launches are untracked.
- A second escalation tier (a thinker escalating further), chained
  escalations, or escalation from inside a worker. Workers hand back.
- Changing mech defaults. `mech` keeps `inherit` effort; `run-mech` merely
  gains the passthrough flag so one wrapper family serves both tiers.

## Verified facts the design rests on

Confirmed live on this machine (Claude Code 2.1.260, herdr 0.8.2,
2026-09-04):

- `claude --help` lists `--effort <level>` with choices
  `low, medium, high, xhigh, max`, valid for interactive and print mode.
  `CLAUDE_CODE_EFFORT_LEVEL` and the `effortLevel` setting are alternative
  sources (binary strings); the design pins via the flag only, so a
  session's effort never depends on machine-local settings.
- An interactive launch `claude --model sonnet --effort high` prints a
  banner whose second line reads `Sonnet 5 with high effort <mdot> Claude Max` (`<mdot>` = U+00B7 middle dot)
  (first line `Claude Code v2.1.260`), and a persistent indicator
  `<bullet> high <mdot> /effort` (`<bullet>` = U+25CF) sits above the prompt. Without `--effort` the model
  line carries no `with ... effort` clause (inferred from the display code;
  AC12 confirms it live).
- `claude -p --output-format json` returns a result object whose keys
  include `subtype`, `is_error`, `num_turns`, `total_cost_usd`, `modelUsage`,
  `permission_denials`, `session_id`, `stop_reason`, `structured_output`,
  and no effort field. With `--json-schema <schema>` the validated object
  lands in `structured_output` (also serialized in `result`).
- `--restricted --strict-mcp-config --tools "Read,Grep,Glob"` composes with
  `-p`, `--max-turns`, `--max-budget-usd`, and `--json-schema` (probe
  returned `subtype: success`, `num_turns: 2`).
- The repo statusline (`claude/statusline.js`) renders the model but not
  effort, though the statusline input JSON carries `effort.level`. The
  banner is therefore the read source today; the statusline is a documented
  future structural source (see Design 3).
- `Workflow`'s `agent(prompt, opts)` accepts `model` (alias string) and
  `effort` (`low|medium|high|xhigh|max`); omitting either inherits the
  calling session's value. The tool requires explicit user opt-in per its
  own description.

## Design

### 1. Effort map and resolution

Constants in `herdr_orch_core.py`:

```python
EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")
ROLE_EFFORT_DEFAULTS = {
    "plan": "high",
    "impl": None,      # inherit: no --effort flag
    "review": "high",
    "mech": None,
    "think": "high",
}
```

`None` means *inherit*: the launch passes no `--effort` flag and the worker
takes the CLI default for its model. It prints as the literal `inherit`.

A new `think` role joins `ROLE_DEFAULTS` (`("fable", "opus")`) and
`ROLE_ALIASES` (`("fable", "opus", "sonnet")`; no `haiku`). `models.think`
becomes a legal config override under the existing rules.

`config.json` gains an optional `effort` block:

```json
"effort": { "plan": "high", "impl": null, "review": "high", "think": "xhigh" }
```

Validation mirrors `models` and fails closed: when present it must be an
object whose keys are a subset of the canonical roles
(`plan`/`impl`/`review`/`mech`/`think`) and whose values are a string in
`EFFORT_LEVELS` or `null`. A non-object, an unknown key, or a value outside
the set makes every effort-resolving verb exit 5 with a concrete message.
Absent keys fall back to `ROLE_EFFORT_DEFAULTS`.

New read-only verbs:

- `python3 "$CORE" resolve-effort --repo-slug <slug> --role <role>` prints
  the level or `inherit`; exit 5 on an invalid role or malformed block. It
  reads config only (no capabilities map, no session).
- `python3 "$CORE" routing-table --repo-slug <slug> --session <id>` prints
  one JSON object keyed by role:
  `{"plan": {"model": "fable", "effort": "high"}, "impl": {"model":
  "sonnet", "effort": null}, ...}` for all five roles. Exit 3 (stale/absent
  map) and 5 (malformed `models` or `effort`) are global and abort the
  call; a role with no surviving model is printed with `"model": null`
  and the verb still exits 0 -- the caller launching that role halts
  exactly as on `resolve-model` exit 4. This is the single call the
  orchestrator uses to fill the brief's Routing block (Design 5) and the
  source for any Workflow script it authors.

### 2. Launch recipe

Interactive launch (section 8 "Model launch"), replacing the two launch
branches with effort-aware ones:

```
MODEL="$(python3 "$CORE" resolve-model --repo-slug <slug> --role <role> --session <id>)"
EFFORT="$(python3 "$CORE" resolve-effort --repo-slug <slug> --role <role>)"
# EFFORT == inherit  -> claude --model $MODEL --permission-mode auto --name <agent>
# otherwise          -> claude --model $MODEL --effort $EFFORT --permission-mode auto --name <agent>
```

(The `--name` capability branch is unchanged and orthogonal.) A nonzero
`resolve-effort` exit is a hard stop like `resolve-model`'s. `$EFFORT` is
shell-safe by construction (closed lowercase set).

`workers[]` entries gain `"effort": "<level>"|null` (the value passed, never
the observed one). `run-mech` gains an optional `--effort <level>`; when
present it appends `--effort <level>` to the `claude` argv and the ledger
`start` line carries `"effort": "<level>"` (`null` when absent). Mech
kickoff keeps calling `resolve-effort --role mech` (default `inherit`), so
nothing changes for mech until a config sets `effort.mech`.

Headless launches (`run-mech`, `run-think`) have no banner and no result
field for effort: their records store the requested effort and the skill
labels it "requested, not verified".

### 3. Verify-after-launch: banner parsing becomes a core verb

The D4 backstop today scrapes the banner by prose. It becomes deterministic:

`python3 "$CORE" classify-banner --model <alias> --effort <level|inherit> --text-file <path>`
(or `--text '<captured text>'`) prints exactly one of
`ok | downgrade | effort-mismatch | unreadable`, exit 0 for all four; the
caller acts on the word, never on the raw text.

Parse rule (`parse_banner(text) -> {"model": str|None, "effort": str|None}`):
locate the last line containing `Claude Code v`; the model line is the next
non-blank line, stripped of the logo glyphs (leading non-`[A-Za-z]`
characters). Match
`^(?P<model>.+?)(?: with (?P<effort>low|medium|high|xhigh|max) effort)?(?:\s*\u00b7.*)?$`
(`\u00b7` is the middle dot; the source uses the escape, keeping the file
ASCII). If no `with ... effort` clause is present, also accept a later line
matching `\u25cf\s*(low|medium|high|xhigh|max)\s*\u00b7\s*/effort` as the
effort source. No `Claude Code v` line, or no parseable model line, is
`unreadable`.

Classification, in precedence order:

| Condition | Result |
| --- | --- |
| banner not parseable | `unreadable` |
| model display name lacks the requested alias family (case-insensitive substring: `fable`, `opus`, `sonnet`, `haiku`) | `downgrade` |
| requested effort is a level and observed effort is absent or different | `effort-mismatch` |
| otherwise (including requested `inherit` with any observed value) | `ok` |

Skill actions: `downgrade` and `unreadable` keep their existing handling
(disable the requested alias and relaunch, capped at 2; abort and surface,
respectively). `effort-mismatch` is **not availability data**: never
`disable-model`, never relaunch automatically. Terminate the worker and
surface `effort pin refused for <role>: requested <level>, observed
<observed|none>; check the account's effort limit or lower
config.effort.<role>`. An organization effort cap is policy a retry cannot
change; the human decides.

Future structural source: if a later herdr exposes model/effort on
`agent get`, or the repo statusline is extended to print `effort.level`
(the pane's statusline line persists where the banner scrolls), prefer that
over the banner; `classify-banner` accepts the same fields from either
source.

### 4. Deep-think escalation

A **deep-think escalation** is one bounded, read-only, headless run of the
strong model at high (or higher) effort that answers one question with a
structured recommendation. The orchestrator launches it, reads the answer
as advisory data, decides, and reports. The thinker cannot act.

#### 4.1 Triggers and non-triggers

Eligible (the orchestrator names the trigger in its report):

- **Ambiguous triage** (section 3): the human asks for a judgment call
  ("which should we do first and why", conflicting priorities), or the
  deterministic ranking has no usable inputs (Jira unreachable AND more
  eligible todos than `config.soft_cap`). Kind `triage`.
- **Milestone/epic decomposition**: the designated item is an epic or
  milestone (a Jira epic key, or a todo whose body the human marks as a
  milestone in the kickoff instruction, `kick off <item> as milestone`)
  and needs splitting into tasks before anything can be kicked off. Kind
  `decompose`. The answer proposes child items; the human designates the
  ones to create. The orchestrator never mints tasks from an answer.
- **Novel incident**: a check-in reaches a state the section-9 table does
  not cover -- an integrity halt (verify exit 4, or exit 5 with a pinned
  record), a mis-anchored *adopted* resource, two live review agents in
  one workspace, model-attributable failures past the relaunch cap, an
  `_orphans` entry with live processes. Kind `incident`. The answer
  recommends a recovery; every recovery step that mutates state is
  proposed to the human, not executed.
- Anything else the human explicitly asks to "escalate" or "deep-think".
  Kind `other`.

Not eligible: any decision with a documented path (kickoff, phase advance,
review dispatch, merge surface, mech relaunch); routine status; design
work a `plan` worker is about to do at high effort anyway; anything a
worker wants (workers hand back; `run-think` is orchestrator-only and a
worker brief never carries it).

Rate limits: at most one live escalation per repo at a time, and at most
one launch per orchestrator turn. A second eligible trigger in the same
turn is reported as "escalation deferred: one already live".

#### 4.2 Modes

- **Headless one-shot (default, the machine path):** `run-think`, below.
  Launched with `Bash run_in_background` from the orchestrator (or in a
  self-managed `pane split` pane in the orchestrator's OWN workspace,
  section 7 rules); either way the orchestrator does not block, and the
  answer file landing under `think/` is a watch wake (`WATCH_DIRS` gains
  `think/*.answer.json`).
- **Short-lived interactive pane (human-attended):** for decomposition
  the human wants to steer live. The orchestrator opens a self-managed
  pane in its own workspace and runs
  `claude --model $MODEL --effort $EFFORT --permission-mode plan --tools Read,Glob,Grep --name <think_id>`
  (`think` role model/effort; plan mode plus a read-only tool set is the
  guardrail), sends the same question text as its first prompt, and
  closes the pane when the human is done. Output is whatever the human
  takes from the conversation; nothing is recorded by the wrapper, no
  spend is tracked, and any resulting kickoff is a normal human
  designation. This mode has no machine contract by design.

#### 4.3 Caps and config

`config.json` gains an optional `think` block with the same bounds and
fail-closed rules as `mech` (Design 3 of the mech spec), minus
`contract_commands`:

```json
"think": { "max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900 }
```

Defaults when absent: `max_turns 15`, `max_budget_usd 3.0`,
`timeout_secs 900`. `mech_caps` generalizes to
`tier_caps(config, tier, defaults, max_turns=None, max_budget_usd=None)`;
`mech_caps` stays as a thin wrapper. New verb
`python3 "$CORE" think-caps --repo-slug <slug> [--max-turns N] [--max-budget-usd X]`
prints `{"max_turns", "max_budget_usd", "timeout_secs"}` or exits 5.
Per-launch overrides come only from the human's instruction ("escalate
with budget 5"), never from the orchestrator's judgment.

#### 4.4 Identity and files

`think_id` = `think-<kind>-<YYYYMMDDTHHMMSSZ>` (UTC launch time; kind in
`triage|decompose|incident|other`), `[a-z0-9-]` only, used as the
session `--name`. Files live under `STATE_ROOT/<repo_slug>/think/`:

```
think/
  <think_id>.question.md     # orchestrator-written brief (input contract)
  <think_id>.answer.json     # wrapper-written result (output contract)
```

Nothing is written into any worktree. The `think/` directory is
machine-local like everything under `STATE_ROOT`.

#### 4.5 Input contract (the question file)

Written by the orchestrator from the new "Deep-think brief variant" in
`brief-template.md`, every placeholder filled. Sections, in order:

1. Role framing: "You are `<think_id>`, a read-only advisor for the
   orchestrator of repo `<repo_slug>`. You have Read/Glob/Grep only, at
   most `<max_turns>` turns and `$<max_budget_usd>`. You cannot and must
   not change anything. Your only output is the structured answer."
2. `## Question` -- one decision, phrased as a question, plus `Kind:
   <kind>` and `Task: <task_id or none>`.
3. `## Context` -- inlined excerpts (task records, todo bodies, transition
   evidence, the ranked triage list) and worktree-relative paths the
   advisor may read. Inline what matters; paths are secondary. Never a
   fence token, socket path, or credential.
4. `## Constraints` -- what is fixed (existing gates, the human-merge
   rule, budget) and what is out of bounds.
5. `## Answer shape` -- restates the output fields and asks for two to four
   options with the recommendation first, rationale grounded in the
   context, and open questions only for what the context cannot settle.

#### 4.6 Output contract

`run-think` passes `--json-schema` with the core constant `THINK_SCHEMA`:

```json
{
  "type": "object",
  "properties": {
    "recommendation": {"type": "string"},
    "rationale": {"type": "string"},
    "options": {"type": "array", "minItems": 1, "maxItems": 6, "items": {
      "type": "object",
      "properties": {
        "label": {"type": "string"}, "summary": {"type": "string"},
        "tradeoffs": {"type": "string"},
        "risk": {"type": "string", "enum": ["low", "medium", "high"]}},
      "required": ["label", "summary", "tradeoffs", "risk"]}},
    "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
    "open_questions": {"type": "array", "items": {"type": "string"}},
    "evidence": {"type": "array", "items": {"type": "string"}}
  },
  "required": ["recommendation", "rationale", "options", "confidence"]
}
```

`<think_id>.answer.json`, written atomically by the wrapper in every
outcome:

```json
{
  "v": 1, "think_id": "think-triage-20260904T170000Z", "kind": "triage",
  "task_id": null, "repo_slug": "<slug>", "model": "fable", "effort": "high",
  "caps": {"max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900},
  "status": "answered|unanswered", "reason": null,
  "answer": { "...structured_output..." },
  "subtype": "success", "is_error": false, "num_turns": 6,
  "total_cost_usd": 1.12, "duration_ms": 184000,
  "models_used": ["claude-fable-5-1"], "downgrade": false,
  "model_attributable": false, "permission_denials": 0, "errors": [],
  "session_id": "<uuid>", "started": "...", "ts": "..."
}
```

`status: answered` requires `subtype: success` AND a `structured_output`
object that validates against `THINK_SCHEMA` (the wrapper re-validates
shape: required keys present and typed; it does not trust the CLI). Every
other case is `unanswered` with `reason` in
`max_turns|max_budget|timeout|no_answer|error` (`no_answer` = success
without a valid structured object). `answer` is `null` when unanswered.
`downgrade`/`model_attributable`/`errors` reuse the mech helpers verbatim.

#### 4.7 The `run-think` verb

```
python3 "$CORE" run-think --repo-slug <slug> --think-id <think_id> --kind <kind>
  [--task-id <task_id>] --model $MODEL --effort <level|inherit> --cwd <repo_worktree>
  --question-file <STATE_ROOT>/<slug>/think/<think_id>.question.md
  --max-turns <N> --max-budget-usd <X> --timeout-secs <T> [--add-dir <dir>]...
```

In order:

1. Validate: repo slug; `think_id` matches
   `think-(triage|decompose|incident|other)-\d{8}T\d{6}Z(-[2-9])?` and its
   kind equals `--kind`; optional task id valid; model in `CAP_MODELS`;
   effort in `EFFORT_LEVELS` or `inherit`; caps within the mech bounds;
   question file a regular non-symlink file contained in `STATE_ROOT`
   and readable; `--cwd` an existing git checkout; each `--add-dir` an
   existing directory contained in `STATE_ROOT/<slug>` (the only extra
   read surface the advisor may be given); every value shell-safe
   (`SHELL_SAFE_RE`); the answer file must not already exist. Any failure:
   exit 2, nothing written.
2. Launch
   `claude --model <M> [--effort <E>] --permission-mode dontAsk --name <think_id> -p --output-format json --json-schema <THINK_SCHEMA> --max-turns <N> --max-budget-usd <X> --restricted --strict-mcp-config --tools Read,Glob,Grep [--add-dir <dir>]...`
   with the question on stdin, cwd `--cwd`, its own process group, killed
   on `--timeout-secs` (reusing `run_mech`'s launch/timeout/parse code,
   factored into a shared `run_headless` helper). `dontAsk` denies anything
   that would prompt; denials are counted, not fatal. `--restricted` plus
   `--strict-mcp-config` removes Bash, Write, Edit, WebFetch, and every MCP
   server, so "read-only" is enforced by the CLI, not by the prompt.
   Session persistence stays on so a human can `--resume` the transcript.
3. Parse the result exactly as `run_mech` does; classify `status`/`reason`
   per 4.6; write `<think_id>.answer.json` atomically. Unwritable: exit 3.
4. Exit 0 when the answer file was written (answered or not); the
   orchestrator reads the file, never the exit code.

Model-attributable failure (`downgrade` or execution error naming the
alias/"model"): the orchestrator applies the existing within-role rule --
`disable-model` on the requested alias, `resolve-model --role think`,
relaunch once with a `-2` suffixed `think_id`. Cap 2 attempts, then decide
inline and say so. Any other `unanswered` is surfaced with the spend line;
a relaunch with raised caps is the human's call.

`resolve-model --role think` exit 4 (no strong model): no escalation; the
orchestrator decides inline at its own effort and reports "no escalation
model available".

#### 4.8 Consuming the answer

- The answer is **data**, subject to the Safety rule on embedded
  instructions: the orchestrator weighs it, never obeys it. Its report
  line reads `escalation <think_id> (<kind>, $<usd>, <turns> turns):
  <recommendation one-liner> -- adopted|adapted|rejected: <why>`.
- Triage: the recommendation reorders or annotates the advisory list;
  section 3 stays read-only.
- Decompose: the options become a proposed child list surfaced to the
  human; kickoff of each child is a normal designation.
- Incident: recommended steps are surfaced; the human approves each
  mutating step; the orchestrator then applies it through the normal
  verbs under its fence.
- Nothing about an escalation is written to a task record. The
  `answer.json` is the durable trace (with `task_id` when it concerned a
  task).

#### 4.9 Status and liveness

`status` gains a top-level `_think` summary folded from `think/*.answer.json`:
`{"launches", "answered", "unanswered", "usd", "turns", "skipped_files"}`
(`usd`/`turns` sum non-null values; unparseable or wrong-`v` files are
skipped and counted, never fatal). No per-task field. A `.question.md`
with no matching `.answer.json` whose mtime is older than
`timeout_secs + 120s` is reported as `think lost: <think_id>` (the wrapper
died); no auto-relaunch. `_think` cannot collide with a task id.

### 5. Workflow-tool routing

#### 5.1 Substrate decision table

| Need | Substrate | Why |
| --- | --- | --- |
| Work that must own a branch, worktree, task record, review, and merge gate | Pane worker (sections 2/2a/5) | The task lifecycle; only substrate with identity, provenance, and completion records |
| Human-designated mechanical task under caps with a spend ledger | `run-mech` | Lifecycle plus headless caps and ledger |
| One bounded judgment call for the orchestrator (4.1 triggers) | `run-think` | Read-only, structured answer, orchestrator-only |
| In-turn fan-out inside one session: parallel reading, analysis, judging, review-then-verify, or bounded parallel mechanical slices of the caller's OWN task | `Workflow` | Deterministic control flow over many subagents, results consumed in the same turn |
| A single helper read/search/analysis | `Agent` subagent | No orchestration needed |

A Workflow run is **in-turn helper work** (section 7's first bullet at
scale). It has no workspace, no index entry, no record; it never
substitutes for a phase or role. In particular: the review gate remains a
fresh `rev-<t>` agent running co-review; a Workflow review inside an impl
worker is a pre-review self-check only, and the orchestrator never
dispatches a Workflow *instead of* a worker.

Workflow agents that mutate files do so only under `isolation: 'worktree'`
and only for the calling worker's own task, and the worker merges the
results into its branch itself. A Workflow launched by the orchestrator is
read-only (analysis, triage support, decomposition drafting) -- the
orchestrator authors no code and its Workflow agents write nothing.

#### 5.2 Models and effort inside a script

Models and efforts are resolved BEFORE the script is authored, never
hard-coded, never picked by judgment:

- The **orchestrator** runs `routing-table` once (Design 1) and maps
  script tiers to roles: planner/judge/synthesizer stages -> `plan`;
  reviewer/verifier stages -> `review`; implementer stages -> `impl`;
  mechanical stages -> `mech`; a single deep judge stage -> `think`. Each
  `agent()` call passes `model: <alias from the table>` and
  `effort: <level>` (omit `effort` when the table says `null`). A role
  with `"model": null` may not appear in the script; drop or halt.
- A **worker** has no capabilities map of its own (`resolve-model` is
  stamped to the orchestrator's session), so its brief carries a
  `## Routing` block rendered from the same `routing-table` output at
  kickoff. A worker authoring a Workflow copies aliases and efforts from
  that block; a role absent from the block is unavailable to it.
- Omitting `model` (inherit the session model) is allowed only for a
  stage whose tier IS the author's own role. No literal model ids, no
  `--fallback-model` equivalents.
- The size guideline (under 15 agents by default) holds unless the human
  raised it in the instruction that opted in.

#### 5.3 Opt-in

The Workflow tool runs only on explicit user opt-in. This skill documents
the grant: **a kickoff under this skill is the user's explicit opt-in to
Workflow use for that task**, by the orchestrator while handling that
task and by the briefed worker inside it. The brief carries the line
`Workflow opt-in: granted for this task by the orchestrated kickoff
(default size guideline)`, so a worker can trace the grant to the
human's own designation. Outside a kickoff (freeform triage or status
turns) the orchestrator uses Workflow only when the current human
instruction asks for that scale in its own words.

#### 5.4 Results feed back through the existing lifecycle

A Workflow returns to the session that launched it and stops there.
Completion is still commits + contract + `emit-done`; a Workflow agent
never runs a `$CORE` mutating verb, `emit-done`, or `emit-review` (the
brief says so). Workflow spend is untracked (interactive-class), and its
transcripts live under the calling session, not `STATE_ROOT`.

### 6. Calibration note (high-effort plan worker, n=1)

This spec was produced by the first plan worker launched at `--effort
high` (Fable). Self-observed, not measured against a medium baseline:
evidence gathering was front-loaded and wide (one eleven-way parallel read
of the mech branch, references, review skills, and CLI help before any
design writing); three uncertain facts were settled by live probes (banner
format via a temporary pane, result-JSON keys, structured-output location)
rather than inferred; the design was written once against those facts.
Cost of the three probes: under one dollar. Recommendation: keep `plan` at
`high`; measure `think` runs through `answer.json` spend before deciding
whether `xhigh` earns its cost anywhere.

## Acceptance criteria

AC1. `resolve-effort --role plan|review|think` prints `high`; `--role
impl|mech` prints `inherit`; a config `effort` block overrides per role
(`{"impl": "low"}` -> `low`, `{"plan": null}` -> `inherit`); exit 5 for an
unknown role, a non-object block, an unknown key, a value outside
`EFFORT_LEVELS`, or a boolean/number value.
AC2. `resolve-model --role think` prints `fable`, falls back to `opus`,
exits 4 with neither, exits 5 when `models.think` names `haiku`.
AC3. `routing-table` prints all five roles with `model`/`effort` from a
valid map and config; exits 3 with a stale map, 5 with a malformed
`effort` or `models` block; a role with no survivor prints `"model": null`
with exit 0.
AC4. `classify-banner`: fixture texts yield `ok` (matching model and
effort), `ok` (requested `inherit`, banner shows an effort or none),
`downgrade` (Sonnet banner under `--model fable`, regardless of effort),
`effort-mismatch` (requested `high`, banner shows no effort; requested
`high`, banner shows `medium`; requested `high`, only the `/effort`
indicator line shows `medium`), and `unreadable` (no `Claude Code v` line;
empty text). The fixtures use the middle-dot separator via escape.
AC5. `think-caps` prints the documented defaults, merges a valid `think`
block, applies overrides, exits 5 on out-of-bounds, unknown key, boolean,
or a `contract_commands` key; `mech-caps` behaviour is unchanged.
AC6. `run-think` against the fake `claude`: (a) success with a valid
structured object -> `answered`, `answer` equals the object, spend fields
copied, exit 0, and the fake saw exactly the documented argv (model,
optional effort, `dontAsk`, name, `-p`, json, `--json-schema` equal to
`THINK_SCHEMA`, both caps, `--restricted`, `--strict-mcp-config`, the
three tools, each `--add-dir`), the question on stdin, cwd == `--cwd`;
(b) `error_max_turns` / `error_max_budget_usd` -> `unanswered` with
`max_turns` / `max_budget`; (c) success with a missing or schema-invalid
`structured_output` -> `unanswered`/`no_answer`; (d) a fake sleeping past
`--timeout-secs` -> `unanswered`/`timeout` and the fake's pid is gone;
(e) `modelUsage` keyed by a sonnet id under `--model fable` ->
`downgrade: true`, `model_attributable: true`; (f) `--effort inherit`
omits the flag, `--effort xhigh` passes it and records it; (g) an
unwritable answer path -> exit 3.
AC7. `run-think` exits 2 and writes nothing for: a malformed `think_id`,
a `think_id` whose kind disagrees with `--kind`, a question file outside
`STATE_ROOT` or a symlink, an `--add-dir` outside `STATE_ROOT/<slug>`, a
non-git `--cwd`, out-of-bounds caps, an effort outside the set, any
shell-unsafe value, and an already-existing answer file.
AC8. `run-mech --effort high` passes `--effort high` in argv and records
`"effort": "high"` on the `start` line; without the flag argv is unchanged
from the mech spec and the line records `null`.
AC9. `status` folds a `think/` fixture of two answered files (1.12 and
0.40 usd, 6 and 3 turns), one unanswered with null cost, one truncated
file, and one `v: 2` file into `_think: {launches: 3, answered: 2,
unanswered: 1, usd: 1.52, turns: 9, skipped_files: 2}`; reports a stale
question with no answer as lost; an empty or absent `think/` reports zeros.
AC10. `watch_scan` includes `think/*.answer.json`; an answer write flips
`watch_changed`.
AC11. The walkthrough suite: (a) a plan kickoff launch line carries
`--effort high` and the `workers[]` entry records `effort: "high"`; an impl
launch line carries no `--effort` and records `null`; (b) a classify-banner
`effort-mismatch` leaves `capabilities.json` untouched (no `disable-model`
call in the fake log) while a `downgrade` flips the requested alias; (c) a
triage escalation writes the question file, invokes `run-think` with the
documented argv, lands `answer.json`, and `status` shows `_think`; (d) the
brief rendered for a kickoff contains a `## Routing` block matching
`routing-table` output and the Workflow opt-in line.
AC12 (human-verify, live): one interactive launch without `--effort` shows
a banner model line with no `with ... effort` clause (confirms the
`inherit` classification), and one real `run-think` on this repo at
`--effort high` lands an `answered` file; the plan's close records both.
AC13. SKILL.md (sections 1, 2, 3, 4, 7, 8, 9 as touched), `state-layout.md`,
`brief-template.md`, and `event-schema.md` describe the effort map, the
launch line, the banner verb and `effort-mismatch` rule, the deep-think
verb, triggers, contracts, files, `_think`, and the Workflow section;
the existing docs drift checks pass and new ones pin the additions.

## Acceptance-criterion to contract-command mapping

| AC | Contract command |
| --- | --- |
| AC1-AC10, AC13 | `core-unit-suite` (`sh claude/hooks/herdr-orch.test.sh`) |
| AC11 | `orchestration-walkthrough-suite` (`sh claude/hooks/herdr-orch-contract.test.sh`) |
| AC12 | human-verify (live), recorded in the plan close |
