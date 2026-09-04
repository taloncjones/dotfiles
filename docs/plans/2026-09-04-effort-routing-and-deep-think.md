# Effort Routing and Deep-Think Escalation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route per-role `--effort` deterministically through the core, verify it from the launch banner, add a bounded read-only `run-think` escalation with a structured answer contract, and document Workflow-tool routing -- all as core verbs the skill prose calls.

**Architecture:** Every decision lands in `claude/hooks/herdr_orch_core.py` as a testable function plus a CLI verb (`resolve-effort`, `routing-table`, `classify-banner`, `think-caps`, `run-think`), reusing the mech tier's caps, headless-launch, and result-parsing code through two small generalizations (`tier_caps`, `run_headless`). The skill and its references become thin callers. Tests are `check`/`ok` snippets in the two existing sh suites; no new runner.

**Tech Stack:** Python 3 stdlib only (argparse, subprocess, json, re, math, os, datetime); POSIX sh test suites; the existing fake `claude`/`herdr` executables on PATH in tests.

**Spec:** `docs/specs/2026-09-04-effort-routing-and-deep-think.md` (branch-only). Read it first; every task cites its section.

## Global Constraints

- **Precondition:** the mech tier must already be in the checkout (`grep -q 'def run_mech' claude/hooks/herdr_orch_core.py`). If it is not, STOP and report "mech tier not merged; rebase this branch onto the mech branch or wait for its merge" -- never re-implement it here.
- Stdlib-only Python; no network in tests; nothing under `STATE_ROOT` is ever git-tracked; ASCII-only source (write the banner glyphs U+00B7 and U+25CF as `\u00b7` / `\u25cf` escapes).
- `EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")`; `THINK_EFFORTS = ("high", "xhigh", "max")`; `ROLE_EFFORT_DEFAULTS = {"plan": "high", "impl": None, "review": "high", "mech": None, "think": "high"}` (spec 1).
- `think` role: `ROLE_DEFAULTS["think"] = ("fable", "opus")`, `ROLE_ALIASES["think"] = ("fable", "opus")` (spec 1).
- Think caps: defaults `max_turns 15`, `max_budget_usd 3.0`, `timeout_secs 900`, `daily_budget_usd 10.0`; bounds as `MECH_BOUNDS` plus `daily_budget_usd` finite, `0 < x <= 200`, and `max_budget_usd <= daily_budget_usd` (spec 4.3).
- `think_id` regex `think-(triage|decompose|incident|other)-\d{14}(-2)?\Z`, max 32 chars (spec 4.4).
- `run-think` exit codes: 0 answer file written; 2 validation failure (nothing written); 3 a write after the launch record failed; 4 a limit refused the launch (nothing written) (spec 4.7).
- Answer `reason` tokens: `max_turns|max_budget|timeout|no_answer|error` (spec 4.6).
- Shell-safety regex for every launch value: `SHELL_SAFE_RE` = `[A-Za-z0-9_./+:@-]+`.
- No emojis, no AI attribution, commit format `<scope>: <summary>` (<75 chars, imperative).
- Run suites from the worktree root: `sh claude/hooks/herdr-orch.test.sh` and `sh claude/hooks/herdr-orch-contract.test.sh`.
- Test snippets: `check` pipes each body into a fresh `sh -e -` (shell) or `python3 -` (body starts with `import`); suite-scope shell FUNCTIONS are invisible inside a snippet, only exported VARIABLES cross. The fake `claude` lives at `$FAKE_CLAUDE_DIR/claude` (exported) and honours `FAKE_CLAUDE_LOG`, `FAKE_CLAUDE_JSON`, `FAKE_CLAUDE_HOOK`, `FAKE_CLAUDE_SLEEP`, `FAKE_CLAUDE_RC`. Python snippets start with `$LOAD`, which binds the core module as `c`.

## File map

| File | Responsibility in this change |
| --- | --- |
| `claude/hooks/herdr_orch_core.py` | effort constants + `role_effort` + `resolve-effort`; `think` role; `routing_table` + verb; ANSI strip / `parse_banner` / `classify_banner` + verb; `tier_caps` (+ `think_caps`, `think-caps` verb); `run-mech --effort`; `valid_think_id`, `THINK_SCHEMA`, `valid_think_answer`; `run_headless`; `run_think` + verb; `_think` status fold; `WATCH_DIRS["think"]` |
| `claude/hooks/herdr-orch.test.sh` | unit checks for every function/verb above (AC1-AC10, AC13) |
| `claude/hooks/herdr-orch-contract.test.sh` | effort launch line, effort-mismatch refusal, think escalation walkthrough, brief Routing block (AC11) |
| `claude/skills/herdr-orchestration/SKILL.md` | sections 1 (routing-table in preflight), 2/2a/5 (one snapshot per dispatch), 3 (triage escalation), 4 (`_think` in the report, lost), 7 (Workflow rule of thumb), 8 (effort column, launch line, classify-banner, effort-mismatch, deep-think subsection, Workflow subsection), 9 (no new rows; note that effort-mismatch publishes nothing) |
| `claude/skills/herdr-orchestration/references/state-layout.md` | `config.effort`, `config.think`, `models.think`, `workers[].effort`, `think/` files and schemas, `_think` |
| `claude/skills/herdr-orchestration/references/brief-template.md` | `## Routing` block, Workflow opt-in line, helper rule, deep-think brief variant |
| `claude/skills/herdr-orchestration/references/event-schema.md` | `think/` launch and answer files are watched, are not events |
| `claude/contracts/td-2026-09-04-add-effort-routing-and-a-deep-think-escalation-pat-contract.json` | this task's verification contract (committed with this plan) |

## Acceptance-criterion mapping

| AC | Task | Contract command |
| --- | --- | --- |
| AC1, AC2 | 1 | core-unit-suite |
| AC3 | 2 | core-unit-suite |
| AC4 | 3 | core-unit-suite |
| AC5 | 4 | core-unit-suite |
| AC8 | 5 | core-unit-suite |
| AC6c (validator), AC7 (ids) | 6 | core-unit-suite |
| (refactor, existing checks) | 7 | core-unit-suite |
| AC6, AC7 | 8 | core-unit-suite |
| AC9, AC10 | 9 | core-unit-suite |
| AC13 | 10 | core-unit-suite |
| AC11 | 11 | orchestration-walkthrough-suite |
| AC12 | 12 | human-verify (live), recorded in the close |

---

### Task 0: Baseline and precondition

- [ ] **Step 1: Check the precondition and record the baseline**

```bash
grep -q 'def run_mech' claude/hooks/herdr_orch_core.py || { echo "[X] mech tier not present; stop"; exit 1; }
sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -1      # "<N> passed, 0 failed"
sh claude/hooks/herdr-orch-contract.test.sh 2>&1 | tail -1
```

Both must report `0 failed`; otherwise stop and report. Carry the two PASS counts into Task 1's commit body.

---

### Task 1: Effort constants, `think` role, `role_effort`, `resolve-effort`

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (constants block near `ROLE_ALIASES`; new function after `resolve_model`; new parser + handler in `main`)
- Test: `claude/hooks/herdr-orch.test.sh` (append before the final docs-drift check)

**Interfaces:**
- Produces: `EFFORT_LEVELS`, `THINK_EFFORTS`, `ROLE_EFFORT_DEFAULTS`; `ROLE_DEFAULTS["think"]`, `ROLE_ALIASES["think"]`; `role_effort(role, config) -> (level_or_None, None) | (None, 5)`; CLI `resolve-effort --repo-slug S --role R` (prints level or `inherit`; exit 5).

- [ ] **Step 1: Write the failing tests**

```sh
check "effort map: defaults, think constraints, config overrides fail closed" <<PY
$LOAD
assert c.EFFORT_LEVELS==("low","medium","high","xhigh","max") and c.THINK_EFFORTS==("high","xhigh","max")
assert c.ROLE_DEFAULTS["think"]==("fable","opus") and c.ROLE_ALIASES["think"]==("fable","opus")
assert c.role_effort("plan",{})==("high",None) and c.role_effort("review",{})==("high",None)
assert c.role_effort("impl",{})==(None,None) and c.role_effort("mech",{})==(None,None)
assert c.role_effort("think",{})==("high",None)
assert c.role_effort("impl",{"effort":{"impl":"low"}})==("low",None)
assert c.role_effort("plan",{"effort":{"plan":None}})==(None,None)
assert c.role_effort("think",{"effort":{"think":"xhigh"}})==("xhigh",None)
assert c.role_effort("review",{"effort":{"plan":"low"}})==("high",None)   # sibling override untouched
bad=[{"effort":[]},{"effort":{"bogus":"high"}},{"effort":{"plan":"turbo"}},{"effort":{"plan":True}},
     {"effort":{"plan":3}},{"effort":{"think":None}},{"effort":{"think":"low"}},{"effort":{"think":"medium"}}]
for b in bad:
    assert c.role_effort("plan",b)==(None,5), b
assert c.role_effort("orchestrator",{})==(None,5)
assert c.resolve_model("think",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{})==("fable",None)
assert c.resolve_model("think",{"fable":False,"opus":True,"sonnet":True,"haiku":True},{})==("opus",None)
assert c.resolve_model("think",{"fable":False,"opus":False,"sonnet":True,"haiku":True},{})==(None,4)
assert c.resolve_model("think",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{"models":{"think":["sonnet"]}})==(None,5)
assert c.resolve_model("think",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{"models":{"think":["haiku"]}})==(None,5)
sys.exit(0)
PY

check "resolve-effort CLI prints level or inherit, exit 5 on bad config" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-e"; mkdir -p "$RD"
[ "$($CLI resolve-effort --repo-slug slug-e --role plan)" = high ]
[ "$($CLI resolve-effort --repo-slug slug-e --role impl)" = inherit ]
[ "$($CLI resolve-effort --repo-slug slug-e --role think)" = high ]
printf '{"v":1,"user":"u","default_base":"origin/main","effort":{"impl":"low","think":"xhigh"}}' > "$RD/config.json"
[ "$($CLI resolve-effort --repo-slug slug-e --role impl)" = low ]
[ "$($CLI resolve-effort --repo-slug slug-e --role think)" = xhigh ]
printf '{"v":1,"user":"u","default_base":"origin/main","effort":{"think":null}}' > "$RD/config.json"
rc=0; $CLI resolve-effort --repo-slug slug-e --role plan 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
rc=0; $CLI resolve-effort --repo-slug slug-e --role nope 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
SH
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep -E 'FAIL'`
Expected: both new checks FAIL (`EFFORT_LEVELS` undefined; `think` role unknown).

- [ ] **Step 3: Implement**

After `ROLE_ALIASES` add the `think` entries and the effort constants:

```python
ROLE_DEFAULTS["think"] = ("fable", "opus")
ROLE_ALIASES["think"] = ("fable", "opus")   # deep think is the strong tier only

EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")
THINK_EFFORTS = ("high", "xhigh", "max")
# None = inherit: no --effort flag on the launch line.
ROLE_EFFORT_DEFAULTS = {"plan": "high", "impl": None, "review": "high",
                        "mech": None, "think": "high"}
```

(Prefer editing the two dict literals in place rather than post-assigning; the post-assignment form above is the exact content either way.) After `resolve_model`:

```python
def role_effort(role, config):
    """(level_or_None, None) on success -- None means inherit; (None, 5) when
    the role is unknown or the config 'effort' block is malformed: not a
    dict, a key outside the roles, a value outside EFFORT_LEVELS (or outside
    THINK_EFFORTS / null for think), or a bool/number. Fail closed like the
    models block."""
    if role not in ROLE_EFFORT_DEFAULTS:
        return (None, 5)
    block = (config or {}).get("effort")
    if block is None:
        return (ROLE_EFFORT_DEFAULTS[role], None)
    if not isinstance(block, dict) or any(k not in ROLE_EFFORT_DEFAULTS for k in block):
        return (None, 5)
    for k, v in block.items():
        if v is None:
            if k == "think":
                return (None, 5)
            continue
        allowed = THINK_EFFORTS if k == "think" else EFFORT_LEVELS
        if isinstance(v, bool) or not isinstance(v, str) or v not in allowed:
            return (None, 5)
    if role in block:
        return (block[role], None)
    return (ROLE_EFFORT_DEFAULTS[role], None)
```

In `main`, parser: `add("resolve-effort", "--role")`. Handler (next to `resolve-model`):

