# Effort routing and a deep-think escalation path for the orchestrator

Task: `td-2026-09-04-add-effort-routing-and-a-deep-think-escalation-pat`
Base: origin/main @ 8a377cc (verification contracts merged, #78), designed
against the mech-tier branch
`talon/td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical/cheap-model-tier`
(unmerged at spec time; this work lands after it and reuses its machinery).
Status: spec, revision 3 after Codex spec review rounds 1 and 2 (branch-only;
dropped before merge per repo convention). Review log at the end.

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
- An interactive (pane) escalation mode. A human who wants to think
  alongside the strong model launches their own `claude --effort xhigh`
  session; there is nothing for the orchestrator to own, cap, or record,
  so it is not a substrate of this skill. Revisit only if a machine
  contract for it emerges.
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
`ROLE_ALIASES` (`("fable", "opus")` -- the strong tier only; `sonnet` or
`haiku` under `models.think` is a config error, exit 5). `models.think`
becomes a legal config override under the existing rules.

`think` effort is likewise constrained: `THINK_EFFORTS = ("high", "xhigh",
"max")`. `effort.think` must be one of those (never `null`, `low`, or
`medium`); `resolve-effort --role think` therefore never prints `inherit`.
"Deep think" means the strong tier at high effort or above, by
construction, in config, resolver, wrapper validation, and tests alike.

`config.json` gains an optional `effort` block:

```json
"effort": { "plan": "high", "impl": null, "review": "high", "think": "xhigh" }
```

Validation mirrors `models` and fails closed: when present it must be an
object whose keys are a subset of the canonical roles
(`plan`/`impl`/`review`/`mech`/`think`) and whose values are a string in
`EFFORT_LEVELS` or `null` (`think`: a string in `THINK_EFFORTS`). A
non-object, an unknown key, a boolean or number, or a value outside the
set makes every effort-resolving verb exit 5 with a concrete message.
Absent keys fall back to `ROLE_EFFORT_DEFAULTS`.

New read-only verbs:

- `python3 "$CORE" resolve-effort --repo-slug <slug> --role <role>` prints
  the level or `inherit`; exit 5 on an invalid role or malformed block. It
  reads config only (no capabilities map, no session).
- `python3 "$CORE" routing-table --repo-slug <slug> --session <id>` prints
  one JSON object keyed by role:
  `{"plan": {"model": "fable", "effort": "high"}, "impl": {"model":
  "sonnet", "effort": null}, ...}` for all five roles, from ONE read of
  `config.json` and ONE read of `capabilities.json`. Exit 3 (stale/absent
  map) and 5 (malformed `models` or `effort`) are global and abort the
  call; a role with no surviving model is printed with `"model": null`
  and the verb still exits 0 -- the caller launching that role halts
  exactly as on `resolve-model` exit 4. **One snapshot per dispatch:**
  every dispatch (kickoff, phase advance, review dispatch, escalation)
  calls `routing-table` once and takes its model, its effort, the
  `workers[]` fields, and the brief's Routing block from that single
  output, so a config or capability change between steps cannot produce
  an inconsistent launch. `resolve-model`/`resolve-effort` remain for
  single-role checks and tests.

### 2. Launch recipe

Interactive launch (section 8 "Model launch"), replacing the two launch
branches with effort-aware ones:

```
ROUTING="$(python3 "$CORE" routing-table --repo-slug <slug> --session <id>)"   # once per dispatch
MODEL="$(printf '%s' "$ROUTING" | python3 -c 'import json,sys; print(json.load(sys.stdin)["<role>"]["model"] or "")')"
EFFORT="$(printf '%s' "$ROUTING" | python3 -c 'import json,sys; print(json.load(sys.stdin)["<role>"]["effort"] or "inherit")')"
# MODEL empty       -> halt: no available model for <role> (as resolve-model exit 4)
# EFFORT == inherit -> claude --model $MODEL --permission-mode auto --name <agent>
# otherwise         -> claude --model $MODEL --effort $EFFORT --permission-mode auto --name <agent>
```

(The `--name` capability branch is unchanged and orthogonal.) A nonzero
`routing-table` exit is a hard stop like `resolve-model`'s. `$EFFORT` is
shell-safe by construction (closed lowercase set).

`workers[]` entries gain `"effort": "<level>"|null` (the value passed, never
the observed one). **Legacy records:** entries written before this change
lack the key; they stay valid, readers treat a missing `effort` as unknown
(`status` reports `effort: "unknown"` for such an entry), full-record
rewrites carry the entries forward byte-for-byte (the existing carry-
forward rule), and every entry appended by a launch under this spec MUST
include the key (walkthrough-asserted; the core adds no `workers[]`
validation, matching today). `run-mech` gains an optional `--effort <level>`; when
present it must be a value in `EFFORT_LEVELS` (`inherit` and anything else
is rejected with exit 2 before the ledger `start` line is written); it
appends `--effort <level>` to the `claude` argv and the ledger `start` line
carries `"effort": "<level>"` (`null` when absent). Mech
kickoff keeps calling `resolve-effort --role mech` (default `inherit`), so
nothing changes for mech until a config sets `effort.mech`.

Headless launches (`run-mech`, `run-think`) have no banner and no result
field for effort: their records store the requested effort and the skill
labels it "requested, not verified".

### 3. Verify-after-launch: banner parsing becomes a core verb

The D4 backstop today scrapes the banner by prose. It becomes deterministic:

`python3 "$CORE" classify-banner --model <alias> --effort <level|inherit> --text-file <path>`
(or `--text '<captured text>'`) prints exactly one of
`ok | downgrade | effort-mismatch | unreadable`, exit 0 for all four; with
`--json` it prints `{"class": "<word>", "model": "<display>|null",
"effort": "<level>|null"}` so the caller can quote the OBSERVED model and
effort in its report without ever parsing the raw capture itself.

Parse rule (`parse_banner(text) -> {"model": str|None, "effort": str|None}`):

1. Normalize: strip ANSI/terminal control sequences (CSI, OSC, and single
   ESC sequences) and carriage returns; split into lines.
2. Anchor the version line: the FIRST line matching
   `Claude Code v\d+\.\d+\.\d+(\S*)?` (the banner is printed once, first;
   later text quoting it is ignored). None -> `unreadable`.
3. The model line is the next non-blank line, with leading logo glyphs
   (any run of characters outside `[A-Za-z]`) removed. It must match
   `^(?P<model>(Fable|Opus|Sonnet|Haiku)\b[^\u00b7]*?)(?: with (?P<effort>low|medium|high|xhigh|max) effort)?(?:\s*\u00b7.*)?$`
   (`\u00b7` is the middle dot; the source uses the escape, keeping the
   file ASCII). A model line that names no recognized family (a changed
   banner, a notice, a prompt) is `unreadable` -- never `downgrade`: only a
   positively identified other family may disable a model.
4. If no `with ... effort` clause matched, a later line matching
   `\u25cf\s*(low|medium|high|xhigh|max)\s*\u00b7\s*/effort` supplies the
   effort. Otherwise effort is `None`.

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

**Lifecycle after `effort-mismatch`.** The banner read happens inside the
launch step, before any state is published (section 2 step 7, section 2a
step 3, section 5 step 3 all publish only after a successful launch), so:
terminate the worker's process in its pane (`/exit`, else kill the pane
process; the pane and workspace are NOT closed for an adopted resource);
then the existing rules apply unchanged -- a fresh kickoff unwinds only
resources this attempt created (step 9) and leaves no task record; a
phase advancement leaves the task `in-progress` with the plan worker's
entry still latest and no implement entry appended; a review dispatch
leaves the task `completed` with no `review_head_sha`. No orphan is
possible because nothing was published; the walkthrough asserts a live-
agent count of zero and an unchanged record after the refusal.