```python
    if ns.cmd == "resolve-effort":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        level, code = role_effort(ns.role, read_config(repo_dir(ns.repo_slug)))
        if code is not None:
            sys.stderr.write("[X] invalid role or config effort block\n")
            return code
        print(level or "inherit")
        return 0
```

- [ ] **Step 4: Run both suites**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -1; sh claude/hooks/herdr-orch-contract.test.sh 2>&1 | tail -1`
Expected: both `0 failed` (the `models` block now also accepts a `think` key; no existing fixture names one).

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add per-role effort map and think role to resolution" \
  -m "Baseline: unit suite <N> passed, contract suite <M> passed."
```

---

### Task 2: `routing-table` verb (one snapshot per dispatch)

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new function after `role_effort`; parser + handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Consumes: `role_effort`, `resolve_model`, `read_config`, `read_capabilities`.
- Produces: `routing_table(available, config) -> (dict|None, code|None)`; CLI `routing-table --repo-slug S --session ID` printing `{"plan": {"model": "fable", "effort": "high"}, ...}` for all five roles; exit 3 stale map, 5 malformed config; a role with no survivor prints `"model": null`, exit 0.

- [ ] **Step 1: Write the failing tests**

```sh
check "routing_table: all roles, null model on no survivor, global 3/5" <<PY
$LOAD
avail={"fable":True,"opus":True,"sonnet":True,"haiku":True}
t,code=c.routing_table(avail,{})
assert code is None and set(t)=={"plan","impl","review","mech","think"},t
assert t["plan"]=={"model":"fable","effort":"high"} and t["impl"]=={"model":"sonnet","effort":None}
assert t["mech"]=={"model":"haiku","effort":None} and t["think"]=={"model":"fable","effort":"high"}
t,code=c.routing_table({"fable":False,"opus":False,"sonnet":True,"haiku":True},{})
assert code is None and t["think"]["model"] is None and t["impl"]["model"]=="sonnet"
assert c.routing_table(None,{})==(None,3)
assert c.routing_table(avail,{"effort":{"plan":"turbo"}})==(None,5)
assert c.routing_table(avail,{"models":{"plan":["gpt"]}})==(None,5)
assert c.routing_table(None,{"models":{"plan":["gpt"]}})==(None,5)   # config error outranks stale map
# single snapshot: main reads config and capabilities exactly once
calls={"cfg":0,"cap":0}
real_cfg,real_cap=c.read_config,c.read_capabilities
c.read_config=lambda rd:(calls.__setitem__("cfg",calls["cfg"]+1) or {})
c.read_capabilities=lambda rd,s:(calls.__setitem__("cap",calls["cap"]+1) or avail)
import io,contextlib
buf=io.StringIO()
with contextlib.redirect_stdout(buf):
    rc=c.main(["routing-table","--repo-slug","slug-rt","--session","S"])
assert rc==0 and calls=={"cfg":1,"cap":1},calls
assert json.loads(buf.getvalue())["review"]=={"model":"opus","effort":"high"}
c.read_config,c.read_capabilities=real_cfg,real_cap
sys.exit(0)
PY

check "routing-table CLI exit codes" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-rt --session S --host h --pid 1)
rc=0; $CLI routing-table --repo-slug slug-rt --session S >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 3 ]
$CLI write-capabilities --repo-slug slug-rt --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
$CLI routing-table --repo-slug slug-rt --session S | python3 -c "import json,sys;t=json.load(sys.stdin);assert t['plan']=={'model':'opus','effort':'high'} and t['impl']['effort'] is None,t"
printf '{"v":1,"user":"u","default_base":"origin/main","effort":{"plan":"low","plan2":"x"}}' > "$CLAUDE_CONFIG_DIR/herdr-orch/slug-rt/config.json"
rc=0; $CLI routing-table --repo-slug slug-rt --session S >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 5 ]
SH
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep FAIL`
Expected: both FAIL (`routing_table` undefined; unknown verb).

- [ ] **Step 3: Implement**

```python
def routing_table(available, config):
    """{role: {model, effort}} for every role from one config + one
    capabilities snapshot. (table, None), or (None, 5) on a malformed
    models/effort block, (None, 3) on an absent/stale map. A role with no
    surviving model gets model None (the caller halts that launch)."""
    for role in ROLE_DEFAULTS:
        if role_preference(role, config) is None or role_effort(role, config)[1] is not None:
            return (None, 5)
    if available is None:
        return (None, 3)
    table = {}
    for role in ROLE_DEFAULTS:
        model, _ = resolve_model(role, available, config)
        table[role] = {"model": model, "effort": role_effort(role, config)[0]}
    return (table, None)
```

Parser: `add("routing-table", "--session")`. Handler:

```python
    if ns.cmd == "routing-table":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        rd = repo_dir(ns.repo_slug)
        cfg = read_config(rd)
        available = read_capabilities(rd, ns.session)
        table, code = routing_table(available, cfg)
        if code is not None:
            sys.stderr.write({3: "[X] capabilities map absent or stale; re-probe first\n",
                              5: "[X] invalid config models or effort block\n"}[code])
            return code
        print(json.dumps(table))
        return 0
```

- [ ] **Step 4: Run both suites** -- expected `0 failed` each.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add routing-table snapshot verb for model and effort"
```

---

### Task 3: Banner parsing and `classify-banner`

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new constants + functions after `classify_probe`; parser + handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `strip_ansi(text) -> str`, `parse_banner(text) -> dict|None` (`{"model": str, "effort": str|None}`), `classify_banner(parsed, alias, effort) -> str` in `ok|downgrade|effort-mismatch|unreadable`; CLI `classify-banner --model A --effort L|inherit (--text-file P | --text S) [--json]` (`--json` prints `{"class", "model", "effort"}` with the observed values or nulls).

- [ ] **Step 1: Write the failing tests**

```sh
check "parse_banner/classify_banner: families, effort clause, indicator line, ansi, adversarial" <<PY
$LOAD
D="\u00b7"; B="\u25cf"
real=" \u2590\u259b\u2588\u2588   Claude Code v2.1.260\n\u259d\u259c\u2588\u2588  Sonnet 5 with high effort "+D+" Claude Max\n  \u259d\u259d    ~/Git/repo\n"
p=c.parse_banner(real); assert p=={"model":"Sonnet 5","effort":"high"},p
assert c.classify_banner(p,"sonnet","high")=="ok"
assert c.classify_banner(p,"sonnet","inherit")=="ok"
assert c.classify_banner(p,"fable","high")=="downgrade"
assert c.classify_banner(p,"sonnet","medium")=="effort-mismatch"
noeff="Claude Code v2.1.260\n  Opus 4.6 "+D+" Claude Max\n"
p=c.parse_banner(noeff); assert p=={"model":"Opus 4.6","effort":None},p
assert c.classify_banner(p,"opus","inherit")=="ok"
assert c.classify_banner(p,"opus","high")=="effort-mismatch"
ind="Claude Code v2.1.260\n  Fable 5.1 "+D+" Claude Max\n\n   "+B+" medium "+D+" /effort\n"
p=c.parse_banner(ind); assert p=={"model":"Fable 5.1","effort":"medium"},p
assert c.classify_banner(p,"fable","high")=="effort-mismatch"
assert c.classify_banner(p,"fable","medium")=="ok"
ansi="\x1b[1mClaude Code v2.1.260\x1b[0m\r\n\x1b[38;5;208mSonnet 5 with xhigh effort\x1b[0m "+D+" Claude Max\n"
assert c.parse_banner(ansi)=={"model":"Sonnet 5","effort":"xhigh"}
assert c.strip_ansi("\x1b]0;title\x07x\x1b[2Ky")=="xy"
# adversarial: first banner wins; unknown family is unreadable, never downgrade
two="Claude Code v2.1.260\n Sonnet 5 "+D+" Claude Max\n> tell me about Claude Code v9.9.9\n Opus 9\n"
assert c.classify_banner(c.parse_banner(two),"sonnet","inherit")=="ok"
for bad in ("", "no banner here", "Claude Code v2.1.260\n", "Claude Code v2.1.260\n  Loading... "+D+" x\n", "Claude Code vX\n Sonnet 5\n"):
    assert c.parse_banner(bad) is None, bad
    assert c.classify_banner(None,"fable","high")=="unreadable"
sys.exit(0)
PY

check "classify-banner CLI" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
T=$(mktemp); printf 'Claude Code v2.1.260\n  Sonnet 5 with high effort \302\267 Claude Max\n' > "$T"
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort high --text-file "$T")" = ok ]
[ "$($CLI classify-banner --repo-slug slug-b --model fable --effort high --text-file "$T")" = downgrade ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort xhigh --text-file "$T")" = effort-mismatch ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort inherit --text 'garbage')" = unreadable ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort xhigh --text-file "$T" --json)" = '{"class": "effort-mismatch", "model": "Sonnet 5", "effort": "high"}' ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort high --text 'garbage' --json)" = '{"class": "unreadable", "model": null, "effort": null}' ]
printf 'Claude Code v2.1.260\n  Sonnet 5 \302\267 Claude Max\n' > "$T"
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort high --text-file "$T" --json)" = '{"class": "effort-mismatch", "model": "Sonnet 5", "effort": null}' ]
rc=0; $CLI classify-banner --repo-slug slug-b --model gpt --effort high --text x 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
rc=0; $CLI classify-banner --repo-slug slug-b --model sonnet --effort turbo --text x 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
SH
```

- [ ] **Step 2: Run to verify they fail** -- both FAIL (`parse_banner` undefined).

- [ ] **Step 3: Implement**

```python
_ANSI_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"            # CSI
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC
    r"|\x1b[@-Z\\-_]"                     # single-char escapes
)
_BANNER_VERSION_RE = re.compile(r"Claude Code v\d+\.\d+\.\d+")
_BANNER_MODEL_RE = re.compile(
    r"^(?P<model>(?:Fable|Opus|Sonnet|Haiku)\b[^\u00b7]*?)"
    r"(?: with (?P<effort>low|medium|high|xhigh|max) effort)?"
    r"(?:\s*\u00b7.*)?$"
)
_BANNER_EFFORT_LINE_RE = re.compile(r"\u25cf\s*(low|medium|high|xhigh|max)\s*\u00b7\s*/effort")
_MODEL_FAMILY = {"fable": "fable", "opus": "opus", "sonnet": "sonnet", "haiku": "haiku"}


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", (text or "").replace("\r", ""))


def parse_banner(text):
    """{"model", "effort"} from the FIRST Claude Code banner in text, or
    None when there is no anchored version line or the model line names no
    known family (spec 3): unknown text is unreadable, never a downgrade."""
    lines = strip_ansi(text).splitlines()
    for i, line in enumerate(lines):
        if not _BANNER_VERSION_RE.search(line):
            continue
        rest = [l for l in lines[i + 1:] if l.strip()]
        if not rest:
            return None
        model_line = re.sub(r"^[^A-Za-z]+", "", rest[0]).strip()
        m = _BANNER_MODEL_RE.match(model_line)
        if not m:
            return None
        effort = m.group("effort")
        if effort is None:
            for later in rest[1:]:
                e = _BANNER_EFFORT_LINE_RE.search(later)
                if e:
                    effort = e.group(1)
                    break
        return {"model": m.group("model").strip(), "effort": effort}
    return None


def classify_banner(parsed, alias, effort) -> str:
    """Spec 3 precedence: unreadable > downgrade > effort-mismatch > ok."""
    if not parsed:
        return "unreadable"
    if _MODEL_FAMILY[alias] not in parsed["model"].lower():
        return "downgrade"
    if effort != "inherit" and parsed.get("effort") != effort:
        return "effort-mismatch"
    return "ok"
```

Parser and handler:

```python
    cb = add("classify-banner", "--model", "--effort")
    cb.add_argument("--text-file", default=None)
    cb.add_argument("--text", default=None)
    cb.add_argument("--json", action="store_true")
    ...
    if ns.cmd == "classify-banner":
        _require(ns.model in CAP_MODELS, "model must be one of fable/opus/sonnet/haiku")
        _require(ns.effort == "inherit" or ns.effort in EFFORT_LEVELS, "effort must be a level or inherit")
        _require((ns.text is None) != (ns.text_file is None), "pass exactly one of --text/--text-file")
        text = ns.text
        if ns.text_file is not None:
            try:
                text = Path(ns.text_file).read_text(errors="replace")
            except OSError:
                text = None
        _require(text is not None, "text-file not readable")
        parsed = parse_banner(text)
        cls = classify_banner(parsed, ns.model, ns.effort)
        if ns.json:
            print(json.dumps({"class": cls, "model": (parsed or {}).get("model"),
                              "effort": (parsed or {}).get("effort")}))
        else:
            print(cls)
        return 0
```

(`_require` exits 2 on failure, matching the other verbs.)

- [ ] **Step 4: Run both suites** -- `0 failed` each.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add classify-banner verb for model and effort readback"
```

---

### Task 4: `tier_caps`, `think_caps`, `think-caps`

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (`MECH_DEFAULTS` block; replace `mech_caps` body; parser + handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `THINK_DEFAULTS`, `DAILY_BOUNDS = (0, 200)`, `tier_caps(config, tier, defaults, extra_keys, max_turns=None, max_budget_usd=None) -> (dict|None, str|None)`, `think_caps(config, max_turns=None, max_budget_usd=None)`, unchanged `mech_caps(...)`; CLI `think-caps --repo-slug S [--max-turns N] [--max-budget-usd X]`.

- [ ] **Step 1: Write the failing tests**

```sh
check "think_caps: defaults, merge, overrides, fail-closed; mech_caps unchanged" <<PY
$LOAD
caps,err=c.think_caps({})
assert err is None and caps=={"max_turns":15,"max_budget_usd":3.0,"timeout_secs":900,"daily_budget_usd":10.0},caps
caps,err=c.think_caps({"think":{"max_turns":20,"daily_budget_usd":25}},max_budget_usd=4.5)
assert err is None and caps["max_turns"]==20 and caps["max_budget_usd"]==4.5 and caps["daily_budget_usd"]==25
bad=[{"think":{"max_turns":0}},{"think":{"bogus":1}},{"think":{"max_turns":True}},{"think":[]},
     {"think":{"contract_commands":[{"name":"a","run":"true"}]}},{"think":{"daily_budget_usd":0}},
     {"think":{"daily_budget_usd":200.5}},{"think":{"daily_budget_usd":True}},
     {"think":{"max_budget_usd":12,"daily_budget_usd":10}},{"think":{"daily_budget_usd":float("nan")}}]
for b in bad:
    caps,err=c.think_caps(b); assert caps is None and err, b
caps,err=c.think_caps({},max_budget_usd=11); assert caps is None       # override above daily ceiling
assert c.mech_caps({})==({"max_turns":40,"max_budget_usd":2.0,"timeout_secs":1800},None)
caps,err=c.mech_caps({"mech":{"daily_budget_usd":5}}); assert caps is None  # not a mech key
sys.exit(0)
PY

check "think-caps CLI" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-t"; mkdir -p "$RD"
[ "$($CLI think-caps --repo-slug slug-t)" = '{"max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900, "daily_budget_usd": 10.0}' ]
printf '{"v":1,"user":"u","default_base":"origin/main","think":{"timeout_secs":600}}' > "$RD/config.json"
[ "$($CLI think-caps --repo-slug slug-t --max-turns 5)" = '{"max_turns": 5, "max_budget_usd": 3.0, "timeout_secs": 600, "daily_budget_usd": 10.0}' ]
rc=0; $CLI think-caps --repo-slug slug-t --max-budget-usd 60 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
SH
```

- [ ] **Step 2: Run to verify they fail** -- FAIL (`think_caps` undefined).

- [ ] **Step 3: Implement**

Replace `mech_caps` with:

```python
THINK_DEFAULTS = {"max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900,
                  "daily_budget_usd": 10.0}
DAILY_BOUNDS = (0, 200)


def _daily_error(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return "daily_budget_usd must be a finite number"
    lo, hi = DAILY_BOUNDS
    if not (lo < value <= hi):
        return f"daily_budget_usd must be > {lo} and <= {hi}"
    return None


def tier_caps(config, tier, defaults, extra_keys, max_turns=None, max_budget_usd=None):
    """Effective caps for a headless tier: defaults <- config.<tier> <- per-launch
    overrides. (caps, None) or (None, message). Fail closed on any malformed
    value or unknown key -- never silently default."""
    block = (config or {}).get(tier)
    caps = dict(defaults)
    if block is not None:
        if not isinstance(block, dict):
            return None, f"{tier} must be a JSON object"
        unknown = set(block) - (set(defaults) | set(extra_keys))
        if unknown:
            return None, f"{tier} has unknown keys: {sorted(unknown)}"
        for k in defaults:
            if k in block:
                caps[k] = block[k]
        if "contract_commands" in block:
            err = validate_contract(
                {"v": 1, "task_id": "x", "commands": block["contract_commands"]}, "x"
            )
            if err:
                return None, f"{tier}.contract_commands: {err}"
    if max_turns is not None:
        caps["max_turns"] = max_turns
    if max_budget_usd is not None:
        caps["max_budget_usd"] = max_budget_usd
    for k in MECH_BOUNDS:
        err = _cap_error(k, caps[k])
        if err:
            return None, err
    if "daily_budget_usd" in caps:
        err = _daily_error(caps["daily_budget_usd"])
        if err:
            return None, err
        if caps["max_budget_usd"] > caps["daily_budget_usd"]:
            return None, "max_budget_usd exceeds daily_budget_usd"
    return caps, None


def mech_caps(config, max_turns=None, max_budget_usd=None):
    return tier_caps(config, "mech", MECH_DEFAULTS, ("contract_commands",), max_turns, max_budget_usd)


def think_caps(config, max_turns=None, max_budget_usd=None):
    return tier_caps(config, "think", THINK_DEFAULTS, (), max_turns, max_budget_usd)
```

Keep `MECH_KEYS` if anything else references it (grep first; delete if unused). Parser: copy the `mech-caps` parser as `tc = add("think-caps")` with the same two optional args; handler identical to `mech-caps` but calling `think_caps`.

- [ ] **Step 4: Run both suites** -- `0 failed` each (all existing mech-caps checks untouched).

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Generalize tier caps and add think-caps verb"
```

---

### Task 5: `run-mech --effort` passthrough

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (`run_mech` argv + start line; `run-mech` parser/validation)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `run-mech` accepts optional `--effort <level>`; `run_mech` argv inserts `--effort <level>` right after `--model <alias>` when set; ledger `start` line carries `"effort": <level>|null`.

- [ ] **Step 1: Write the failing test** (model it on the existing run-mech success check; the scaffold below is complete)

```sh
check "run-mech --effort passes the flag and records it; absent -> null and argv unchanged" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-me"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
BASE=$(git -C "$WT" rev-parse HEAD); printf 'brief\n' > "$RD/tasks/td-me.brief.md"
export PATH="$FAKE_CLAUDE_DIR:$PATH" FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.1,"modelUsage":{"claude-haiku-4-5-20251001":{}}}' > "$FAKE_CLAUDE_JSON"
base="$CLI run-mech --repo-slug slug-me --task-id td-me --workspace w1 --agent mech-td-me --model haiku --worktree $WT --base-sha $BASE --brief-file $RD/tasks/td-me.brief.md --max-turns 5 --max-budget-usd 0.5 --timeout-secs 60"
$base --launch-id mech-td-me-1 --effort high
grep -qx -- '--effort' "$FAKE_CLAUDE_LOG.argv" && grep -qx -- 'high' "$FAKE_CLAUDE_LOG.argv"
python3 -c "import json;l=[json.loads(x) for x in open('$RD/tasks/td-me.spend.jsonl')];assert l[0]['kind']=='start' and l[0]['effort']=='high',l"
$base --launch-id mech-td-me-2
! grep -qx -- '--effort' "$FAKE_CLAUDE_LOG.argv"
python3 -c "import json;l=[json.loads(x) for x in open('$RD/tasks/td-me.spend.jsonl')];assert l[2]['kind']=='start' and l[2]['effort'] is None,l"
rc=0; $base --launch-id mech-td-me-3 --effort turbo 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
rc=0; $base --launch-id mech-td-me-4 --effort inherit 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
[ "$(wc -l < "$RD/tasks/td-me.spend.jsonl")" -eq 4 ]      # two launches, no line for the refused ones
SH
```

- [ ] **Step 2: Run to verify it fails** -- FAIL (unknown argument `--effort`).

- [ ] **Step 3: Implement**

Parser: `rm.add_argument("--effort", default=None)`. In the `run-mech` handler, after the model check: `_require(ns.effort is None or ns.effort in EFFORT_LEVELS, "effort must be one of low/medium/high/xhigh/max")`. In `run_mech`:

```python
    append_spend(rd, a.task_id, dict(base, kind="start", role="mech",
                                     model=a.model, effort=getattr(a, "effort", None),
                                     ts=start_ts, **caps))
    ...
    argv = ["claude", "--model", a.model]
    if getattr(a, "effort", None):
        argv += ["--effort", a.effort]
    argv += ["--permission-mode", "auto", "--name", a.agent, "-p", "--output-format", "json",
             "--max-turns", str(a.max_turns), "--max-budget-usd", str(a.max_budget_usd)]
```

- [ ] **Step 4: Run both suites** -- `0 failed` (the existing exact-argv mech check passes because nothing is inserted when `--effort` is absent).

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Pass optional effort through run-mech and the ledger"
```

---

### Task 6: Think identity, schema, and answer validator

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new constants + functions after `valid_mech_agent`)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `THINK_KINDS`, `THINK_ID_RE`, `valid_think_id(tid) -> bool`, `think_kind(tid) -> str`, `THINK_SCHEMA` (dict, spec 4.6 verbatim), `_check_schema(obj, schema, path) -> str|None`, `valid_think_answer(obj) -> str|None` (None = valid).

- [ ] **Step 1: Write the failing tests**

```sh
check "think ids: every kind fits 32 with the retry suffix; validator matches THINK_SCHEMA exactly" <<PY
$LOAD
for k in ("triage","decompose","incident","other"):
    for suf in ("","-2"):
        tid=f"think-{k}-20260904170000{suf}"
        assert c.valid_think_id(tid) and len(tid)<=32 and re.fullmatch(c.AGENT_NAME_RE.pattern,tid), tid
        assert c.think_kind(tid)==k
for bad in ("think-triage-202609041700001","think-triage-20260904170000-3","think-Triage-20260904170000",
            "think-triage-20260904T170000Z","think-x-20260904170000","",None,"think-triage-20260904170000-2-2"):
    assert not c.valid_think_id(bad), bad
opt=lambda i:{"label":f"o{i}","summary":"s","tradeoffs":"t","risk":"low"}
good={"recommendation":"r","rationale":"why","options":[opt(1),opt(2)],"confidence":"high"}
assert c.valid_think_answer(good) is None
full=dict(good,options=[opt(i) for i in range(4)],open_questions=["q"]*10,evidence=["e"]*20,
          recommendation="x"*500,rationale="y"*4000)
assert c.valid_think_answer(full) is None
bad=[None,[],{},dict(good,options=[opt(1)]),dict(good,options=[opt(i) for i in range(5)]),
     dict(good,extra=1),dict(good,options=[dict(opt(1),x=1),opt(2)]),dict(good,recommendation="x"*501),
     dict(good,options=[dict(opt(1),risk="none"),opt(2)]),dict(good,confidence="sure"),
     dict(good,open_questions=["q"]*11),dict(good,evidence=[""]),dict(good,rationale=""),
     dict(good,options=[opt(1),{"label":"a","summary":"s","risk":"low"}]),dict(good,recommendation=3)]
for b in bad:
    assert isinstance(c.valid_think_answer(b),str), b
assert c.THINK_SCHEMA["properties"]["options"]["minItems"]==2 and c.THINK_SCHEMA["additionalProperties"] is False
sys.exit(0)
PY
```

- [ ] **Step 2: Run to verify it fails** -- FAIL (`valid_think_id` undefined).

- [ ] **Step 3: Implement**