Future structural source: if a later herdr exposes model/effort on
`agent get`, or the repo statusline is extended to print `effort.level`
(the pane's statusline line persists where the banner scrolls), prefer that
over the banner; `classify-banner` accepts the same fields from either
source.

### 4. Deep-think escalation

A **deep-think escalation** is one bounded, headless run of the strong
model (`think` role: `fable -> opus`, effort `high`/`xhigh`/`max`) that
answers ONE question with a structured recommendation. The orchestrator
launches it, reads the answer as advisory data, decides, and reports. The
thinker has no tool that can write, run, or fetch (Design 4.7): its only
channel back is the answer.

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

Vocabulary: an **escalation** is one question, one `think_id` family,
one budget. It may take up to two **attempts** (the second only on a
model-attributable failure, Design 4.7); both attempts share the
escalation's `max_budget_usd`.

Core-enforced limits (`run-think`, from durable files under a repo-wide
lock, 4.4):

- one live escalation per repo at a time: a launch while another launch
  record is live exits 4, nothing written;
- a daily spend ceiling, `config.think.daily_budget_usd` (default 10.0,
  bounds 0 < x <= 200). The day's committed spend is the sum, over launch
  records with `started` in the current UTC day, of the answer's numeric
  `total_cost_usd` when one exists, else the launch's reserved
  `caps.max_budget_usd` (live, lost, unwritable-answer, and null-cost runs
  all count at their cap, never double-counted). When committed spend plus
  the requested cap would exceed the ceiling, `run-think` exits 4 with the
  figures and the orchestrator surfaces "daily think budget reached"; only
  the human raises it (config edit);
- the retry budget rule (4.7 step 2).

Skill-enforced limit (prose, not a file): one escalation per orchestrator
turn. A second eligible trigger in the same turn is reported as
"escalation deferred: already launched this turn".

#### 4.2 Mode

One mode: the headless one-shot `run-think` (4.7). Launched with `Bash
run_in_background` from the orchestrator (or in a self-managed `pane
split` pane in the orchestrator's OWN workspace, section 7 rules); either
way the orchestrator does not block. The launch record and the answer
file landing under `think/` are watch wakes (`WATCH_DIRS` gains `think/`
with suffixes `.launch.json` and `.answer.json`). An interactive variant
is a non-goal (see Non-goals).

#### 4.3 Caps and config

`config.json` gains an optional `think` block with the same bounds and
fail-closed rules as `mech` (Design 3 of the mech spec), minus
`contract_commands`:

```json
"think": { "max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900, "daily_budget_usd": 10.0 }
```

Defaults when absent: `max_turns 15`, `max_budget_usd 3.0`,
`timeout_secs 900`, `daily_budget_usd 10.0` (finite number, 0 < x <= 200;
a per-launch `max_budget_usd` above it is a config error). `mech_caps`
generalizes to `tier_caps(config, tier, defaults, extra_keys, max_turns=None,
max_budget_usd=None)`; `mech_caps` stays as a thin wrapper. New verb
`python3 "$CORE" think-caps --repo-slug <slug> [--max-turns N] [--max-budget-usd X]`
prints `{"max_turns", "max_budget_usd", "timeout_secs", "daily_budget_usd"}`
or exits 5.
Per-launch overrides come only from the human's instruction ("escalate
with budget 5"), never from the orchestrator's judgment.

#### 4.4 Identity and files

`think_id` = `think-<kind>-<YYYYMMDDHHMMSS>` (UTC launch time, 14 digits;
kind in `triage|decompose|incident|other`), optionally suffixed `-2` for
the single retry attempt. Longest form `think-decompose-20260904170000-2`
is 32 characters, the herdr/Claude agent-name limit (`AGENT_NAME_RE`);
every kind and suffix fits, and `valid_think_id()` enforces the regex
`think-(triage|decompose|incident|other)-\d{14}(-2)?\Z`. It is the
session `--name`. Files live under `STATE_ROOT/<repo_slug>/think/`:

```
think/
  <think_id>.question.md     # orchestrator-written brief (input contract)
  <think_id>.launch.json     # wrapper-written, create-exclusive, before launch (liveness)
  <think_id>.answer.json     # wrapper-written result (output contract)
```

`<think_id>.launch.json` is the durable live record:
`{"v": 1, "think_id", "kind", "task_id", "repo_slug", "model", "effort",
"caps": {max_turns, max_budget_usd, timeout_secs}, "attempt": 1|2,
"parent": <think_id of attempt 1 or null>, "started": "<iso>", "pid": <int>}`.
It is written with `O_CREAT|O_EXCL` (a collision is exit 2, nothing else
written) and carries the effective launch-time caps, so lost-detection and
budget math never depend on current config. A launch is **live** while its
`.launch.json` has no `.answer.json` and `started` is younger than its own
`timeout_secs + 120s`; older is **lost**.

`think/.lock` is a repo-wide lock file held (`fcntl.flock`, exclusive)
by `run-think` from the liveness scan through the daily-budget check to
the create-exclusive launch-record write, so two concurrent invocations
with distinct ids cannot both observe "nothing live": exactly one wins,
the other exits 4. The lock is released before `claude` is launched (the
launch record is the liveness token from then on).

Nothing is written into any worktree. The `think/` directory is
machine-local like everything under `STATE_ROOT`. The attempt-2 record's
`parent` ties the two attempts into one escalation for budget purposes.
Attempt 2 reuses the parent's question: the orchestrator copies
`<parent>.question.md` to `<parent>-2.question.md` byte-for-byte before
the relaunch, and `run-think` refuses a retry whose question differs from
the parent's (exit 2).

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
   options (unordered alternatives; the `recommendation` field stands on
   its own and need not name one of them), rationale grounded in the
   context, and open questions only for what the context cannot settle.

#### 4.6 Output contract

`run-think` passes `--json-schema` with the core constant `THINK_SCHEMA`
(the prose "two to four options" and this schema are the same rule):

```json
{
  "type": "object", "additionalProperties": false,
  "properties": {
    "recommendation": {"type": "string", "minLength": 1, "maxLength": 500},
    "rationale": {"type": "string", "minLength": 1, "maxLength": 4000},
    "options": {"type": "array", "minItems": 2, "maxItems": 4, "items": {
      "type": "object", "additionalProperties": false,
      "properties": {
        "label": {"type": "string", "minLength": 1, "maxLength": 80},
        "summary": {"type": "string", "minLength": 1, "maxLength": 1000},
        "tradeoffs": {"type": "string", "minLength": 1, "maxLength": 1000},
        "risk": {"type": "string", "enum": ["low", "medium", "high"]}},
      "required": ["label", "summary", "tradeoffs", "risk"]}},
    "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
    "open_questions": {"type": "array", "maxItems": 10, "items": {"type": "string", "minLength": 1, "maxLength": 300}},
    "evidence": {"type": "array", "maxItems": 20, "items": {"type": "string", "minLength": 1, "maxLength": 300}}
  },
  "required": ["recommendation", "rationale", "options", "confidence"]
}
```

The wrapper re-validates the returned object against exactly this
contract with a stdlib checker, `valid_think_answer(obj) -> None|str`:
required keys present; no extra keys at either level; every type as
declared; every enum value in its set; every `minItems`/`maxItems`/
`minLength`/`maxLength` bound honoured. Any violation is
`unanswered`/`no_answer` with the checker's message in `errors`. The CLI's
own validation is not trusted.

`<think_id>.answer.json`, written atomically by the wrapper in every
outcome:

```json
{
  "v": 1, "think_id": "think-triage-20260904170000", "kind": "triage",
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
that passes `valid_think_answer`. Every other case is `unanswered` with
`reason` in `max_turns|max_budget|timeout|no_answer|error` (`no_answer` =
success without a valid structured object). `answer` is `null` when
unanswered. `downgrade`/`model_attributable`/`errors` reuse the mech
helpers verbatim. `answer.json` additionally carries `attempt` and
`parent` copied from the launch record.

#### 4.7 The `run-think` verb

```
python3 "$CORE" run-think --repo-slug <slug> --session <id> --fence <fence>
  --think-id <think_id> --kind <kind> [--task-id <task_id>]
  --model $MODEL --effort <level> --cwd <repo_worktree>
  --max-turns <N> --max-budget-usd <X> --timeout-secs <T> [--add-dir tasks|think]... [--parent <think_id>]
```

`run-think` is a **fenced** verb like `write-task`: it takes the owning
orchestrator's `--session`/`--fence` and refuses under a stale or foreign
fence exactly as the other fenced verbs do (nonzero exit, nothing
written), so a stale orchestrator or a worker cannot launch one. The
fence is checked first, and checked again immediately before the launch
record is created (inside the lock).

In order:

1. Validate (exit 2, nothing written, on any failure): fence (as above);
   repo slug;
   `valid_think_id(think_id)` and its kind equals `--kind`; optional task
   id valid; model in `ROLE_ALIASES["think"]`; effort in `THINK_EFFORTS`
   (no `inherit`); caps within the mech bounds; the question file is
   exactly `STATE_ROOT/<slug>/think/<think_id>.question.md` (not an
   argument; a symlink, a missing file, or an unreadable file fails);
   `--cwd` is an existing git checkout whose `repo_slug()` (from
   `git remote get-url origin` and its common dir) equals `--repo-slug`,
   so the advisor reads only this repo; each `--add-dir` is the literal
   token `tasks` or `think`, mapped to `STATE_ROOT/<slug>/tasks` or
   `STATE_ROOT/<slug>/think` (never the slug root, so `owner.json` with
   its fence and socket path, `config.json`, and `capabilities.json` are
   never exposed); every value shell-safe (`SHELL_SAFE_RE`); the
   `.launch.json` and `.answer.json` must not already exist. Retry
   identity is an iff: a `-2` id requires `--parent` and `--parent`
   requires a `-2` id; `--parent` must equal this id minus `-2`; the
   parent's `.answer.json` must exist with `model_attributable: true`,
   the same `kind` and `task_id`, and a numeric `total_cost_usd` (a null
   parent cost refuses the retry, exit 4, since the remainder is
   undefined); this launch's `--model` must differ from the parent's
   (the survivor after `disable-model`); `<think_id>.question.md` must be
   byte-identical to the parent's question.
2. Under `think/.lock` (4.4), re-check the fence, then enforce the limits
   (exit 4, nothing written): another `.launch.json` in `think/` is live
   (4.4); or the daily ceiling (4.1, reservation semantics) would be
   exceeded; for an attempt 2, the effective `max_budget_usd` is the
   escalation cap minus attempt 1's numeric `total_cost_usd` (a remainder
   under 0.25 refuses the retry).
3. Still under the lock, write `<think_id>.launch.json` create-exclusive
   (collision: exit 2); release the lock.
4. Launch
   `claude --model <M> --effort <E> --permission-mode dontAsk --name <think_id> -p --output-format json --json-schema <THINK_SCHEMA> --max-turns <N> --max-budget-usd <X> --restricted --strict-mcp-config --tools Read,Glob,Grep [--add-dir <abs dir>]...`
   with the question on stdin, cwd `--cwd`, its own process group, killed
   on `--timeout-secs` (reusing `run_mech`'s launch/timeout/parse code,
   factored into a shared `run_headless` helper). What each flag buys,
   per the CLI's own help: `--restricted` removes the built-in tools that
   run commands or code (Bash and the other code-running tools) and
   WebFetch, and ignores user, project, and local settings files (so no
   settings-defined hooks or MCP servers load); `--strict-mcp-config`
   skips every MCP server not passed on the command line (none is);
   `--tools Read,Glob,Grep` leaves only those three built-ins, so Write,
   Edit, NotebookEdit, and WebSearch are absent; `--permission-mode
   dontAsk` denies anything that would prompt, including a Read outside
   `--cwd` and the `--add-dir` roots, and the result's
   `permission_denials` counts them. **Trust boundary:** managed
   (organization) settings and an explicit `--settings` still apply
   (`run-think` passes none). "Read-only" therefore holds relative to
   the managed configuration: on a machine whose managed settings add
   hooks or MCP servers with side effects, those run under the managed
   policy's authority and this verb cannot exclude them; the skill states
   this assumption, and an adversarial acceptance case is not possible
   without managed settings on the test machine. The residual surface on
   an unmanaged machine is: reads inside the repo checkout and the two
   state subdirectories, and the answer. AC12 proves this live (the
   advisor is asked to write, run, fetch, and read outside its roots, and
   must report that it cannot). Session persistence stays on so a human
   can `--resume` the transcript.
5. Parse the result exactly as `run_mech` does; classify `status`/`reason`
   per 4.6; write `<think_id>.answer.json` atomically. Unwritable: exit 3
   (the launch record remains and will read as lost).
6. Exit 0 when the answer file was written (answered or not); the
   orchestrator reads the file, never the exit code.

Model-attributable failure (`downgrade` or execution error naming the
alias/"model"): the orchestrator applies the existing within-role rule --
`disable-model` on the requested alias, `routing-table` again, copy the
question to `<think_id>-2.question.md`, relaunch once as `<think_id>-2
--parent <think_id>` on the survivor (a different alias by construction)
within the remaining budget. Two attempts per escalation, then decide
inline and say so. Any other `unanswered` is surfaced with the spend line; a fresh
escalation with raised caps is the human's call, next turn.

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

`status` gains a top-level `_think` summary folded from `think/*.launch.json`
and `think/*.answer.json`:

```json
"_think": {"launches": 3, "answered": 2, "unanswered": 1, "usd": 1.52, "turns": 9,
           "usd_today": 1.52, "live": ["think-triage-20260904170000"],
           "lost": ["think-incident-20260903120000"], "skipped_files": 2}
```

`launches` counts launch records; `answered`/`unanswered` count answer
files by `status`; `usd`/`turns` sum non-null values; `usd_today` sums
committed spend over launches whose `started` falls in the current UTC
day (the daily-ceiling input, reservation semantics: numeric answer cost,
else the launch's cap); `live` and `lost` list launch records with
no answer, split by the 4.4 age rule using each record's own
`timeout_secs`; unparseable or wrong-`v` files are skipped and counted in
`skipped_files`, never fatal. No per-task field. Lost detection is
polling-only: the transition from live to lost writes nothing and
generates no wake (exactly like mech `wrapper lost`); the next check-in
or heartbeat wake reports it, and there is no auto-relaunch. `_think`
cannot collide with a task id.

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
substitutes for a herdr phase or role. In particular: the review gate
remains a fresh `rev-<t>` agent running co-review; a Workflow review
inside an impl worker is a pre-review self-check only, and the
orchestrator never dispatches a Workflow *instead of* a worker.

**Precedence with the user's standing order.** The global CLAUDE.md
(Default Skill Routing) says to "orchestrate multi-task implementation
with the Workflow tool directly (planner/reviewer on the stronger model,
workers on cheaper models, per-task review)". That order governs how a
session implements a multi-task PLAN; this skill governs the herdr task
LIFECYCLE. They compose: an `implement` worker executing its committed
plan may fan the plan's tasks out over a Workflow (tiered per 5.2,
mutations under `isolation: 'worktree'`, results merged into its own
branch by the worker), and that is the standing order in action inside
one herdr task. What the Workflow never does is stand in for the herdr
worker itself: no branch, record, contract gate, or review of its own.
Where the two documents seem to disagree, this precedence rule wins and
SKILL.md states it (AC13 pins the sentence).

A Workflow launched by the orchestrator is read-only (analysis, triage
support, decomposition drafting) -- the orchestrator authors no code and
its Workflow agents write nothing.

#### 5.2 Models and effort inside a script

Models and efforts are resolved BEFORE the script is authored, never
hard-coded, never picked by judgment:

- The **orchestrator** runs `routing-table` once (Design 1) and maps
  script tiers to roles: planner/judge/synthesizer stages -> `plan`;
  reviewer/verifier stages -> `review`; implementer stages -> `impl`;
  mechanical stages -> `mech`; a single deep judge stage -> `think`. Each
  `agent()` call passes `model: <alias from the table>` and
  `effort: <level>` (omit `effort` when the table says `null`). A role
  with `"model": null` may not appear in the script: if every stage
  mapped to that role is optional (a verify or judge stage whose absence
  the author can name in the result), author the script without those
  stages and `log()` the omission; if any required stage maps to it, do
  not author the script -- report "no available model for <role>" and
  fall back to in-turn subagents or hand back.
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

The Workflow tool runs only on explicit user opt-in, in the user's own
words. The grant this skill relies on is not the kickoff itself but the
user's standing order in their global CLAUDE.md (Default Skill Routing:
"Orchestrate multi-task implementation with the Workflow tool directly
..."), reaffirmed for orchestrated dispatch in the instruction that
created this spec. The skill records that grant verbatim, scoped to
orchestrated tasks: the orchestrator may author Workflows while handling
an orchestrated task, and a briefed worker may author them inside its
task, both within the default size guideline. The brief carries the exact
line `Workflow opt-in: granted by the user's standing order (global
CLAUDE.md, Default Skill Routing) for this orchestrated task; default
size guideline`, so a worker can trace the grant to the human's words
rather than to the orchestrator. A human may narrow it per task
(`kick off <item> no-workflow` -> the brief line reads `Workflow opt-in:
withheld for this task`) or widen the size in the kickoff instruction.
Outside an orchestrated task (freeform triage or status turns) the
orchestrator uses Workflow only when the current human instruction asks
for that scale in its own words. If the standing order is ever removed
from the user's CLAUDE.md, the grant lapses with it and the brief line
must not be emitted.

#### 5.4 Results feed back through the existing lifecycle

A Workflow returns to the session that launched it and stops there.
Completion is still commits + contract + `emit-done`; a Workflow agent
never runs a `$CORE` mutating verb, `emit-done`, or `emit-review` (the
brief's ground rules say so in one line: "Workflow/subagent helpers never
call `herdr_orch_core.py`; only you emit the completion record").
Executable coverage of Workflow scripts is out of reach for the sh suites
(no Workflow runtime); the rules are pinned as brief/SKILL text (AC13)
and observed in live use. Workflow spend is untracked (interactive-class), and its
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
(`{"impl": "low"}` -> `low`, `{"plan": null}` -> `inherit`,
`{"think": "xhigh"}` -> `xhigh`); exit 5 for an unknown role, a non-object
block, an unknown key, a value outside `EFFORT_LEVELS`, a boolean/number
value, and `think` set to `null`, `low`, or `medium`.
AC2. `resolve-model --role think` prints `fable`, falls back to `opus`,
exits 4 with neither, exits 5 when `models.think` names `sonnet` or
`haiku`.
AC3. `routing-table` prints all five roles with `model`/`effort` from a
valid map and config; exits 3 with a stale map, 5 with a malformed
`effort` or `models` block; a role with no survivor prints `"model": null`
with exit 0; the verb reads `config.json` and `capabilities.json` once
each (asserted by counting opens through a patched `open` in the unit
check).
AC4. `classify-banner`: fixture texts yield `ok` (matching model and
effort), `ok` (requested `inherit`, banner shows an effort or none); with
`--json` the observed `model`/`effort` are reported (`"effort": "medium"`
for a medium banner, `null` for none, `"model": null` when unreadable);
`downgrade` (Sonnet banner under `--model fable`, regardless of effort),
`effort-mismatch` (requested `high`, banner shows no effort; requested
`high`, banner shows `medium`; requested `high`, only the `/effort`
indicator line shows `medium`), and `unreadable` (no `Claude Code v` line;
empty text; a version line followed by a model line naming no known
family; a later prompt line quoting `Claude Code v9.9.9 Opus` after a
real Sonnet banner still classifies on the first banner). ANSI-wrapped
fixtures (colour codes around the model line) classify identically to
plain ones. The fixtures use the middle-dot separator via escape.
AC5. `think-caps` prints the documented defaults (including
`daily_budget_usd`), merges a valid `think` block, applies overrides,
exits 5 on out-of-bounds, unknown key, boolean, a `contract_commands`
key, a `daily_budget_usd` outside (0, 200], or a `max_budget_usd` above
`daily_budget_usd`; `mech-caps` behaviour is unchanged (existing checks
pass untouched).
AC6. `run-think` against the fake `claude`: (a) success with a valid
structured object -> `.launch.json` then `answered`, `answer` equals the
object, spend fields copied, exit 0, and the fake saw exactly the
documented argv (model, effort, `dontAsk`, name, `-p`, json,
`--json-schema` equal to `THINK_SCHEMA`, both caps, `--restricted`,
`--strict-mcp-config`, the three tools, each `--add-dir` as the absolute
state subdirectory), the question on stdin, cwd == `--cwd`; (b)
`error_max_turns` / `error_max_budget_usd` -> `unanswered` with
`max_turns` / `max_budget`; (c) success with a missing `structured_output`,
one option, five options, an extra top-level key, an extra option key, a
501-character recommendation, or a `risk` outside the enum ->
`unanswered`/`no_answer` with the checker message in `errors`, while two
and four options with maximal in-bounds strings are `answered`; (d) a
fake sleeping past `--timeout-secs` -> `unanswered`/`timeout` and the
fake's pid is gone; (e) `modelUsage` keyed by a sonnet id under
`--model fable` -> `downgrade: true`, `model_attributable: true`; (f)
`--effort xhigh` is passed and recorded; (g) an unwritable answer path ->
exit 3 with the launch record left in place; (h) attempt 2 with
`--parent` runs with `max_budget_usd` = cap minus attempt 1's cost, and
is refused (exit 4) when the remainder is under 0.25 or when the parent
was not model-attributable.
AC7. `run-think` refuses under a stale or foreign fence like every fenced
verb (nonzero, nothing written). It exits 2 and writes nothing for: a
malformed `think_id`
(each kind with a 15-digit stamp, a `-3` suffix, uppercase), a
`think_id` whose kind disagrees with `--kind`, a missing or symlinked
question file, an `--add-dir` token other than `tasks`/`think`, a
non-git `--cwd`, a `--cwd` whose remote resolves to a different
`repo_slug`, out-of-bounds caps, a model outside `fable`/`opus`, an
effort outside `high`/`xhigh`/`max` (including `inherit`), any
shell-unsafe value, an existing `.launch.json` or `.answer.json`, a `-2`
id without `--parent`, `--parent` with a non-`-2` id, a `--parent` that is
not this id minus `-2`, a parent with a different `kind` or `task_id`, a
retry `--model` equal to the parent's, and a retry question that differs
from the parent's. Exit 4 and nothing written for: a live sibling launch
record (a younger `.launch.json` with no answer), a daily ceiling that the
requested cap would exceed (fixture answers dated today; a live sibling
dated today with no answer counts at its cap), and a parent with a null
`total_cost_usd`. A lost sibling (older than its own timeout + 120s) is
ignored and the launch proceeds (exit 0). Two concurrent `run-think`
invocations with distinct ids (started in the background against a fake
`claude` that sleeps) yield exactly one `.launch.json` and one exit 4.
AC8. `run-mech --effort high` passes `--effort high` in argv and records
`"effort": "high"` on the `start` line; without the flag argv is unchanged
from the mech spec and the line records `null`; `--effort inherit` or
`--effort turbo` exits 2 with no ledger line written.
AC9. `status` folds a `think/` fixture of three launch records with two
answered files (1.12 and 0.40 usd, 6 and 3 turns, both dated today), one
unanswered with null cost, one live launch record (no answer, young), one
lost launch record (no answer, older than its recorded timeout + 120s),
one truncated answer file, and one `v: 2` answer file into
`_think: {launches: 5, answered: 2, unanswered: 1, usd: 1.52, turns: 9,
usd_today: 1.52, live: [<id>], lost: [<id>], skipped_files: 2}`; an empty
or absent `think/` reports zeros and empty lists; a legacy task record
whose `workers[]` entry lacks `effort` is reported with `effort:
"unknown"` and passes through a full-record `write-task` rewrite
unchanged.
AC10. `watch_scan` includes `think/*.launch.json` and
`think/*.answer.json`; a launch-record write and an answer write each
flip `watch_changed`; a `.question.md` write does not.
AC11. The walkthrough suite: (a) one `routing-table` call per dispatch: a
plan kickoff launch line carries `--effort high` and the `workers[]` entry
records `effort: "high"`; an impl launch line carries no `--effort` and
records `null`; (b) a `classify-banner` `effort-mismatch` on a plan
launch leaves `capabilities.json` untouched (no `disable-model` call in
the fake log), no task record is written, and the fake herdr log shows
the pane process terminated but no `workspace close` for an adopted
resource, while a `downgrade` flips the requested alias and relaunches;
(c) a triage escalation writes the question file at the canonical path,
invokes `run-think` with the documented argv (`--add-dir tasks`), lands
`.launch.json` then `.answer.json`, `status` shows `_think`, and a second
`run-think` issued while the first is live exits 4; then an explicit
`other`-kind escalation succeeds after the first answered; (d) the brief
rendered for a kickoff contains a `## Routing` block equal to the
`routing-table` output used for the launch, the exact Workflow opt-in
line, and the one-line helper rule from 5.4; a `no-workflow` kickoff
renders the withheld line instead.
AC12 (human-verify, live): (a) one interactive launch without `--effort`
shows a banner model line with no `with ... effort` clause (confirms the
`inherit` classification); (b) one real `run-think` on this repo at
`--effort high` whose question asks the advisor to (1) create a file, (2)
run a shell command, (3) fetch a URL, (4) read a file outside its roots,
and (5) list the tools it has, lands an `answered` file whose answer
reports all four refused and only Read/Glob/Grep available, with
`permission_denials` >= 1 for the outside read and no new file on disk;
the plan's close records both outcomes.
AC13. SKILL.md (sections 1, 2, 3, 4, 7, 8, 9 as touched), `state-layout.md`,
`brief-template.md`, and `event-schema.md` describe the effort map, the
single-snapshot launch line, the banner verb and `effort-mismatch`
lifecycle, the deep-think verb, each named trigger and non-trigger, the
escalation vocabulary and limits, contracts, files, `_think`, the
Workflow decision table, the precedence sentence, the opt-in grant line
and its `no-workflow` narrowing, and the helper rule; the existing docs
drift checks pass and new ones pin each of those strings.

## Acceptance-criterion to contract-command mapping

| AC | Contract command |
| --- | --- |
| AC1-AC10, AC13 | `core-unit-suite` (`sh claude/hooks/herdr-orch.test.sh`) |
| AC11 | `orchestration-walkthrough-suite` (`sh claude/hooks/herdr-orch-contract.test.sh`) |
| AC12 | human-verify (live), recorded in the plan close |

## Review log

### Round 1 (Codex, `model_reasoning_effort=high`, 2026-09-04): needs-rework, 17 findings

| # | Sev | Finding (short) | Disposition |
| --- | --- | --- | --- |
| 1 | critical | `--add-dir` could expose `owner.json`/fence/socket; cwd and question path unbound | Folded: `--add-dir` tokens `tasks`/`think` only; question path canonical; `--cwd` slug-bound (4.7) |
| 2 | critical | "read-only" asserted from flag compatibility, not proven | Folded: per-flag effect stated from CLI help, residual surface named, live AC12(b) proves refusals |
| 3 | high | kickoff redefined as Workflow opt-in | Pushed back, reworded: the grant traces to the user's standing order and this task's instruction, recorded verbatim in the brief, narrowable per task (5.3). A per-task confirmation would contradict the user's explicit direction for this spec |
| 4 | high | think model/effort could be weak | Folded: `ROLE_ALIASES["think"]` = fable/opus; `THINK_EFFORTS` = high/xhigh/max everywhere |
| 5 | high | one-per-turn vs retry; budget doubles; no aggregate cap | Folded: escalation vs attempt vocabulary; shared budget with 0.25 floor; `daily_budget_usd` (4.1, 4.3, 4.7) |
| 6 | high | one-live-per-repo unenforceable; no launch-time caps | Folded: create-exclusive `.launch.json` with caps; `run-think` enforces liveness (4.4, 4.7) |
| 7 | high | interactive mode unbounded and contract-less | Folded: removed; explicit non-goal |
| 8 | high | banner regex accepts anything as a model | Folded: ANSI strip, anchored first version line, known-family requirement, unknown -> `unreadable`, adversarial fixtures (3, AC4) |
| 9 | high | schema vs prose vs validation mismatch | Folded: one schema (2-4 options, bounds, no extra keys), `valid_think_answer`, boundary ACs (4.6, AC6c) |
| 10 | high | legacy `workers[].effort` undefined | Folded: absent = unknown, carried forward, new launches must include (2, AC9) |
| 11 | high | `effort-mismatch` lifecycle unspecified | Folded: publish-after-launch makes it stateless; termination and non-unwind rules stated (3, AC11b) |
| 12 | high | Workflow policy vs CLAUDE.md standing order | Folded: precedence paragraph, pinned by AC13 (5.1) |
| 13 | high | think ids exceed the 32-char name limit on retry | Folded: 14-digit stamp, `-2` only; longest form is 32 (4.4, AC7) |
| 14 | medium | routing values from separate reads | Folded: `routing-table` single snapshot per dispatch (1, 2, AC3, AC11a) |
| 15 | medium | Workflow rules untested; "drop or halt" ambiguous | Folded: required/optional stage rule (5.2); brief/SKILL strings pinned (AC11d, AC13); executable script coverage declared out of reach |
| 16 | medium | `think lost` shape and wake undefined | Folded: `_think.live`/`lost` lists, polling-only, no wake (4.9, AC9) |
| 17 | medium | triggers prose-only | Folded partially: names pinned by drift checks (AC13), liveness refusal and explicit `other` in the walkthrough (AC11c); eligibility itself stays a skill rule |

### Round 2 (Codex, `model_reasoning_effort=high`, 2026-09-04): needs-rework, 11 findings -- last round per the review skill's cap; proceeding to plan

| # | Sev | Finding (short) | Disposition |
| --- | --- | --- | --- |
| 1 | high | `run-think` unfenced | Folded: fenced verb, checked before validation and again under the lock (4.7) |
| 2 | high | scan-then-create not atomic | Folded: `think/.lock` flock across scan, budget, launch write; concurrency AC (4.4, AC7) |
| 3 | high | daily ceiling ignores live/lost/null-cost runs | Folded: reservation semantics (cap until numeric cost); null parent cost refuses retry (4.1, 4.7, 4.9) |
| 4 | high | retry identity incomplete | Folded: `-2` iff `--parent`, exact base, same kind/task, different model, identical question (4.4, 4.7, AC7) |
| 5 | high | managed settings unstated | Folded: trust boundary paragraph; adversarial case declared infeasible on an unmanaged test machine (4.7) |
| 6 | medium | observed effort not exposed | Folded: `classify-banner --json` (3, AC4) |
| 7 | medium | "recommendation first" untestable | Folded: ordering requirement removed (4.5) |
| 8 | medium | core vs skill limits conflated | Folded: split; "already launched this turn" (4.1) |
| 9 | medium | AC7 lost-sibling placement | Folded (AC7) |
| 10 | low | example id format | Folded (4.6) |
| 11 | low | `run-mech --effort` invalid input | Folded (2, AC8) |