```python
THINK_KINDS = ("triage", "decompose", "incident", "other")
THINK_ID_RE = re.compile(r"think-(triage|decompose|incident|other)-\d{14}(-2)?\Z")
THINK_REASONS = ("max_turns", "max_budget", "timeout", "no_answer", "error")


def valid_think_id(tid) -> bool:
    return isinstance(tid, str) and len(tid) <= 32 and bool(THINK_ID_RE.match(tid))


def think_kind(tid) -> str:
    return tid.split("-")[1]


def _s(mx):
    return {"type": "string", "minLength": 1, "maxLength": mx}


THINK_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "recommendation": _s(500),
        "rationale": _s(4000),
        "options": {"type": "array", "minItems": 2, "maxItems": 4, "items": {
            "type": "object", "additionalProperties": False,
            "properties": {"label": _s(80), "summary": _s(1000), "tradeoffs": _s(1000),
                           "risk": {"type": "string", "enum": ["low", "medium", "high"]}},
            "required": ["label", "summary", "tradeoffs", "risk"]}},
        "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
        "open_questions": {"type": "array", "maxItems": 10, "items": _s(300)},
        "evidence": {"type": "array", "maxItems": 20, "items": _s(300)},
    },
    "required": ["recommendation", "rationale", "options", "confidence"],
}


def _check_schema(obj, schema, path="$"):
    """Minimal checker for the subset THINK_SCHEMA uses: object/array/string,
    properties, required, additionalProperties:false, enum, min/maxItems,
    min/maxLength. Returns the first violation as a string, else None."""
    t = schema.get("type")
    if t == "object":
        if not isinstance(obj, dict):
            return f"{path}: expected object"
        props = schema.get("properties", {})
        for k in schema.get("required", []):
            if k not in obj:
                return f"{path}: missing {k}"
        if schema.get("additionalProperties") is False:
            extra = set(obj) - set(props)
            if extra:
                return f"{path}: unexpected keys {sorted(extra)}"
        for k, sub in props.items():
            if k in obj:
                err = _check_schema(obj[k], sub, f"{path}.{k}")
                if err:
                    return err
        return None
    if t == "array":
        if not isinstance(obj, list):
            return f"{path}: expected array"
        if "minItems" in schema and len(obj) < schema["minItems"]:
            return f"{path}: fewer than {schema['minItems']} items"
        if "maxItems" in schema and len(obj) > schema["maxItems"]:
            return f"{path}: more than {schema['maxItems']} items"
        for i, item in enumerate(obj):
            err = _check_schema(item, schema["items"], f"{path}[{i}]")
            if err:
                return err
        return None
    if t == "string":
        if not isinstance(obj, str):
            return f"{path}: expected string"
        if "enum" in schema and obj not in schema["enum"]:
            return f"{path}: not one of {schema['enum']}"
        if len(obj) < schema.get("minLength", 0):
            return f"{path}: too short"
        if len(obj) > schema.get("maxLength", 10 ** 9):
            return f"{path}: too long"
        return None
    return f"{path}: unsupported schema type {t}"


def valid_think_answer(obj):
    return _check_schema(obj, THINK_SCHEMA)
```

- [ ] **Step 4: Run both suites** -- `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add think id rules, answer schema, and validator"
```

---

### Task 7: Extract `run_headless` from `run_mech` (pure refactor)

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py:run_mech` (the Popen/communicate/timeout/parse block)

**Interfaces:**
- Produces: `run_headless(argv, cwd, stdin_text, timeout_secs) -> (subtype, result, exit_code)`; `subtype` is `"timeout"`, `"unparseable"`, or the result's own `subtype`; `result` is the parsed result dict or None; `exit_code` int or None (launch failed).
- `run_mech` behaviour is byte-for-byte unchanged (existing checks are the test).

- [ ] **Step 1: Confirm the existing coverage that guards this refactor**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep -c 'PASS  run-mech'`
Expected: at least 3 (success, cap-hit, timeout checks exist on the mech branch).

- [ ] **Step 2: Implement the extraction**

```python
def run_headless(argv, cwd, stdin_text, timeout_secs):
    """Run `claude -p` with the text on stdin in its own process group; kill
    the group on timeout. (subtype, result, exit_code) where subtype is
    'timeout', 'unparseable', or the result's subtype."""
    subtype, result, exit_code, stdout = "unparseable", None, None, ""
    try:
        proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
    except OSError as e:
        sys.stderr.write(f"[X] cannot launch claude: {e}\n")
        return subtype, result, exit_code
    try:
        stdout, _err = proc.communicate(stdin_text, timeout=timeout_secs)
        exit_code = proc.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.wait()
        return "timeout", None, proc.returncode
    result = parse_claude_result(stdout)
    if result is not None:
        subtype = str(result.get("subtype") or "unparseable")
    return subtype, result, exit_code
```

In `run_mech`, replace the block from `subtype, result, exit_code, stdout = ...` through the `if subtype != "timeout": ... ` parse with:

```python
    subtype, result, exit_code = run_headless(argv, a.worktree, brief, timeout_secs)
```

- [ ] **Step 3: Run both suites** -- `0 failed`, same PASS counts as Task 6's run.

- [ ] **Step 4: Commit**

```bash
git add claude/hooks/herdr_orch_core.py
git commit -m "herdr: Extract run_headless from run_mech"
```

---

### Task 8: `run-think` verb

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new functions after `run_mech`; parser + handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Consumes: `run_headless`, `valid_think_id`, `think_kind`, `THINK_SCHEMA`, `valid_think_answer`, `think_caps` bounds via `_cap_error`, `models_used`, `is_downgrade`, `result_errors`, `model_attributable`, `write_json_atomic`, `repo_slug`, `_git`, `contained`, `state_root`, `SHELL_SAFE_RE`.
- Produces: `think_dir(rd) -> Path`; `think_scan(rd, now_ts) -> {"launches": [...records], "answers": {think_id: record}, "live": [...], "lost": [...], "skipped_files": n}`; `think_usd_today(scan, today_prefix) -> float` (reservation semantics: numeric answer cost, else the launch's `caps.max_budget_usd`); `write_launch_record(path, rec) -> bool` (create-exclusive); `think_lock(rd)` context manager (`fcntl.flock` on `think/.lock`); `run_think(rd, a, question, caps, add_dirs, attempt, parent, budget) -> int`; CLI `run-think` (fenced: `--session`/`--fence`) per spec 4.7.

- [ ] **Step 1: Write the failing tests** (one Python check for the pure helpers, one shell check for the verb)

```sh
check "think_scan/think_usd_today: live vs lost by each record's own timeout; today sum" <<PY
$LOAD
rd=tempfile.mkdtemp(); td=os.path.join(rd,"think"); os.mkdir(td)
def w(name,rec): open(os.path.join(td,name),"w").write(json.dumps(rec))
L=lambda tid,started,to=900:{"v":1,"think_id":tid,"kind":c.think_kind(tid),"task_id":None,"repo_slug":"s","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":to},"attempt":1,"parent":None,"started":started,"pid":1}
w("think-triage-20260904100000.launch.json",L("think-triage-20260904100000","2026-09-04T10:00:00Z"))
w("think-triage-20260904100000.answer.json",{"v":1,"think_id":"think-triage-20260904100000","status":"answered","total_cost_usd":1.12,"num_turns":6,"started":"2026-09-04T10:00:00Z"})
w("think-other-20260904110000.launch.json",L("think-other-20260904110000","2026-09-04T11:00:00Z"))
w("think-other-20260904110000.answer.json",{"v":1,"think_id":"think-other-20260904110000","status":"answered","total_cost_usd":0.40,"num_turns":3,"started":"2026-09-04T11:00:00Z"})
w("think-incident-20260904120000.launch.json",L("think-incident-20260904120000","2026-09-04T12:00:00Z"))
w("think-incident-20260904120000.answer.json",{"v":1,"think_id":"think-incident-20260904120000","status":"unanswered","total_cost_usd":None,"num_turns":None,"started":"2026-09-04T12:00:00Z"})
w("think-decompose-20260904125900.launch.json",L("think-decompose-20260904125900","2026-09-04T12:59:00Z"))      # live: 1 min old
w("think-incident-20260903120000.launch.json",L("think-incident-20260903120000","2026-09-03T12:00:00Z",600))  # lost
open(os.path.join(td,"think-other-20260904130000.answer.json"),"w").write('{"v":1,"trunc')
w("think-other-20260904140000.answer.json",{"v":2,"think_id":"x"})
s=c.think_scan(rd,"2026-09-04T13:00:00Z")
assert len(s["launches"])==5 and set(s["answers"])=={"think-triage-20260904100000","think-other-20260904110000","think-incident-20260904120000"},s
assert s["live"]==["think-decompose-20260904125900"] and s["lost"]==["think-incident-20260903120000"] and s["skipped_files"]==2,s
# reservation: answered 1.12 + 0.40, unanswered null cost counts its 3.0 cap, live decompose counts its 3.0 cap
assert c.think_usd_today(s,"2026-09-04")==7.52, c.think_usd_today(s,"2026-09-04")
assert c.think_usd_today(s,"2026-09-03")==3.0                                   # lost launch counts its cap
assert c.run_headless(["sh","-c","sleep 5"], ".", "", 1)[0]=="timeout"
e=c.think_scan(tempfile.mkdtemp(),"2026-09-04T13:00:00Z"); assert e["launches"]==[] and e["live"]==[] and e["skipped_files"]==0
sys.exit(0)
PY

check "run-think: argv, launch record, answered/unanswered, limits, exit codes" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
SLUG="github-com-org-repo-cafef00d"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/$SLUG"; mkdir -p "$RD/think" "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$WT" remote add origin https://github.com/org/repo.git
SLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/repo.git'))")
RD="$CLAUDE_CONFIG_DIR/herdr-orch/$SLUG"; mkdir -p "$RD/think" "$RD/tasks"
export PATH="$FAKE_CLAUDE_DIR:$PATH" FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"
FE=$($CLI claim-owner --repo-slug $SLUG --session S --host h --pid 1)
ID=think-triage-20260904170000
printf 'Which item first?\n' > "$RD/think/$ID.question.md"
GOOD='{"recommendation":"do A","rationale":"because","options":[{"label":"A","summary":"s","tradeoffs":"t","risk":"low"},{"label":"B","summary":"s","tradeoffs":"t","risk":"medium"}],"confidence":"high"}'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.9,"duration_ms":1000,"session_id":"sid","permission_denials":[{"tool":"Read"}],"modelUsage":{"claude-fable-5-1":{}},"structured_output":%s}' "$GOOD" > "$FAKE_CLAUDE_JSON"
base="$CLI run-think --repo-slug $SLUG --session S --fence $FE --kind triage --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60"
rc=0; $CLI run-think --repo-slug $SLUG --session S --fence 999 --kind triage --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$RD/think/$ID.launch.json" ]                 # stale fence refused, nothing written
$base --think-id $ID --add-dir tasks
python3 - "$RD" "$ID" "$WT" "$FAKE_CLAUDE_LOG" <<'PY'
import json,sys,os
rd,tid,wt,log=sys.argv[1:]
l=json.load(open(f"{rd}/think/{tid}.launch.json")); a=json.load(open(f"{rd}/think/{tid}.answer.json"))
assert l["think_id"]==tid and l["caps"]["timeout_secs"]==60 and l["attempt"]==1 and l["parent"] is None and l["effort"]=="high",l
assert a["status"]=="answered" and a["answer"]["recommendation"]=="do A" and a["total_cost_usd"]==0.9 and a["num_turns"]==4
assert a["permission_denials"]==1 and a["models_used"]==["claude-fable-5-1"] and a["downgrade"] is False and a["attempt"]==1,a
argv=open(log+".argv").read().splitlines()
schema=json.load(open(os.devnull)) if False else None
exp=["claude","--model","fable","--effort","high","--permission-mode","dontAsk","--name",tid,"-p","--output-format","json","--json-schema"]
assert argv[:len(exp)]==exp,argv
i=argv.index("--json-schema"); import importlib.util
s=importlib.util.spec_from_file_location("c","claude/hooks/herdr_orch_core.py");c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
assert json.loads(argv[i+1])==c.THINK_SCHEMA
tail=argv[i+2:]
assert tail==["--max-turns","15","--max-budget-usd","3.0","--restricted","--strict-mcp-config","--tools","Read,Glob,Grep","--add-dir",f"{rd}/tasks"],tail
assert open(log+".stdin").read()=="Which item first?\n"
assert os.path.realpath(open(log+".cwd").read().strip())==os.path.realpath(wt)
PY
# limits: second launch while the first is live -> exit 4, nothing written
ID2=think-other-20260904170100; printf 'q\n' > "$RD/think/$ID2.question.md"
rm "$RD/think/$ID.answer.json"                                # make the first launch look live again
rc=0; $base --think-id $ID2 2>/dev/null || rc=$?; [ "$rc" -eq 4 ] && [ ! -e "$RD/think/$ID2.launch.json" ]
# lost sibling is ignored: backdate the first launch beyond 60+120s
python3 -c "import json;p='$RD/think/$ID.launch.json';d=json.load(open(p));d['started']='2020-01-01T00:00:00Z';json.dump(d,open(p,'w'))"
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":15,"total_cost_usd":2.0}' > "$FAKE_CLAUDE_JSON"
$base --think-id $ID2
python3 -c "import json;a=json.load(open('$RD/think/$ID2.answer.json'));assert a['status']=='unanswered' and a['reason']=='max_turns' and a['answer'] is None,a"
# no_answer: success without a valid object; boundary variants
ID3=think-other-20260904170200; printf 'q\n' > "$RD/think/$ID3.question.md"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.2,"structured_output":{"recommendation":"r","rationale":"w","options":[{"label":"a","summary":"s","tradeoffs":"t","risk":"low"}],"confidence":"high"}}' > "$FAKE_CLAUDE_JSON"
$base --think-id $ID3
python3 -c "import json;a=json.load(open('$RD/think/$ID3.answer.json'));assert a['reason']=='no_answer' and 'fewer than 2' in a['errors'][0],a"
# timeout: fake sleeps past --timeout-secs; pid gone afterwards
ID4=think-incident-20260904170300; printf 'q\n' > "$RD/think/$ID4.question.md"
# concurrency: two distinct ids racing -> exactly one launch record and one exit 4
IDA=think-other-20260904170400; IDB=think-other-20260904170500
printf 'q\n' > "$RD/think/$IDA.question.md"; printf 'q\n' > "$RD/think/$IDB.question.md"
python3 -c "import json;p='$RD/think/$ID2.launch.json';d=json.load(open(p));d['started']='2020-01-01T00:00:00Z';json.dump(d,open(p,'w'))"
for X in $ID3 $ID4; do [ -e "$RD/think/$X.launch.json" ] && python3 -c "import json;p='$RD/think/$X.launch.json';d=json.load(open(p));d['started']='2020-01-01T00:00:00Z';json.dump(d,open(p,'w'))"; done
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.1}' > "$FAKE_CLAUDE_JSON"
FAKE_CLAUDE_SLEEP=2 FAKE_CLAUDE_LOG="$RD/logA" $base --think-id $IDA >/dev/null 2>&1 & PA=$!
FAKE_CLAUDE_SLEEP=2 FAKE_CLAUDE_LOG="$RD/logB" $base --think-id $IDB >/dev/null 2>&1 & PB=$!
ra=0; wait $PA || ra=$?; rb=0; wait $PB || rb=$?
[ $((ra + rb)) -eq 4 ] && [ "$(ls "$RD/think/" | grep -c -E "($IDA|$IDB)\.launch\.json")" -eq 1 ]
SH
```

Note: the timeout sub-case needs `--timeout-secs` below the fake's sleep, but the floor is 60 s. Keep it as a separate check using a 61 s sleep only if the suite budget allows; otherwise assert the timeout path through the Python API directly (`c.run_headless(["sh","-c","sleep 5"], ".", "", 1)` -> `("timeout", None, -9)`), which is what the mech suite already does for its own timeout check. Add that one-liner to the Python check above.

Add a third check for the remaining exit-2 and exit-4 cases:

```sh
check "run-think exit 2 validation cases write nothing; daily ceiling and retry math exit 4" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$WT" remote add origin https://github.com/org/repo2.git
SLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/repo2.git'))")
RD="$CLAUDE_CONFIG_DIR/herdr-orch/$SLUG"; mkdir -p "$RD/think"
ID=think-triage-20260904180000; printf 'q\n' > "$RD/think/$ID.question.md"
export PATH="$FAKE_CLAUDE_DIR:$PATH" FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"; : > "$FAKE_CLAUDE_JSON"
FE=$($CLI claim-owner --repo-slug $SLUG --session S --host h --pid 1)
ok="--repo-slug $SLUG --session S --fence $FE --kind triage --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60"
try() { rc=0; $CLI run-think "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || { echo "expected 2 got $rc for: $*" >&2; exit 1; }; }
try $ok --think-id think-triage-2026090418000                              # 13-digit stamp
try $ok --think-id think-triage-20260904180000-3
try $ok --think-id think-Triage-20260904180000
try $ok --think-id think-other-20260904180000                              # kind disagrees with --kind triage
F2="--repo-slug $SLUG --session S --fence $FE --kind triage"
try $F2 --model sonnet --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID
try $F2 --model fable --effort inherit --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID
try $F2 --model fable --effort medium --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID
try $F2 --model fable --effort high --cwd $WT --max-turns 0 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID
try $ok --think-id think-triage-20260904180000-2                              # -2 without --parent
try $ok --think-id $ID --parent think-triage-20260904170000                    # --parent with a non -2 id
try $ok --think-id $ID --add-dir owner
try $ok --think-id $ID --add-dir "$RD"
try $F2 --model fable --effort high --cwd "$(mktemp -d)" --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID   # non-git cwd
OTHER=$(mktemp -d); git -C "$OTHER" init -q; git -C "$OTHER" -c user.name=t -c user.email=t@x commit -q --allow-empty -m b; git -C "$OTHER" remote add origin https://github.com/org/elsewhere.git
try $F2 --model fable --effort high --cwd $OTHER --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID          # foreign repo
rm "$RD/think/$ID.question.md"; try $ok --think-id $ID; printf 'q\n' > "$RD/think/$ID.real.md"; ln -s "$RD/think/$ID.real.md" "$RD/think/$ID.question.md"; try $ok --think-id $ID
rm "$RD/think/$ID.question.md"; printf 'q\n' > "$RD/think/$ID.question.md"
: > "$RD/think/$ID.launch.json"; try $ok --think-id $ID; rm "$RD/think/$ID.launch.json"
[ ! -e "$FAKE_CLAUDE_LOG.argv" ]                                            # never launched
# daily ceiling: two answered launches today at 3.0 each plus one null-cost launch reserved at its 3.0 cap = 9.0 of 10.0; a 3.0 cap must refuse with 4
TODAY=$(date -u +%Y-%m-%d)
for n in 1 2 3; do printf '{"v":1,"think_id":"think-other-2026090410000%s","kind":"other","task_id":null,"repo_slug":"%s","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":60},"attempt":1,"parent":null,"started":"%sT10:00:0%sZ","pid":1}' "$n" "$SLUG" "$TODAY" "$n" > "$RD/think/think-other-2026090410000$n.launch.json"; done
for n in 1 2; do printf '{"v":1,"think_id":"think-other-2026090410000%s","status":"answered","total_cost_usd":3.0,"num_turns":1,"started":"%sT10:00:0%sZ"}' "$n" "$TODAY" "$n" > "$RD/think/think-other-2026090410000$n.answer.json"; done
printf '{"v":1,"think_id":"think-other-20260904100003","status":"unanswered","total_cost_usd":null,"num_turns":null,"started":"%sT10:00:03Z"}' "$TODAY" > "$RD/think/think-other-20260904100003.answer.json"
rc=0; $CLI run-think $ok --think-id $ID 2>/dev/null || rc=$?; [ "$rc" -eq 4 ] && [ ! -e "$RD/think/$ID.launch.json" ]
rm "$RD"/think/think-other-*.answer.json "$RD"/think/think-other-*.launch.json
# retry rules: parent not model-attributable -> 2; same model as parent -> 2; question differs -> 2; parent kind differs -> 2;
# null parent cost -> 4; attributable with 2.9 spent of 3.0 -> 4 (remainder < 0.25); with 1.0 spent -> runs with cap 2.0
P=think-triage-20260904190000; printf 'q\n' > "$RD/think/$P.question.md"; printf 'q\n' > "$RD/think/$P-2.question.md"
PA() { printf '{"v":1,"think_id":"%s","kind":"%s","task_id":null,"model":"fable","status":"unanswered","reason":"error","model_attributable":%s,"total_cost_usd":%s,"num_turns":1,"started":"2020-01-01T00:00:00Z","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":60}}' "$P" "$1" "$2" "$3" > "$RD/think/$P.answer.json"; }
R2="--repo-slug $SLUG --session S --fence $FE --kind triage --model opus --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $P-2 --parent $P"
PA triage false 1.0;  try $R2
PA triage true 1.0;   try $ok --think-id $P-2 --parent $P                      # same model as parent (fable)
PA incident true 1.0; try $R2                                                    # parent kind differs
PA triage true 1.0;   printf 'different\n' > "$RD/think/$P-2.question.md"; try $R2; printf 'q\n' > "$RD/think/$P-2.question.md"
PA triage true null;  rc=0; $CLI run-think $R2 2>/dev/null || rc=$?; [ "$rc" -eq 4 ]
PA triage true 2.9;   rc=0; $CLI run-think $R2 2>/dev/null || rc=$?; [ "$rc" -eq 4 ]
PA triage true 1.0
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":3,"total_cost_usd":2.0}' > "$FAKE_CLAUDE_JSON"
$CLI run-think $R2
grep -qx -- '2.0' "$FAKE_CLAUDE_LOG.argv"
python3 -c "import json;l=json.load(open('$RD/think/$P-2.launch.json'));a=json.load(open('$RD/think/$P-2.answer.json'));assert l['attempt']==2 and l['parent']=='$P' and l['caps']['max_budget_usd']==2.0 and a['reason']=='max_budget' and a['parent']=='$P',(l,a)"
SH
```

- [ ] **Step 2: Run to verify they fail** -- FAIL (`think_scan` undefined; unknown verb).

- [ ] **Step 3: Implement**

```python
THINK_TOOLS = "Read,Glob,Grep"
THINK_ADD_DIRS = ("tasks", "think")
THINK_RETRY_FLOOR_USD = 0.25
THINK_LOST_GRACE_SECS = 120


def think_dir(rd) -> Path:
    return Path(rd) / "think"


def _parse_iso(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def _load_v1(path):
    try:
        rec = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) and rec.get("v") == 1 and not isinstance(rec.get("v"), bool) else None


def think_scan(rd, now_ts):
    """Launch and answer records under think/, plus live/lost lists computed
    from each launch record's own timeout (spec 4.4). Never raises."""
    out = {"launches": [], "answers": {}, "live": [], "lost": [], "skipped_files": 0}
    d = think_dir(rd)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    now = _parse_iso(now_ts)
    for name in names:
        for suffix in (".launch.json", ".answer.json"):
            if not name.endswith(suffix):
                continue
            tid = name[: -len(suffix)]
            if not valid_think_id(tid):
                continue
            rec = _load_v1(d / name)
            if rec is None or rec.get("think_id") != tid:
                out["skipped_files"] += 1
                continue
            if suffix == ".launch.json":
                out["launches"].append(rec)
            else:
                out["answers"][tid] = rec
    for rec in out["launches"]:
        tid = rec["think_id"]
        if tid in out["answers"]:
            continue
        started = _parse_iso(rec.get("started"))
        caps = rec.get("caps") if isinstance(rec.get("caps"), dict) else {}
        to = caps.get("timeout_secs") if isinstance(caps.get("timeout_secs"), int) else MECH_BOUNDS["timeout_secs"][1]
        if started is not None and now is not None and (now - started).total_seconds() <= to + THINK_LOST_GRACE_SECS:
            out["live"].append(tid)
        else:
            out["lost"].append(tid)
    return out


def think_usd_today(scan, today_prefix) -> float:
    """Committed spend for the UTC day (spec 4.1 reservation semantics): per
    launch record started today, the answer's numeric total_cost_usd when
    one exists, else the launch's reserved caps.max_budget_usd."""
    total = 0.0
    for launch in scan["launches"]:
        if not (isinstance(launch.get("started"), str) and launch["started"].startswith(today_prefix)):
            continue
        ans = scan["answers"].get(launch["think_id"])
        cost = (ans or {}).get("total_cost_usd")
        if ans is not None and cost is not None and _finite_nonneg(cost):
            total += cost
        else:
            caps = launch.get("caps") if isinstance(launch.get("caps"), dict) else {}
            cap = caps.get("max_budget_usd")
            total += cap if (cap is not None and _finite_nonneg(cap)) else 0.0
    return round(total, 4)


@contextlib.contextmanager
def think_lock(rd):
    """Repo-wide exclusive lock over the liveness/budget check and the launch
    record write (spec 4.4). Released before claude is launched."""
    d = think_dir(rd)
    d.mkdir(parents=True, exist_ok=True)
    fd = os.open(d / ".lock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def write_launch_record(path, rec) -> bool:
    """Create-exclusive write; False when the file already exists or cannot
    be written (the caller maps that to exit 2)."""
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except OSError:
        return False
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(rec, indent=2) + "\n")
    return True


def think_outcome(subtype, result):
    """(status, reason, answer, errors) per spec 4.6."""
    errors = result_errors(result)
    if subtype in _CAP_SUBTYPES:
        return "unanswered", _CAP_SUBTYPES[subtype], None, errors
    if subtype == "timeout":
        return "unanswered", "timeout", None, errors
    if subtype == "success":
        answer = (result or {}).get("structured_output")
        err = valid_think_answer(answer)
        if err is None:
            return "answered", None, answer, errors
        return "unanswered", "no_answer", None, [err] + errors
    return "unanswered", "error", None, errors


def run_think(rd, a, question, launch, add_dirs) -> int:
    """Spec 4.7 steps 4-6, after the handler wrote the launch record under
    the lock. Exit 0 answer file written; 3 answer unwritable."""
    d = think_dir(rd)
    caps, started, attempt, parent = launch["caps"], launch["started"], launch["attempt"], launch["parent"]
    argv = ["claude", "--model", a.model, "--effort", a.effort, "--permission-mode", "dontAsk",
            "--name", a.think_id, "-p", "--output-format", "json",
            "--json-schema", json.dumps(THINK_SCHEMA, separators=(",", ":")),
            "--max-turns", str(caps["max_turns"]), "--max-budget-usd", str(caps["max_budget_usd"]),
            "--restricted", "--strict-mcp-config", "--tools", THINK_TOOLS]
    for ad in add_dirs:
        argv += ["--add-dir", ad]
    subtype, result, exit_code = run_headless(argv, a.cwd, question, caps["timeout_secs"])
    status, reason, answer, errors = think_outcome(subtype, result)
    used = models_used(result)
    downgrade = is_downgrade(used, a.model)

    def _num(k, integer=False):
        v = (result or {}).get(k)
        return v if _finite_nonneg(v, integer) else None

    denials = (result or {}).get("permission_denials")
    rec = {"v": 1, "think_id": a.think_id, "kind": a.kind, "task_id": a.task_id,
           "repo_slug": a.repo_slug, "model": a.model, "effort": a.effort,
           "caps": caps, "attempt": attempt, "parent": parent,
           "status": status, "reason": reason, "answer": answer,
           "subtype": subtype, "is_error": bool((result or {}).get("is_error", subtype != "success")),
           "num_turns": _num("num_turns", True), "total_cost_usd": _num("total_cost_usd"),
           "duration_ms": _num("duration_ms", True), "models_used": used, "downgrade": downgrade,
           "model_attributable": model_attributable(subtype, downgrade, errors, a.model),
           "permission_denials": len(denials) if isinstance(denials, list) else 0,
           "errors": errors, "exit_code": exit_code,
           "session_id": (result or {}).get("session_id"), "started": started, "ts": now_iso()}
    try:
        write_json_atomic(d / f"{a.think_id}.answer.json", rec)
    except OSError:
        sys.stderr.write("[X] cannot write the answer file\n")
        return 3
    return 0
```

Add `import contextlib`, `import datetime`, and `import fcntl` at the top of the module. In `run_think`, wrap the launch-record write so the caller's lock is honoured: the handler below takes the lock around the limit checks and the `write_launch_record` call, so move that call out of `run_think` into the handler (pass the written `launch` dict into `run_think` instead of building it there; `run_think(rd, a, question, launch, add_dirs)` then starts at the argv). Parser:

```python
    rt = add("run-think", "--think-id", "--kind", "--model", "--effort", "--cwd", fenced=True)
    rt.add_argument("--task-id", default=None)
    rt.add_argument("--max-turns", type=int, required=True)
    rt.add_argument("--max-budget-usd", type=float, required=True)
    rt.add_argument("--timeout-secs", type=int, required=True)
    rt.add_argument("--add-dir", action="append", default=[])
    rt.add_argument("--parent", default=None)
```

Handler (spec 4.7 steps 1-2, then `run_think`):

```python
    if ns.cmd == "run-think":
        rd = _fenced(ns)                      # stale/foreign fence refused like write-task
        _require(valid_think_id(ns.think_id), "invalid think-id")
        _require(ns.kind in THINK_KINDS and think_kind(ns.think_id) == ns.kind, "kind must match the think-id")
        _require(ns.task_id is None or valid_task_id(ns.task_id), "invalid task-id")
        _require(ns.model in ROLE_ALIASES["think"], "model must be fable or opus")
        _require(ns.effort in THINK_EFFORTS, "effort must be high, xhigh, or max")
        for name in ("repo_slug", "think_id", "kind", "model", "effort", "cwd"):
            _require(SHELL_SAFE_RE.match(str(getattr(ns, name))),
                     f"--{name.replace('_', '-')} contains whitespace or a shell metacharacter")
        for k in ("max_turns", "max_budget_usd", "timeout_secs"):
            err = _cap_error(k, getattr(ns, k))
            _require(err is None, err or "")
        qf = think_dir(rd) / f"{ns.think_id}.question.md"
        _require(qf.is_file() and not qf.is_symlink(), "question file missing or not a regular file")
        try:
            question = qf.read_text()
        except (OSError, UnicodeDecodeError):
            question = None
        _require(question is not None, "question file is not readable as text")
        is_retry = ns.think_id.endswith("-2")
        _require(is_retry == (ns.parent is not None), "a -2 id requires --parent and vice versa")
        cwd = Path(ns.cwd)
        _require(cwd.is_dir() and _git(str(cwd), "rev-parse", "--git-dir") is not None, "cwd must be a git checkout")
        remote = _git(str(cwd), "remote", "get-url", "origin")
        common = _git(str(cwd), "rev-parse", "--git-common-dir")
        common_abs = str((cwd / common).resolve()) if common else None
        _require(common_abs is not None and repo_slug(remote or "", common_abs) == ns.repo_slug,
                 "cwd does not belong to --repo-slug")
        add_dirs = []
        for tok in ns.add_dir:
            _require(tok in THINK_ADD_DIRS, "add-dir must be tasks or think")
            p = rd / tok
            _require(p.is_dir() and contained(p, state_root()), f"{tok} directory missing")
            add_dirs.append(str(p))
        ld, ad = think_dir(rd) / f"{ns.think_id}.launch.json", think_dir(rd) / f"{ns.think_id}.answer.json"
        _require(not ld.exists() and not ad.exists(), "launch or answer record already exists")
        caps = {"max_turns": ns.max_turns, "max_budget_usd": ns.max_budget_usd, "timeout_secs": ns.timeout_secs}
        attempt, budget = 1, ns.max_budget_usd
        if ns.parent is not None:
            _require(valid_think_id(ns.parent) and ns.think_id == ns.parent + "-2", "think-id must be the parent's -2 form")
            prec = _load_v1(think_dir(rd) / f"{ns.parent}.answer.json")
            _require(prec is not None and prec.get("model_attributable") is True, "parent must be a model-attributable failure")
            _require(prec.get("kind") == ns.kind and prec.get("task_id") == ns.task_id, "parent kind/task must match")
            _require(prec.get("model") != ns.model, "retry must run on a different model than the parent")
            try:
                same_q = (think_dir(rd) / f"{ns.parent}.question.md").read_bytes() == qf.read_bytes()
            except OSError:
                same_q = False
            _require(same_q, "retry question must be byte-identical to the parent's")
            spent = prec.get("total_cost_usd")
            if spent is None or not _finite_nonneg(spent):
                sys.stderr.write("[X] parent cost unknown; retry remainder undefined\n")
                return 4
            budget = round(ns.max_budget_usd - spent, 4)
            attempt = 2
            if budget < THINK_RETRY_FLOOR_USD:
                sys.stderr.write(f"[X] retry budget {budget} below the {THINK_RETRY_FLOOR_USD} floor\n")
                return 4
        cfg_caps, err = think_caps(read_config(rd))
        _require(err is None, err or "")
        with think_lock(rd):
            _require(check_fence(rd, ns.session, ns.fence), "stale fence")
            now = now_iso()
            scan = think_scan(rd, now)
            live = [t for t in scan["live"] if t != ns.think_id]
            if live:
                sys.stderr.write(f"[X] escalation already live: {live[0]}\n")
                return 4
            spent_today = think_usd_today(scan, now[:10])
            if spent_today + budget > cfg_caps["daily_budget_usd"]:
                sys.stderr.write(f"[X] daily think budget: spent {spent_today} + {budget} > {cfg_caps['daily_budget_usd']}\n")
                return 4
            launch = {"v": 1, "think_id": ns.think_id, "kind": ns.kind, "task_id": ns.task_id,
                      "repo_slug": ns.repo_slug, "model": ns.model, "effort": ns.effort,
                      "caps": dict(caps, max_budget_usd=budget), "attempt": attempt,
                      "parent": ns.parent, "started": now, "pid": os.getpid()}
            if not write_launch_record(think_dir(rd) / f"{ns.think_id}.launch.json", launch):
                sys.stderr.write("[X] launch record exists or is unwritable\n")
                return 2
        return run_think(rd, ns, question, launch, add_dirs)
```

`_git` returns stripped stdout; `--git-common-dir` may be relative (`.git`), hence the `cwd / common` resolve. The `--add-dir` check refuses `owner`, absolute paths, and any token outside the pair (the required-arg `_require` exits 2 before anything is written).

- [ ] **Step 4: Run both suites** -- `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add run-think bounded read-only escalation verb"
```

---

### Task 9: `status` `_think` fold, legacy effort, watch dirs

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (`WATCH_DIRS`; `status` handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Consumes: `think_scan`, `think_usd_today`.
- Produces: `status` output gains `_think` (spec 4.9 shape) and per-task `workers_effort: [<level>|"unknown", ...]` (one entry per `workers[]` item, `null` effort reported as `"inherit"`, missing key as `"unknown"`); `WATCH_DIRS["think"] = ((".launch.json", valid_think_id), (".answer.json", valid_think_id))`.

- [ ] **Step 1: Write the failing tests**

```sh
check "status: _think fold, legacy workers effort unknown, watch includes think files" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-st --session S --host h --pid 1)
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-st"; mkdir -p "$RD/think"
TODAY=$(date -u +%Y-%m-%d)
L() { printf '{"v":1,"think_id":"%s","kind":"%s","task_id":null,"repo_slug":"slug-st","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":%s},"attempt":1,"parent":null,"started":"%s","pid":1}' "$1" "$2" "$3" "$4" > "$RD/think/$1.launch.json"; }
A() { printf '{"v":1,"think_id":"%s","status":"%s","total_cost_usd":%s,"num_turns":%s,"started":"%s"}' "$1" "$2" "$3" "$4" "$5" > "$RD/think/$1.answer.json"; }
L think-triage-20260904100000 triage 900 "${TODAY}T10:00:00Z"; A think-triage-20260904100000 answered 1.12 6 "${TODAY}T10:00:00Z"
L think-other-20260904110000 other 900 "${TODAY}T11:00:00Z";  A think-other-20260904110000 answered 0.40 3 "${TODAY}T11:00:00Z"
L think-incident-20260904120000 incident 900 "${TODAY}T12:00:00Z"; A think-incident-20260904120000 unanswered null null "${TODAY}T12:00:00Z"
L think-decompose-20260904125900 decompose 900 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
L think-incident-20260903120000 incident 600 "2026-09-03T12:00:00Z"
printf '{"v":1,"trunc' > "$RD/think/think-other-20260904130000.answer.json"
printf '{"v":2,"think_id":"think-other-20260904140000"}' > "$RD/think/think-other-20260904140000.answer.json"
$CLI write-task --repo-slug slug-st --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"in-progress","workers":[{"role":"impl","phase":"plan","model":"fable"},{"role":"impl","phase":"implement","model":"sonnet","effort":null},{"role":"review","model":"opus","effort":"high"}]}'
$CLI status --repo-slug slug-st | python3 -c "
import json,sys;s=json.load(sys.stdin);t=s['_think']
assert t=={'launches':5,'answered':2,'unanswered':1,'usd':1.52,'turns':9,'usd_today':1.52,'live':['think-decompose-20260904125900'],'lost':['think-incident-20260903120000'],'skipped_files':2},t
assert s['PROJ-1']['workers_effort']==['unknown','inherit','high'],s['PROJ-1']"
rm -r "$RD/think"
$CLI status --repo-slug slug-st | python3 -c "import json,sys;t=json.load(sys.stdin)['_think'];assert t=={'launches':0,'answered':0,'unanswered':0,'usd':0.0,'turns':0,'usd_today':0.0,'live':[],'lost':[],'skipped_files':0},t"
python3 - "$RD" <<'PY'
import importlib.util,sys,os,json
s=importlib.util.spec_from_file_location("c","claude/hooks/herdr_orch_core.py");c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
rd=sys.argv[1]; os.makedirs(os.path.join(rd,"think"),exist_ok=True)
assert "think" in c.WATCH_DIRS
snap0=c.watch_scan(rd,{})
open(os.path.join(rd,"think","think-triage-20260904150000.question.md"),"w").write("q")
assert not c.watch_changed(snap0, c.watch_scan(rd,snap0))
open(os.path.join(rd,"think","think-triage-20260904150000.launch.json"),"w").write("{}")
snap1=c.watch_scan(rd,snap0); assert c.watch_changed(snap0,snap1)
open(os.path.join(rd,"think","think-triage-20260904150000.answer.json"),"w").write("{}")
assert c.watch_changed(snap1, c.watch_scan(rd,snap1))
PY
SH
```

- [ ] **Step 2: Run to verify it fails** -- FAIL (no `_think` key).

- [ ] **Step 3: Implement**

`WATCH_DIRS` gains `"think": ((".launch.json", valid_think_id), (".answer.json", valid_think_id)),`. In the `status` handler, inside the per-task loop after `workers` is read:

```python
            effort_list = []
            if isinstance(workers, list):
                for w in workers:
                    if not isinstance(w, dict) or "effort" not in w:
                        effort_list.append("unknown")
                    else:
                        effort_list.append(w["effort"] if w["effort"] is not None else "inherit")
            result[tid] = {..., "workers_effort": effort_list}
```

and before `print(json.dumps(result))`:

```python
        now = now_iso()
        scan = think_scan(rd, now)
        answers = list(scan["answers"].values())
        result["_think"] = {
            "launches": len(scan["launches"]),
            "answered": sum(1 for a in answers if a.get("status") == "answered"),
            "unanswered": sum(1 for a in answers if a.get("status") == "unanswered"),
            "usd": round(sum(a["total_cost_usd"] for a in answers
                             if _finite_nonneg(a.get("total_cost_usd")) and a.get("total_cost_usd") is not None), 4),
            "turns": sum(a["num_turns"] for a in answers
                         if _finite_nonneg(a.get("num_turns"), True) and a.get("num_turns") is not None),
            "usd_today": think_usd_today(scan, now[:10]),
            "live": scan["live"], "lost": scan["lost"], "skipped_files": scan["skipped_files"],
        }
```

- [ ] **Step 4: Run both suites** -- `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Fold think launches into status and watch"
```

---

### Task 10: Skill and reference docs, with drift checks

**Files:**
- Modify: `claude/skills/herdr-orchestration/SKILL.md` (sections 1, 2, 2a, 3, 4, 5, 7, 8, 9)
- Modify: `claude/skills/herdr-orchestration/references/state-layout.md`, `brief-template.md`, `event-schema.md`
- Test: `claude/hooks/herdr-orch.test.sh` (new docs drift check, modelled on the mech one)

**Interfaces:**
- Produces: the exact strings the drift check below pins. Write the docs so every `grep` in Step 1 matches.

- [ ] **Step 1: Write the failing drift check**

```sh
check "docs pin effort routing, banner verb, deep think, and Workflow routing" <<'SH'
S="claude/skills/herdr-orchestration/SKILL.md"; R="claude/skills/herdr-orchestration/references"
grep -q 'routing-table --repo-slug' "$S"                     # one snapshot per dispatch
grep -q 'One snapshot per dispatch' "$S"
grep -q -- '--effort \$EFFORT' "$S"                          # launch line
grep -q 'classify-banner --model' "$S"
grep -q 'effort-mismatch' "$S"
grep -q 'not availability data' "$S"                         # never disable-model on effort-mismatch
grep -q 'Deep-think escalation' "$S"
grep -q 'run-think --repo-slug' "$S"
grep -q 'think-caps --repo-slug' "$S"
for t in 'Ambiguous triage' 'Milestone/epic decomposition' 'Novel incident' 'Not eligible'; do grep -q "$t" "$S"; done
grep -q 'one live escalation per repo' "$S"
grep -q 'daily_budget_usd' "$S"
grep -q 'escalation deferred' "$S"
grep -q '_think' "$S"
grep -q 'Workflow' "$S" && grep -q 'in-turn helper work' "$S"
grep -q 'Precedence with the user' "$S"
grep -q 'Workflow opt-in: granted by the user' "$R/brief-template.md"
grep -q 'Workflow opt-in: withheld for this task' "$R/brief-template.md"
grep -q '## Routing' "$R/brief-template.md"
grep -q 'never call `herdr_orch_core.py`' "$R/brief-template.md"
grep -q 'Deep-think brief variant' "$R/brief-template.md"
grep -q '"effort": {' "$R/state-layout.md"
grep -q '"think": {' "$R/state-layout.md"
grep -q '\.launch\.json' "$R/state-layout.md"
grep -q '\.answer\.json' "$R/state-layout.md"
grep -q 'workers\[\].effort\|"effort": "high"' "$R/state-layout.md"
grep -q 'think/' "$R/event-schema.md"
grep -q 'models.think\|"think": \["fable", "opus"\]' "$R/state-layout.md"
SH
```

- [ ] **Step 2: Run to verify it fails** -- FAIL (none of the strings exist yet).

- [ ] **Step 3: Write the docs** (content requirements; copy phrasing from the spec sections named)

SKILL.md:
- Section 1 step 5: after the probe, note that launches read the map through `routing-table` (spec 1).
- Section 2 step 6, 2a step 3, 5 step 3: replace "resolve-model --role X" wording with the single-snapshot recipe from spec 2 (the `ROUTING=...` block, verbatim), and say the `workers[]` entry records `effort` from it (spec 2, including the legacy paragraph).
- Section 3: add "Escalation" paragraph: the triage trigger conditions (spec 4.1 `Ambiguous triage`), the `escalation deferred` rule, and that the answer only reorders/annotates the advisory list (spec 4.8).
- Section 4: the report line gains `_think` (live/lost/usd_today) and the `escalation <think_id> ... adopted|adapted|rejected` line (spec 4.8, 4.9); `think lost` is polling-only.
- Section 7: add the rule-of-thumb line "subagents for helpers, Workflow for in-turn fan-out, self-managed panes for your own processes, agent panels for the orchestrator only", pointing to section 8's Workflow subsection.
- Section 8: routing table gains an `Effort` column with the exact defaults and a `Deep-think (think)` row (`fable -> opus`, `high`); "Model launch" step 2 becomes the spec 2 recipe; "Verify-after-launch" replaces the prose classification with `classify-banner --model $MODEL --effort $EFFORT --text-file <capture>` and the four-way table plus the `effort-mismatch` action and lifecycle paragraph from spec 3 (keep the sentence "`effort-mismatch` is **not availability data**"). Add subsection "**Deep-think escalation**" = spec 4.1 (triggers with the four headings `Ambiguous triage`, `Milestone/epic decomposition`, `Novel incident`, `Not eligible`), 4.2, 4.3 (`think-caps --repo-slug <slug> [--max-turns N] [--max-budget-usd X]`), 4.4-4.9 condensed, with the launch line
  `python3 "$CORE" run-think --repo-slug <slug> --think-id <think_id> --kind <kind> [--task-id <task_id>] --model $MODEL --effort $EFFORT --cwd <repo_worktree> --max-turns <N> --max-budget-usd <X> --timeout-secs <T> [--add-dir tasks] [--add-dir think]`
  and the phrases "one live escalation per repo", "daily_budget_usd", "escalation deferred". Add subsection "**Workflow-tool routing**" = spec 5.1 table, 5.2 rules, 5.3 opt-in (with the exact brief line), 5.4, including the heading text "Precedence with the user's standing order" and the phrase "in-turn helper work".
- Section 9: add one sentence under the table: an `effort-mismatch` refusal publishes nothing and so adds no row.

state-layout.md: `config.json` example gains `"effort": {"plan": "high", "impl": null, "review": "high", "think": "high"}`, `"think": {"max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900, "daily_budget_usd": 10.0}`, and `"think": ["fable", "opus"]` under `models`; validation paragraphs from spec 1 and 4.3; the layout tree gains `think/<think_id>.question.md|.launch.json|.answer.json`; the `workers[]` example gains `"effort": "high"` on the first entry and `"effort": null` on the mech entry, with the legacy paragraph; new subsections for `think/<think_id>.launch.json` and `.answer.json` schemas (spec 4.4, 4.6) and the `_think` status object (spec 4.9).

brief-template.md: every variant's `## Workspace` block is followed by a `## Routing` block:

```
## Routing
Models and efforts were resolved by the orchestrator from one `routing-table`
snapshot at launch; use these aliases verbatim in any Workflow `agent()` call
(`effort` omitted where it says inherit); a role listed as unavailable may not
appear in a script you author:
- plan: <model> / <effort|inherit>
- impl: <model> / <effort|inherit>
- review: <model> / <effort|inherit>
- mech: <model> / <effort|inherit>
- think: <model|unavailable> / <effort>
Workflow opt-in: granted by the user's standing order (global CLAUDE.md, Default Skill Routing) for this orchestrated task; default size guideline
```

with the alternative last line `Workflow opt-in: withheld for this task` for a `no-workflow` kickoff, and the ground rule "Workflow/subagent helpers never call `herdr_orch_core.py`; only you emit the completion record." Add the "Deep-think brief variant" (spec 4.5, the five sections, written to `STATE_ROOT/<slug>/think/<think_id>.question.md`).

event-schema.md: add a paragraph that `think/*.launch.json` and `think/*.answer.json` are watched like the sidecars (a write wakes the orchestrator), are records not events, and are folded only by `status`.

- [ ] **Step 4: Run both suites** -- `0 failed`; also run the ASCII check `LC_ALL=C grep -n '[^ -~]' claude/skills/herdr-orchestration/SKILL.md claude/skills/herdr-orchestration/references/*.md | grep -v '^\S*:[0-9]*:.*--' | head` and fix any non-ASCII you introduced (the files already contain `--` dashes only).

- [ ] **Step 5: Commit**

```bash
git add claude/skills/herdr-orchestration claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Document effort routing, deep-think escalation, and Workflow routing"
```

---

### Task 11: Walkthrough suite (AC11)

**Files:**
- Modify: `claude/hooks/herdr-orch-contract.test.sh` (append a section 11 before the final summary)

**Interfaces:**
- Consumes: every verb above through `$CLI`; the fake `herdr` and fake `claude` already defined in the suite.

- [ ] **Step 1: Write the walkthrough** (append before `printf '\n%d passed, %d failed\n'`)

```sh
# 11. effort routing + deep-think: one routing-table snapshot per dispatch, effort on the
# launch line and in workers[], effort-mismatch publishes nothing and touches no
# capability, think escalation lands launch+answer and refuses a concurrent second.
ESLUG="github-com-org-effort-0badf00d"
EF=$($CLI claim-owner --repo-slug "$ESLUG" --session E --host h --pid 3)
ERD="$ROOT/herdr-orch/$ESLUG"; mkdir -p "$ERD/tasks" "$ERD/think"
printf '{"v":1,"user":"talon","default_base":"origin/main"}' > "$ERD/config.json"
$CLI write-capabilities --repo-slug "$ESLUG" --session E --fence "$EF" \
  --json '{"v":1,"session_id":"E","available":{"fable":true,"opus":true,"sonnet":true,"haiku":true}}'
ROUTING=$($CLI routing-table --repo-slug "$ESLUG" --session E)
PM=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["plan"]["model"])')
PE=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["plan"]["effort"] or "inherit")')
IM=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["impl"]["model"])')
IE=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["impl"]["effort"] or "inherit")')
ok "routing snapshot: plan fable/high, impl sonnet/inherit" "[ '$PM/$PE' = fable/high ] && [ '$IM/$IE' = sonnet/inherit ]"
: > "$BIN/calls.log"
PID=$(herdr worktree create --cwd "$PWD" --branch talon/PROJ-E/x --base origin/main --label PROJ-E | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])")
herdr pane run "$PID" "claude --model $PM --effort $PE --permission-mode auto --name plan-proj-e"
ok "plan launch line carries --effort high" "grep -q '^pane run w1:p1 claude --model fable --effort high --permission-mode auto --name plan-proj-e$' '$BIN/calls.log'"
BANNER=$(mktemp); printf 'Claude Code v2.1.260\n  Fable 5.1 with high effort \302\267 Claude Max\n' > "$BANNER"
ok "banner classifies ok for the requested pin" "[ \"\$($CLI classify-banner --repo-slug '$ESLUG' --model $PM --effort $PE --text-file '$BANNER')\" = ok ]"
$CLI write-task --repo-slug "$ESLUG" --task-id PROJ-E --session E --fence "$EF" \
  --json "{\"task_id\":\"PROJ-E\",\"base_sha\":\"b0\",\"status\":\"in-progress\",\"workers\":[{\"role\":\"impl\",\"phase\":\"plan\",\"workspace_id\":\"w1\",\"agent\":\"plan-proj-e\",\"model\":\"$PM\",\"effort\":\"$PE\",\"created_by_this_orch\":true,\"started\":\"t\"}]}"
ok "workers[] records the pinned effort" "python3 -c \"import json;t=json.load(open('$ERD/tasks/PROJ-E.json'));assert t['workers'][0]['effort']=='high',t\""
# effort-mismatch on an impl launch: nothing published, capabilities untouched, no disable-model, no workspace close
printf 'Claude Code v2.1.260\n  Sonnet 5 \302\267 Claude Max\n' > "$BANNER"
CLS=$($CLI classify-banner --repo-slug "$ESLUG" --model sonnet --effort high --text-file "$BANNER")
ok "impl pinned high but banner shows none -> effort-mismatch" "[ '$CLS' = effort-mismatch ]"
CAP_BEFORE=$(cat "$ERD/capabilities.json"); : > "$BIN/calls.log"
herdr pane run "$PID" "claude --model sonnet --effort high --permission-mode auto --name impl-proj-e"
# the skill terminates the worker and publishes nothing; simulate exactly that and assert the invariants
herdr agent prompt "$PID" "/exit"
ok "effort-mismatch: capabilities unchanged, no disable-model, no workspace close, record unchanged" \
  "[ \"\$(cat '$ERD/capabilities.json')\" = \"\$CAP_BEFORE\" ] && ! grep -q disable-model '$BIN/calls.log' && ! grep -q 'workspace close' '$BIN/calls.log' && python3 -c \"import json;t=json.load(open('$ERD/tasks/PROJ-E.json'));assert len(t['workers'])==1 and t['status']=='in-progress',t\""
printf 'Claude Code v2.1.260\n  Sonnet 5 with high effort \302\267 Claude Max\n' > "$BANNER"
ok "downgrade still flips the requested alias" \
  "[ \"\$($CLI classify-banner --repo-slug '$ESLUG' --model fable --effort high --text-file '$BANNER')\" = downgrade ] && $CLI disable-model --repo-slug '$ESLUG' --session E --fence '$EF' --model fable && [ \"\$($CLI resolve-model --repo-slug '$ESLUG' --role plan --session E)\" = opus ]"
# think escalation (triage): question at the canonical path, run-think with --add-dir tasks, launch+answer, status _think, concurrent refusal, then an explicit other
TWT=$(mktemp -d); git -C "$TWT" init -q; git -C "$TWT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$TWT" remote add origin https://github.com/org/effort.git
TSLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/effort.git'))")
TRD="$ROOT/herdr-orch/$TSLUG"; mkdir -p "$TRD/tasks" "$TRD/think"
TF=$($CLI claim-owner --repo-slug "$TSLUG" --session E --host h --pid 4)
TID=think-triage-20260904170000
printf 'You are %s ...\n## Question\nWhich of the three todos first?\n' "$TID" > "$TRD/think/$TID.question.md"
export FAKE_CLAUDE_LOG="$FAKE/tlog" FAKE_CLAUDE_JSON="$FAKE/tres.json"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5,"total_cost_usd":1.1,"modelUsage":{"claude-fable-5-1":{}},"structured_output":{"recommendation":"todo B first","rationale":"unblocks A and C","options":[{"label":"B first","summary":"s","tradeoffs":"t","risk":"low"},{"label":"A first","summary":"s","tradeoffs":"t","risk":"medium"}],"confidence":"high"}}' > "$FAKE_CLAUDE_JSON"
TCMD="python3 claude/hooks/herdr_orch_core.py run-think --repo-slug $TSLUG --session E --fence $TF --think-id $TID --kind triage --model fable --effort high --cwd $TWT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 900 --add-dir tasks"
ok "every think launch value is shell-safe" "python3 -c \"import re,sys;sys.exit(0 if all(re.fullmatch(r'[A-Za-z0-9_./+:@-]+',w) for w in '$TCMD'.split()) else 1)\""
$TCMD
ok "think launch record then answer landed, answered" \
  "python3 -c \"import json;l=json.load(open('$TRD/think/$TID.launch.json'));a=json.load(open('$TRD/think/$TID.answer.json'));assert l['kind']=='triage' and a['status']=='answered' and a['answer']['recommendation']=='todo B first',(l,a)\""
ok "the advisor saw the question on stdin, the repo as cwd, and --add-dir tasks" \
  "grep -q 'Which of the three todos first' '$FAKE_CLAUDE_LOG.stdin' && grep -qx -- '$TRD/tasks' '$FAKE_CLAUDE_LOG.argv' && grep -qx -- '--restricted' '$FAKE_CLAUDE_LOG.argv'"
ok "status reports _think" "$CLI status --repo-slug '$TSLUG' | python3 -c \"import json,sys;t=json.load(sys.stdin)['_think'];assert t['launches']==1 and t['answered']==1 and t['usd']==1.1,t\""
TID2=think-other-20260904170100; printf 'q\n' > "$TRD/think/$TID2.question.md"
rm "$TRD/think/$TID.answer.json"          # first escalation looks live again
ok "a second run-think while one is live exits 4 and writes nothing" \
  "rc=0; $CLI run-think --repo-slug $TSLUG --session E --fence $TF --think-id $TID2 --kind other --model fable --effort high --cwd $TWT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 900 >/dev/null 2>&1 || rc=\$?; [ \"\$rc\" = 4 ] && [ ! -e '$TRD/think/$TID2.launch.json' ]"
python3 -c "import json;p='$TRD/think/$TID.launch.json';d=json.load(open(p));d['started']='2020-01-01T00:00:00Z';json.dump(d,open(p,'w'))"
$CLI run-think --repo-slug $TSLUG --session E --fence $TF --think-id $TID2 --kind other --model fable --effort high --cwd $TWT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 900
ok "explicit other-kind escalation succeeds once the first is no longer live" "[ -e '$TRD/think/$TID2.answer.json' ]"
# brief rendering: Routing block equals the snapshot; opt-in line; helper rule; no-workflow variant
render_brief() {   # $1 = ROUTING json, $2 = granted|withheld
  printf '%s' "$1" | python3 -c '
import json,sys
t=json.load(sys.stdin); mode=sys.argv[1]
print("## Routing")
for r in ("plan","impl","review","mech","think"):
    m=t[r]["model"] or "unavailable"; e=t[r]["effort"] or "inherit"
    print(f"- {r}: {m} / {e}")
print("Workflow opt-in: granted by the user'"'"'s standing order (global CLAUDE.md, Default Skill Routing) for this orchestrated task; default size guideline" if mode=="granted" else "Workflow opt-in: withheld for this task")
print("Workflow/subagent helpers never call `herdr_orch_core.py`; only you emit the completion record.")' "$2"
}
B1=$(render_brief "$ROUTING" granted); B2=$(render_brief "$ROUTING" withheld)
ok "brief Routing block matches the snapshot and carries the grant + helper rule" \
  "printf '%s' \"\$B1\" | grep -q '^- plan: fable / high$' && printf '%s' \"\$B1\" | grep -q '^- impl: sonnet / inherit$' && printf '%s' \"\$B1\" | grep -q '^Workflow opt-in: granted by the user' && printf '%s' \"\$B1\" | grep -q 'never call \`herdr_orch_core.py\`'"
ok "no-workflow kickoff renders the withheld line" "printf '%s' \"\$B2\" | grep -q '^Workflow opt-in: withheld for this task$'"
ok "skill documents the brief Routing block and both opt-in lines" \
  "grep -q '## Routing' claude/skills/herdr-orchestration/references/brief-template.md && grep -q 'withheld for this task' claude/skills/herdr-orchestration/references/brief-template.md"
```

- [ ] **Step 2: Run the walkthrough** -- `sh claude/hooks/herdr-orch-contract.test.sh 2>&1 | tail -20`; every new `ok` line PASS, `0 failed`. (The fake herdr's `agent prompt` returns canned JSON; the assertion is on the calls log and state, not on a real termination.)

- [ ] **Step 3: Commit**

```bash
git add claude/hooks/herdr-orch-contract.test.sh
git commit -m "herdr: Add effort routing and deep-think walkthrough to the contract suite"
```

---

### Task 12: Live checks (AC12) and close

- [ ] **Step 1: Banner without `--effort` (AC12a).** In a scratch pane of YOUR OWN workspace (`herdr pane split "$HERDR_PANE_ID" --direction down`), run `claude --model sonnet --permission-mode auto --name effort-probe`, wait ~7 s, `herdr pane read <pane> --source recent-unwrapped --lines 40 > /tmp/banner.txt`, then `python3 claude/hooks/herdr_orch_core.py classify-banner --repo-slug x --model sonnet --effort inherit --text-file /tmp/banner.txt` must print `ok` and `--effort high` must print `effort-mismatch`. Close the pane (`herdr pane close <pane>`). Record the banner's model line in the commit body of Step 3.

- [ ] **Step 2: Real `run-think` (AC12b).** With `CLAUDE_CONFIG_DIR` at the real config dir and this repo's real slug (`python3 -c` over `repo_slug(git remote get-url origin)`), write `STATE_ROOT/<slug>/think/think-other-<YYYYMMDDHHMMSS>.question.md` whose Question asks the advisor to: (1) create a file named `think-probe.txt` in the repo, (2) run `git status` via a shell, (3) fetch `https://example.com`, (4) read `/etc/hosts`, (5) list the tools it has -- and to report in `recommendation` which of 1-4 it could do and in `evidence` its tool names. Launch `run-think --repo-slug <slug> --session <your session id> --fence <fence from claim-owner> ... --kind other --model fable --effort high --max-turns 8 --max-budget-usd 1.0 --timeout-secs 600 --cwd <this worktree>` (claim ownership of the slug first with `claim-owner`; release nothing afterwards -- the heartbeat simply goes stale) (use `opus` if `resolve-model --role think` says so). Expected: `status: answered`, the answer says all four were impossible, `evidence` names only Read/Glob/Grep, `permission_denials >= 1`, and `git status --porcelain` in the worktree stays empty. If the CLI refuses `--restricted` together with any flag, record the exact error and mark AC12b blocked in the close; do not weaken the argv.

- [ ] **Step 3: Record and close**

```bash
git commit --allow-empty -m "herdr: Record effort routing live checks" \
  -m "AC12a: <banner model line, classification>. AC12b: <answered|blocked: reason>, denials=<n>, cost=<usd>."
python3 claude/hooks/herdr_orch_core.py verify-contract --repo-slug <slug> --task-id td-2026-09-04-add-effort-routing-and-a-deep-think-escalation-pat --worktree "$PWD"
```

Then follow the implement brief's close (emit-done with `--phase implement`) -- `--outcome completed` only on verify-contract exit 0.

---

## Self-review

- **Spec coverage:** spec 1 -> Tasks 1-2; spec 2 -> Tasks 2, 5, 9 (legacy), 10; spec 3 -> Task 3 (+10 prose, 11 lifecycle); spec 4.1-4.9 -> Tasks 4, 6, 8, 9, 10, 11; spec 5 -> Tasks 10, 11 (brief rendering); spec 6 -> no code (spec text only); AC12 -> Task 12.
- **Placeholders:** none; every step carries code or exact strings. The docs task lists content requirements plus the exact pinned strings rather than full prose, which is the pattern the mech plan used.
- **Type consistency:** `role_effort` returns `(level_or_None, code)`; `routing_table` returns `(dict, code)`; `think_scan` keys `launches/answers/live/lost/skipped_files`; `run_think(rd, a, question, launch, add_dirs)` matches the handler call (the handler builds and writes `launch` under `think_lock`); `think_outcome` returns a 4-tuple consumed only inside `run_think`.
