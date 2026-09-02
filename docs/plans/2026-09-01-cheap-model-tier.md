# Cheap-Model Mech Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a human-designated `mech` worker role that runs haiku-first, headless, under turn/dollar/wall-clock caps, with per-task spend recorded in a ledger and surfaced by `status`.

**Architecture:** All logic lands in the tested core CLI (`claude/hooks/herdr_orch_core.py`): a `mech` resolver role, a `mech-caps` config verb, a `mech-contract` generator, a `run-mech` wrapper that launches `claude -p` and writes the spend ledger plus a guaranteed completion record, and a `status` spend fold. The skill prose (SKILL.md, references) becomes a thin caller of those verbs. Tests are `check` snippets in the two existing sh suites; no new test runner.

**Tech Stack:** Python 3 stdlib only (argparse, subprocess, json, re, math); POSIX sh test suites; fake `claude`/`herdr` executables on PATH in tests.

**Spec:** `docs/specs/2026-09-01-cheap-model-tier.md` (branch-only). Read it first; every task cites its section.

## Global Constraints

- Stdlib-only Python; no network in tests; nothing under `STATE_ROOT` is ever git-tracked.
- `CAP_MODELS = ("fable", "opus", "sonnet", "haiku")`; `haiku` is legal only in the `mech` role (spec s1).
- Cap bounds: `max_turns` int 1-500; `max_budget_usd` finite number > 0 and <= 50; `timeout_secs` int 60-14400; defaults 40 / 2.0 / 1800 (spec s3).
- Shell-safety regex for every `run-mech` argument value: `[A-Za-z0-9_./+:@-]+` (spec s4).
- `run-mech` exit codes: 0 all writes ok; 2 validation failure (nothing written); 3 a write after the start line failed (spec s4).
- Reason tokens: `max_turns|max_budget|timeout|no_emit|error|needs_design|blocked_on_human|other` (spec s4).
- No emojis, no AI attribution, ASCII only, commit format `<scope>: <summary>`.
- Run the test suites from the worktree root: `sh claude/hooks/herdr-orch.test.sh` and `sh claude/hooks/herdr-orch-contract.test.sh`. Record the baseline PASS counts on origin/main @ 8a377cc in the first commit message body before changing anything.

## File map

| File | Responsibility in this change |
| --- | --- |
| `claude/hooks/herdr_orch_core.py` | `haiku` alias + per-role alias sets; `mech_caps`, `mech_contract`; `emit-done --launch-id/--reason`; spend ledger validate/fold; `status` spend/totals/orphans; `run_mech` + CLI verb; `WATCH_DIRS` |
| `claude/hooks/herdr-orch.test.sh` | unit checks for every core function and verb above (AC1-AC8, AC10) |
| `claude/hooks/herdr-orch-contract.test.sh` | mech kickoff walkthrough with fake herdr + fake claude (AC9) |
| `claude/skills/herdr-orchestration/SKILL.md` | sections 1 (probe writes haiku), 2 (mech designation, contract source, launch base), 4 (mech liveness/correlation/relaunch, spend in report), 8 (mech row, run-mech launch), 9 (rows) |
| `claude/skills/herdr-orchestration/references/state-layout.md` | `config.mech`, four-alias capabilities, `workers[].launch_id/caps`, `done.json` optional fields, spend ledger schema, `_totals/_orphans` |
| `claude/skills/herdr-orchestration/references/brief-template.md` | mech brief variant |
| `claude/skills/herdr-orchestration/references/event-schema.md` | note that the ledger is watched and is not an event |
| `claude/contracts/td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical-contract.json` | this task's verification contract (committed with this plan) |

---

### Task 1: `haiku` alias, `mech` role, per-role alias sets

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py:27-60` (CAP_MODELS, ROLE_DEFAULTS, valid_capabilities) and `:140-170` (role_preference)
- Test: `claude/hooks/herdr-orch.test.sh` (append after the "resolve-model CLI" check, about line 520)

**Interfaces:**
- Produces: `CAP_MODELS` (4-tuple), `ROLE_DEFAULTS["mech"] == ("haiku", "sonnet")`, `ROLE_ALIASES: dict[role -> tuple]`; unchanged signatures `role_preference(role, config)`, `resolve_model(role, available, config)`, `valid_capabilities(rec, session_id)`.

- [ ] **Step 1: Write the failing tests** (append to `herdr-orch.test.sh` before the final summary block)

```sh
check "mech role: haiku-first defaults, haiku only legal in mech, 4-alias capabilities" <<PY
$LOAD
assert c.CAP_MODELS==("fable","opus","sonnet","haiku")
assert c.role_preference("mech",{})==("haiku","sonnet")
assert c.role_preference("mech",{"models":{"mech":["sonnet","haiku"]}})==("sonnet","haiku")
for r in ("plan","impl","review"):
    assert c.role_preference(r,{"models":{r:["haiku"]}}) is None, r
assert c.role_preference("plan",{"models":{"mech":["haiku"]}})==("fable","opus")  # sibling override does not taint
ok3={"v":1,"session_id":"S","available":{"fable":True,"opus":True,"sonnet":True}}
assert not c.valid_capabilities(ok3,"S")                      # old 3-alias map is stale
ok4=dict(ok3,available=dict(ok3["available"],haiku=True))
assert c.valid_capabilities(ok4,"S")
assert c.resolve_model("mech",{"fable":False,"opus":True,"sonnet":True,"haiku":True},{})==("haiku",None)
assert c.resolve_model("mech",{"fable":False,"opus":True,"sonnet":True,"haiku":False},{})==("sonnet",None)
assert c.resolve_model("mech",{"fable":False,"opus":True,"sonnet":False,"haiku":False},{})==(None,4)
assert c.resolve_model("mech",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{"models":{"mech":["gpt"]}})==(None,5)
sys.exit(0)
PY

check "resolve-model/disable-model CLI accept the mech role and haiku alias" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-m --session S --host h --pid 1)
! $CLI write-capabilities --repo-slug slug-m --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true}}' 2>/dev/null
$CLI write-capabilities --repo-slug slug-m --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
[ "$($CLI resolve-model --repo-slug slug-m --role mech --session S)" = haiku ]
$CLI disable-model --repo-slug slug-m --session S --fence "$F" --model haiku
[ "$($CLI resolve-model --repo-slug slug-m --role mech --session S)" = sonnet ]
[ "$($CLI resolve-model --repo-slug slug-m --role plan --session S)" = opus ]   # other roles unaffected
SH
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep -E 'FAIL|mech'`
Expected: both new checks FAIL (CAP_MODELS is a 3-tuple; `mech` role unknown).

- [ ] **Step 3: Implement**

In `herdr_orch_core.py` replace the constants block:

```python
CAP_MODELS = ("fable", "opus", "sonnet", "haiku")

ROLE_DEFAULTS = {
    "plan": ("fable", "opus"),
    "impl": ("sonnet", "opus"),
    "review": ("opus", "sonnet"),
    "mech": ("haiku", "sonnet"),
}

# Aliases a role's config override may name. haiku is mech-only: the cheap
# tier is human-designated per task, never a silent option for design,
# implementation, or review.
ROLE_ALIASES = {
    "plan": ("fable", "opus", "sonnet"),
    "impl": ("fable", "opus", "sonnet"),
    "review": ("fable", "opus", "sonnet"),
    "mech": CAP_MODELS,
}
```

In `role_preference`, change the inner loop's membership test:

```python
            allowed = ROLE_ALIASES[role]
            for m in override:
                if m not in allowed:
                    return None
```

(`models.get(role)` returns None for an unknown role, so `ROLE_ALIASES[role]` is only reached for a known one; the final `ROLE_DEFAULTS.get(role)` still returns None for unknown roles.)

`valid_capabilities` needs no code change (it compares against `CAP_MODELS`). Update the `write-capabilities` `_require` message to `available:{fable,opus,sonnet,haiku all bool}` and the `disable-model`/`classify-probe` messages to `fable/opus/sonnet/haiku`.

- [ ] **Step 4: Run the whole unit suite**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -3`
Expected: 0 FAIL. If an existing check hard-codes the 3-alias map (grep `"sonnet":true}` in the test file), update that fixture to include `"haiku":true` -- that is the intended behavior change, not a regression.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add mech role and haiku alias to model resolution"
```

---

### Task 2: `mech-caps` and `mech-contract` verbs

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new functions after `resolve_model`; new CLI parsers + handlers in `main`)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `MECH_DEFAULTS`, `MECH_BOUNDS`, `MECH_KEYS`, `_cap_error(key, value) -> str|None`, `mech_caps(config, max_turns=None, max_budget_usd=None) -> (dict|None, str|None)`, `mech_contract(config, task_id) -> dict|None`; CLI `mech-caps --repo-slug S [--max-turns N] [--max-budget-usd X]` (prints JSON, exit 5 on error) and `mech-contract --repo-slug S --task-id T --worktree W` (writes `claude/contracts/<T>-contract.json`, prints the relative path; exit 5 when config has no `contract_commands` or is malformed; exit 2 when the file already exists or the worktree is invalid).

- [ ] **Step 1: Write the failing tests**

```sh
check "mech_caps: defaults, config merge, overrides, fail-closed validation" <<PY
$LOAD
caps,err=c.mech_caps({})
assert err is None and caps=={"max_turns":40,"max_budget_usd":2.0,"timeout_secs":1800},caps
caps,err=c.mech_caps({"mech":{"max_turns":60,"max_budget_usd":3}})
assert err is None and caps["max_turns"]==60 and caps["max_budget_usd"]==3 and caps["timeout_secs"]==1800
caps,err=c.mech_caps({"mech":{"max_turns":60}},max_turns=10,max_budget_usd=0.5)
assert err is None and caps["max_turns"]==10 and caps["max_budget_usd"]==0.5
bad=[{"mech":{"max_turns":0}},{"mech":{"max_turns":501}},{"mech":{"max_budget_usd":0}},
     {"mech":{"max_budget_usd":50.01}},{"mech":{"timeout_secs":59}},{"mech":{"max_turns":True}},
     {"mech":{"bogus":1}},{"mech":[]},{"mech":{"max_budget_usd":float("inf")}},
     {"mech":{"contract_commands":[]}},{"mech":{"contract_commands":[{"name":"a","run":"true","x":1}]}}]
for b in bad:
    caps,err=c.mech_caps(b); assert caps is None and err, b
caps,err=c.mech_caps({},max_turns=0); assert caps is None
caps,err=c.mech_caps({},max_budget_usd=51); assert caps is None
good={"mech":{"contract_commands":[{"name":"t","run":"true","timeout_secs":5}]}}
assert c.mech_caps(good)[1] is None
assert c.mech_contract(good,"td-x")=={"v":1,"task_id":"td-x","commands":[{"name":"t","run":"true","timeout_secs":5}]}
assert c.mech_contract({},"td-x") is None
sys.exit(0)
PY

check "mech-caps / mech-contract CLI" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-c"; mkdir -p "$RD"
out=$($CLI mech-caps --repo-slug slug-c)
[ "$out" = '{"max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}' ]
printf '{"v":1,"user":"u","default_base":"origin/main","mech":{"max_turns":60,"contract_commands":[{"name":"t","run":"true"}]}}' > "$RD/config.json"
out=$($CLI mech-caps --repo-slug slug-c --max-budget-usd 1.5)
[ "$out" = '{"max_turns": 60, "max_budget_usd": 1.5, "timeout_secs": 1800}' ]
rc=0; $CLI mech-caps --repo-slug slug-c --max-turns 999 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
WT=$(mktemp -d); git -C "$WT" init -q
rel=$($CLI mech-contract --repo-slug slug-c --task-id td-x --worktree "$WT")
[ "$rel" = claude/contracts/td-x-contract.json ]
python3 -c "import json;d=json.load(open('$WT/$rel'));assert d=={'v':1,'task_id':'td-x','commands':[{'name':'t','run':'true'}]},d"
rc=0; $CLI mech-contract --repo-slug slug-c --task-id td-x --worktree "$WT" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]   # exists
printf '{"v":1,"user":"u","default_base":"origin/main"}' > "$RD/config.json"
rc=0; $CLI mech-contract --repo-slug slug-c --task-id td-y --worktree "$WT" 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]   # no template
SH
```

- [ ] **Step 2: Run to verify they fail** -- `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep FAIL` shows both.

- [ ] **Step 3: Implement**

After `resolve_model`:

```python
MECH_DEFAULTS = {"max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}
MECH_BOUNDS = {"max_turns": (1, 500), "max_budget_usd": (0, 50), "timeout_secs": (60, 14400)}
MECH_KEYS = frozenset(MECH_DEFAULTS) | {"contract_commands"}


def _cap_error(key, value):
    """Error message when a cap value is out of bounds or mistyped, else None."""
    lo, hi = MECH_BOUNDS[key]
    if isinstance(value, bool):
        return f"{key} must be a number, not a boolean"
    if key == "max_budget_usd":
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            return f"{key} must be a finite number"
        if not (lo < value <= hi):
            return f"{key} must be > {lo} and <= {hi}"
        return None
    if not isinstance(value, int) or not (lo <= value <= hi):
        return f"{key} must be an int in [{lo}, {hi}]"
    return None


def mech_caps(config, max_turns=None, max_budget_usd=None):
    """Effective mech caps: defaults <- config.mech <- per-launch overrides.
    (caps, None) or (None, message). Fail closed on any malformed value or
    unknown key, matching the `models` rule -- never silently default."""
    block = (config or {}).get("mech")
    caps = dict(MECH_DEFAULTS)
    if block is not None:
        if not isinstance(block, dict):
            return None, "mech must be a JSON object"
        unknown = set(block) - MECH_KEYS
        if unknown:
            return None, f"mech has unknown keys: {sorted(unknown)}"
        for k in MECH_BOUNDS:
            if k in block:
                caps[k] = block[k]
        if "contract_commands" in block:
            err = validate_contract(
                {"v": 1, "task_id": "x", "commands": block["contract_commands"]}, "x"
            )
            if err:
                return None, f"mech.contract_commands: {err}"
    if max_turns is not None:
        caps["max_turns"] = max_turns
    if max_budget_usd is not None:
        caps["max_budget_usd"] = max_budget_usd
    for k in MECH_BOUNDS:
        err = _cap_error(k, caps[k])
        if err:
            return None, err
    return caps, None


def mech_contract(config, task_id):
    """Contract dict generated from config.mech.contract_commands, or None
    when the template is absent. Caller validates config via mech_caps first."""
    block = (config or {}).get("mech") or {}
    cmds = block.get("contract_commands") if isinstance(block, dict) else None
    if not cmds:
        return None
    return {"v": 1, "task_id": task_id, "commands": json.loads(json.dumps(cmds))}
```

In `main`, parsers:

```python
    mc = add("mech-caps")
    mc.add_argument("--max-turns", type=int, default=None)
    mc.add_argument("--max-budget-usd", type=float, default=None)
    add("mech-contract", "--task-id", "--worktree")
```

Handlers (before the final `return 2`):

```python
    if ns.cmd == "mech-caps":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        caps, err = mech_caps(read_config(repo_dir(ns.repo_slug)),
                              ns.max_turns, ns.max_budget_usd)
        if err:
            sys.stderr.write(f"[X] {err}\n")
            return 5
        print(json.dumps(caps))
        return 0
    if ns.cmd == "mech-contract":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        wt = Path(ns.worktree)
        _require(wt.is_dir(), "worktree must be an existing directory")
        cfg = read_config(repo_dir(ns.repo_slug))
        _, err = mech_caps(cfg)
        if err:
            sys.stderr.write(f"[X] {err}\n")
            return 5
        rec = mech_contract(cfg, ns.task_id)
        if rec is None:
            sys.stderr.write("[X] config has no mech.contract_commands\n")
            return 5
        rel = f"claude/contracts/{ns.task_id}-contract.json"
        out = wt / rel
        _require(contained(out, wt), "contract path escapes the worktree")
        _require(not out.exists(), "contract already exists; use it or remove it deliberately")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(rec, indent=2) + "\n")
        print(rel)
        return 0
```

`_require` exits 2 with a message (existing helper). `mech-caps` is read-only and unfenced (it reads config only).

- [ ] **Step 4: Run the unit suite** -- expected 0 FAIL.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add mech-caps and mech-contract verbs"
```

---

### Task 3: `emit-done --launch-id / --reason`, reason tokens, mech agent name

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (constants; `emit-done` parser + handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `MECH_REASONS` tuple; `emit-done` accepts optional `--launch-id <str>` and `--reason <token>`; `done.json` gains those keys only when given.

- [ ] **Step 1: Write the failing tests**

```sh
check "emit-done: optional launch_id and reason round-trip; bad reason rejected" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
$CLI emit-done --repo-slug slug-e --task-id td-x --workspace w1 --agent mech-td-x --phase implement \
  --outcome paused --head-sha h1 --base-sha b0 --launch-id mech-td-x-20260901T000000Z --reason needs_design
python3 -c "import json;d=json.load(open('$CLAUDE_CONFIG_DIR/herdr-orch/slug-e/tasks/td-x.done.json'));assert d['launch_id']=='mech-td-x-20260901T000000Z' and d['reason']=='needs_design',d"
$CLI emit-done --repo-slug slug-e --task-id td-x --workspace w1 --agent impl-td-x --phase implement \
  --outcome completed --head-sha h1 --base-sha b0
python3 -c "import json;d=json.load(open('$CLAUDE_CONFIG_DIR/herdr-orch/slug-e/tasks/td-x.done.json'));assert 'launch_id' not in d and 'reason' not in d,d"
rc=0; $CLI emit-done --repo-slug slug-e --task-id td-x --workspace w1 --agent impl-td-x --phase implement \
  --outcome paused --head-sha h1 --base-sha b0 --reason tired 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
SH

check "agent_name mech prefix obeys canonical constraints" <<PY
$LOAD
n=c.agent_name("mech","td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical")
assert n.startswith("mech-") and len(n)<=32 and re.fullmatch(r"mech-[a-z0-9-]{1,27}",n),n
assert c.agent_name("mech","TD-1",existing={"mech-td-1"})=="mech-td-1-2"
assert c.MECH_REASONS==("max_turns","max_budget","timeout","no_emit","error","needs_design","blocked_on_human","other")
sys.exit(0)
PY
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement**

Constant near `MECH_DEFAULTS`:

```python
MECH_REASONS = ("max_turns", "max_budget", "timeout", "no_emit", "error",
                "needs_design", "blocked_on_human", "other")
```

Parser: capture the `emit-done` parser and add the two options:

```python
    ed = add("emit-done", "--task-id", "--workspace", "--agent", "--phase",
             "--outcome", "--head-sha", "--base-sha")
    ed.add_argument("--launch-id", default=None)
    ed.add_argument("--reason", default=None)
```

Handler, inside the `emit-done` branch after building `done`:

```python
            if ns.launch_id:
                done["launch_id"] = ns.launch_id
            if ns.reason is not None:
                _require(ns.reason in MECH_REASONS,
                         f"reason must be one of {'|'.join(MECH_REASONS)}")
                done["reason"] = ns.reason
```

- [ ] **Step 4: Run the unit suite** -- 0 FAIL.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add launch id and reason to emit-done records"
```

---

### Task 4: Spend ledger validation, fold, watch, and `status` spend/totals/orphans

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new functions after `fold_status`; `WATCH_DIRS`; `status` handler)
- Test: `claude/hooks/herdr-orch.test.sh`

**Interfaces:**
- Produces: `SPEND_KEYS` tuple, `spend_path(rd, task_id) -> Path`, `append_spend(rd, task_id, rec) -> None` (raises OSError on failure), `_finite_nonneg(x, integer=False) -> bool`, `valid_spend_line(rec, task_id) -> bool`, `fold_spend(lines, task_id) -> dict` with keys `usd, turns, launches, unknown_cost_launches, skipped_lines`. `status` JSON: per task `spend`, top-level `_totals` (the five keys plus `untracked_launches`) and `_orphans` (sorted list).

- [ ] **Step 1: Write the failing tests** (AC6, AC7)

```sh
check "fold_spend: exact AC6 fixture" <<PY
$LOAD
L=[
 '{"v":1,"kind":"start","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L1","ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L1","num_turns":17,"total_cost_usd":0.42,"ts":"t"}',
 '{"v":1,"kind":"start","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L2","ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L2","num_turns":3,"total_cost_usd":null,"ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","launch_id":"L3","num_tur',
 '{"v":1,"kind":"end","task_id":"td-other","launch_id":"L4","num_turns":1,"total_cost_usd":9.0,"ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","launch_id":"L5","num_turns":1,"total_cost_usd":true,"ts":"t"}',
]
assert c.fold_spend(L,"td-x")=={"usd":0.42,"turns":20,"launches":2,"unknown_cost_launches":1,"skipped_lines":3}
assert c.fold_spend([],"td-x")=={"usd":0.0,"turns":0,"launches":0,"unknown_cost_launches":0,"skipped_lines":0}
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","num_turns":-1},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","total_cost_usd":float("nan")},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","num_turns":2.5},"td-x")
assert not c.valid_spend_line({"v":True,"kind":"end","task_id":"td-x","launch_id":"L"},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"mid","task_id":"td-x","launch_id":"L"},"td-x")
assert c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","subtype":"weird"},"td-x")
assert (".spend.jsonl", c.valid_task_id) in c.WATCH_DIRS["tasks"]
sys.exit(0)
PY

check "status: per-task spend, _totals with untracked_launches, _orphans" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-s"; mkdir -p "$RD/tasks" "$RD/workspaces"
F=$($CLI claim-owner --repo-slug slug-s --session S --host h --pid 1)
$CLI write-task --repo-slug slug-s --task-id td-a --session S --fence "$F" \
  --json '{"task_id":"td-a","status":"in-progress","workers":[{"role":"mech","launch_id":"L1"},{"role":"impl"}]}'
$CLI write-task --repo-slug slug-s --task-id td-b --session S --fence "$F" \
  --json '{"task_id":"td-b","status":"in-progress","workers":[{"role":"review"}]}'
printf '%s\n' '{"v":1,"kind":"start","task_id":"td-a","launch_id":"L1","ts":"t"}' \
  '{"v":1,"kind":"end","task_id":"td-a","launch_id":"L1","num_turns":17,"total_cost_usd":0.42,"ts":"t"}' > "$RD/tasks/td-a.spend.jsonl"
printf '{"v":1,"kind":"start","task_id":"td-z","launch_id":"L9","ts":"t"}\n' > "$RD/tasks/td-z.spend.jsonl"
$CLI status --repo-slug slug-s | python3 -c '
import json,sys; s=json.load(sys.stdin)
assert s["td-a"]["spend"]=={"usd":0.42,"turns":17,"launches":1,"unknown_cost_launches":0,"skipped_lines":0},s
assert s["td-b"]["spend"]["launches"]==0 and s["td-b"]["spend"]["usd"]==0.0
assert s["_totals"]=={"usd":0.42,"turns":17,"launches":1,"unknown_cost_launches":0,"skipped_lines":0,"untracked_launches":2},s
assert s["_orphans"]==["td-z"],s
'
SH
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement**

After `fold_status`:

```python
SPEND_KEYS = ("usd", "turns", "launches", "unknown_cost_launches", "skipped_lines")


def spend_path(rd, task_id) -> Path:
    return Path(rd) / "tasks" / f"{task_id}.spend.jsonl"


def append_spend(rd, task_id, rec) -> None:
    """Append one ledger line. Raises OSError on failure (caller maps it)."""
    p = spend_path(rd, task_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as f:
        f.write(json.dumps(rec) + "\n")
        f.flush()


def _finite_nonneg(x, integer=False) -> bool:
    """None passes (absent/unknown); bools never; ints/floats must be finite
    and >= 0; integer=True additionally requires an int."""
    if x is None:
        return True
    if isinstance(x, bool):
        return False
    if integer:
        return isinstance(x, int) and x >= 0
    return isinstance(x, (int, float)) and math.isfinite(x) and x >= 0


def valid_spend_line(rec, task_id) -> bool:
    if not isinstance(rec, dict):
        return False
    v = rec.get("v")
    if not isinstance(v, int) or isinstance(v, bool) or v != 1:
        return False
    if rec.get("kind") not in ("start", "end"):
        return False
    if rec.get("task_id") != task_id or not _nonempty_str(rec.get("launch_id")):
        return False
    if rec["kind"] == "end":
        if not _finite_nonneg(rec.get("num_turns"), integer=True):
            return False
        if not _finite_nonneg(rec.get("total_cost_usd")):
            return False
    return True


def fold_spend(lines, task_id):
    """Sum a task's ledger. Malformed/foreign lines are skipped and counted,
    never fatal -- same posture as parse_events."""
    out = {k: 0 for k in SPEND_KEYS}
    out["usd"] = 0.0
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            out["skipped_lines"] += 1
            continue
        if not valid_spend_line(rec, task_id):
            out["skipped_lines"] += 1
            continue
        if rec["kind"] == "start":
            out["launches"] += 1
            continue
        cost = rec.get("total_cost_usd")
        if cost is None:
            out["unknown_cost_launches"] += 1
        else:
            out["usd"] += cost
        if rec.get("num_turns") is not None:
            out["turns"] += rec["num_turns"]
    out["usd"] = round(out["usd"], 4)
    return out
```

`WATCH_DIRS["tasks"]` becomes:

```python
    "tasks": ((".done.json", valid_task_id), (".review.json", valid_task_id),
              (".spend.jsonl", valid_task_id)),
```

In the `status` handler, replace the result-building loop (from `result = {}` to `print(json.dumps(result))`) with:

```python
        result = {}
        totals = {k: 0 for k in SPEND_KEYS}
        totals["usd"] = 0.0
        untracked = 0
        primary = set()
        for tf in sorted((rd / "tasks").glob("*.json")):
            if tf.name.endswith((".done.json", ".review.json")):
                continue
            try:
                task = json.loads(tf.read_text())
            except ValueError:
                continue
            if not isinstance(task, dict):
                continue
            tid = task.get("task_id")
            primary.add(tf.name[: -len(".json")])
            sp = spend_path(rd, tid) if isinstance(tid, str) else None
            try:
                lines = sp.read_text().splitlines() if sp and sp.is_file() else []
            except OSError:
                lines = []
            spend = fold_spend(lines, tid)
            for k in SPEND_KEYS:
                totals[k] += spend[k]
            workers = task.get("workers")
            if isinstance(workers, list):
                untracked += sum(
                    1 for w in workers if isinstance(w, dict) and w.get("role") != "mech"
                )
            result[tid] = {
                "status": task.get("status"),
                "fold": fold_status(by_task.get(tid, [])),
                "spend": spend,
            }
        totals["usd"] = round(totals["usd"], 4)
        totals["untracked_launches"] = untracked
        orphans = set()
        for suffix in (".spend.jsonl", ".done.json"):
            for f in (rd / "tasks").glob(f"*{suffix}"):
                tid = f.name[: -len(suffix)]
                if valid_task_id(tid) and tid not in primary:
                    orphans.add(tid)
        result["_totals"] = totals
        result["_orphans"] = sorted(orphans)
        print(json.dumps(result))
        return 0
```

- [ ] **Step 4: Run both suites** -- existing `status` consumers only read `[tid]["status"]`; confirm the contract suite's `grep -q PROJ-1` and the unit suite's existing status checks still pass. 0 FAIL.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Fold mech spend ledger into status and watch"
```

---

### Task 5: `run-mech` wrapper

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (new `run_mech` + helpers after `append_spend`; CLI parser + handler)
- Test: `claude/hooks/herdr-orch.test.sh` (fake `claude` fixture + AC4/AC5 checks)

**Interfaces:**
- Consumes: `_cap_error`, `append_spend`, `_finite_nonneg`, `MECH_REASONS`, `now_iso`, `write_json_atomic`, `contained`, `state_root`, `_nonempty_str`.
- Produces: `SHELL_SAFE_RE`, `MECH_AGENT_RE`, `SHA40_RE`, `_CAP_SUBTYPES`, `parse_claude_result(stdout) -> dict|None`, `models_used(result) -> list`, `is_downgrade(models, alias) -> bool`, `own_launch_record(done, workspace, agent, launch_id, start_ts) -> bool`, `wrapper_outcome(subtype, head_sha, base_sha, dirty) -> (outcome, reason)`, `_git(worktree, *args) -> str|None`, `run_mech(rd, a, timeout_secs) -> int` where `a` is the parsed argparse namespace; CLI verb `run-mech`.

- [ ] **Step 1: Write the fake `claude` fixture and failing tests**

Add near the top of `herdr-orch.test.sh` (after `LOAD`) a helper that builds a fake `claude` on PATH:

```sh
# fake claude for run-mech tests: records argv/cwd/stdin/pid, runs
# $FAKE_CLAUDE_HOOK (a shell snippet, e.g. a simulated worker emit-done),
# sleeps $FAKE_CLAUDE_SLEEP secs, prints the JSON file $FAKE_CLAUDE_JSON,
# exits $FAKE_CLAUDE_RC (default 0).
make_fake_claude() {
    dir=$(mktemp -d)
    cat > "$dir/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_CLAUDE_LOG.argv"
pwd > "$FAKE_CLAUDE_LOG.cwd"
cat > "$FAKE_CLAUDE_LOG.stdin"
echo $$ > "$FAKE_CLAUDE_LOG.pid"
[ -n "$FAKE_CLAUDE_HOOK" ] && sh -c "$FAKE_CLAUDE_HOOK"
sleep "${FAKE_CLAUDE_SLEEP:-0}"
[ -n "$FAKE_CLAUDE_JSON" ] && cat "$FAKE_CLAUDE_JSON"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
    chmod +x "$dir/claude"; printf '%s' "$dir"
}
```

Then the checks (place after the Task-4 checks):

```sh
check "run-mech: success with fresh worker record; argv/stdin/cwd exact; ledger start+end" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); FAKE=$(make_fake_claude); PATH="$FAKE:$PATH"
CLI="python3 claude/hooks/herdr_orch_core.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
BASE=$(git -C "$WT" rev-parse HEAD)
printf 'do the thing\n' > "$RD/tasks/td-r.brief.md"
export FAKE_CLAUDE_LOG="$FAKE/log"; export FAKE_CLAUDE_JSON="$FAKE/res.json"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5,"total_cost_usd":0.11,"duration_ms":10,"session_id":"sid","modelUsage":{"claude-haiku-4-5-20251001":{}}}' > "$FAKE_CLAUDE_JSON"
export FAKE_CLAUDE_HOOK="git -C $WT -c user.name=t -c user.email=t@x commit -q --allow-empty -m work; $CLI emit-done --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --phase implement --outcome completed --head-sha \$(git -C $WT rev-parse HEAD) --base-sha $BASE --launch-id mech-td-r-20260901T000000Z"
$CLI run-mech --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --launch-id mech-td-r-20260901T000000Z \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/td-r.brief.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60
[ "$(cat $FAKE_CLAUDE_LOG.argv | tr '\n' ' ')" = "--model haiku --permission-mode auto --name mech-td-r -p --output-format json --max-turns 7 --max-budget-usd 0.5 " ]
[ "$(cat $FAKE_CLAUDE_LOG.stdin)" = "do the thing" ]
[ "$(cd "$WT" && pwd -P)" = "$(cd "$(cat $FAKE_CLAUDE_LOG.cwd)" && pwd -P)" ]
python3 - <<PY
import json
L=[json.loads(l) for l in open("$RD/tasks/td-r.spend.jsonl")]
assert [l["kind"] for l in L]==["start","end"],L
assert L[0]["max_turns"]==7 and L[0]["max_budget_usd"]==0.5 and L[0]["model"]=="haiku" and L[0]["launch_id"]=="mech-td-r-20260901T000000Z"
e=L[1]; assert e["subtype"]=="success" and e["total_cost_usd"]==0.11 and e["num_turns"]==5 and e["downgrade"] is False and e["record_written_by"]=="worker" and e["models_used"]==["claude-haiku-4-5-20251001"],e
d=json.load(open("$RD/tasks/td-r.done.json")); assert d["outcome"]=="completed" and "reason" not in d,d
PY
SH

check "run-mech: cap hits, no_emit, errors, dirty, unparseable, downgrade -> wrapper records" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); FAKE=$(make_fake_claude); PATH="$FAKE:$PATH"
CLI="python3 claude/hooks/herdr_orch_core.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
BASE=$(git -C "$WT" rev-parse HEAD); : > "$RD/tasks/b.md"
export FAKE_CLAUDE_LOG="$FAKE/log"; export FAKE_CLAUDE_JSON="$FAKE/res.json"
run() { $CLI run-mech --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --launch-id "mech-td-r-$1" \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/b.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60; }
expect() { python3 -c "import json;d=json.load(open('$RD/tasks/td-r.done.json'));assert (d['outcome'],d['reason'],d['launch_id'])==('$1','$2','mech-td-r-$3'),d"; }
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":7,"total_cost_usd":0.2}' > "$FAKE_CLAUDE_JSON"; run 1; expect paused max_turns 1
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":3,"total_cost_usd":0.5}' > "$FAKE_CLAUDE_JSON"; run 2; expect paused max_budget 2
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01}' > "$FAKE_CLAUDE_JSON"; run 3; expect paused no_emit 3
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"total_cost_usd":0.01}' > "$FAKE_CLAUDE_JSON"; run 4; expect failed error 4   # HEAD == base
git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m work; run 5; expect paused error 5              # ahead + clean
touch "$WT/dirty"; run 6; expect failed error 6                                                                            # ahead + dirty
rm "$WT/dirty"; git -C "$WT" checkout -q "$BASE"; git -C "$WT" checkout -q -B main
printf 'not json' > "$FAKE_CLAUDE_JSON"; run 7; expect failed error 7
python3 -c "import json;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];e=[l for l in L if l['kind']=='end'][-1];assert e['subtype']=='unparseable' and e['total_cost_usd'] is None and e['num_turns'] is None,e"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01,"modelUsage":{"claude-sonnet-5":{}}}' > "$FAKE_CLAUDE_JSON"; run 8
python3 -c "import json;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];e=L[-1];assert e['downgrade'] is True and e['models_used']==['claude-sonnet-5'],e"
# stale record from another launch is replaced; a live-launch record survives a cap hit
export FAKE_CLAUDE_HOOK="$CLI emit-done --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --phase implement --outcome completed --head-sha $BASE --base-sha $BASE --launch-id mech-td-r-9"
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":2,"total_cost_usd":0.5}' > "$FAKE_CLAUDE_JSON"; run 9
python3 -c "import json;d=json.load(open('$RD/tasks/td-r.done.json'));assert d['outcome']=='completed' and d['launch_id']=='mech-td-r-9',d"
unset FAKE_CLAUDE_HOOK; run 10; expect paused max_budget 10
python3 -c "import json;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];assert len([l for l in L if l['kind']=='start'])==10 and L[-1]['record_written_by']=='wrapper',len(L)"
SH

check "run-mech: timeout kills the child; unwritable ledger exits 2 before any write" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); FAKE=$(make_fake_claude); PATH="$FAKE:$PATH"
CLI="python3 claude/hooks/herdr_orch_core.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
BASE=$(git -C "$WT" rev-parse HEAD); : > "$RD/tasks/b.md"
export FAKE_CLAUDE_LOG="$FAKE/log"; export FAKE_CLAUDE_JSON="$FAKE/res.json"; export FAKE_CLAUDE_SLEEP=30
printf '{"type":"result","subtype":"success"}' > "$FAKE_CLAUDE_JSON"
$CLI run-mech --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --launch-id mech-td-r-1 \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/b.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60 --timeout-secs-override-for-test 2
python3 -c "import json;d=json.load(open('$RD/tasks/td-r.done.json'));assert (d['outcome'],d['reason'])==('paused','timeout'),d"
python3 -c "import json;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];assert L[-1]['subtype']=='timeout',L"
! kill -0 "$(cat $FAKE_CLAUDE_LOG.pid)" 2>/dev/null
unset FAKE_CLAUDE_SLEEP
chmod 500 "$RD/tasks"
rc=0; $CLI run-mech --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --launch-id mech-td-r-2 \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/b.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60 2>/dev/null || rc=$?
chmod 700 "$RD/tasks"
[ "$rc" -eq 2 ]   # start line itself unwritable -> exit 2, nothing written for launch 2
python3 -c "import json;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];assert not any(l['launch_id']=='mech-td-r-2' for l in L)"
SH

check "run-mech: unwritable done target exits 3 with the end line still appended" <<PY
$LOAD
import types, subprocess as sp
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-r"); (rd/"tasks").mkdir(parents=True)
wt=tempfile.mkdtemp(); sp.run(["git","-C",wt,"init","-q"],check=True)
sp.run(["git","-C",wt,"-c","user.name=t","-c","user.email=t@x","commit","-q","--allow-empty","-m","b"],check=True)
base=sp.run(["git","-C",wt,"rev-parse","HEAD"],capture_output=True,text=True,check=True).stdout.strip()
brief=rd/"tasks"/"b.md"; brief.write_text("x")
fake=tempfile.mkdtemp(); open(f"{fake}/claude","w").write('#!/bin/sh\ncat >/dev/null\nprintf \'{"type":"result","subtype":"success"}\'\n'); os.chmod(f"{fake}/claude",0o755)
os.environ["PATH"]=fake+":"+os.environ["PATH"]
(rd/"tasks"/"td-r.done.json").mkdir()   # a directory where the record must go -> write fails
a=types.SimpleNamespace(repo_slug="slug-r",task_id="td-r",workspace="w1",agent="mech-td-r",launch_id="mech-td-r-1",
  model="haiku",worktree=wt,base_sha=base,brief_file=str(brief),max_turns=7,max_budget_usd=0.5,timeout_secs=60)
assert c.run_mech(rd,a,60)==3
L=[json.loads(l) for l in open(rd/"tasks"/"td-r.spend.jsonl")]
assert [l["kind"] for l in L]==["start","end"] and L[-1]["record_written_by"]=="none",L
sys.exit(0)
PY

check "run-mech: validation exits 2 and writes nothing" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); FAKE=$(make_fake_claude); PATH="$FAKE:$PATH"
CLI="python3 claude/hooks/herdr_orch_core.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; : > "$RD/tasks/b.md"; OUT=$(mktemp -d); : > "$OUT/b.md"
B="$(printf %040d 0)"
base="--repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree $WT --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60"
try() { rc=0; $CLI run-mech "$@" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ] || { echo "expected 2 got $rc: $*" >&2; return 1; }; }
try $base --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$B" --brief-file "$OUT/b.md"            # brief outside STATE_ROOT
try $base --agent mech- --launch-id mech--1 --base-sha "$B" --brief-file "$RD/tasks/b.md"               # empty suffix
try $base --agent mech-Td-r --launch-id mech-Td-r-1 --base-sha "$B" --brief-file "$RD/tasks/b.md"       # uppercase
try $base --agent mech-abcdefghijklmnopqrstuvwxyz0123 --launch-id x --base-sha "$B" --brief-file "$RD/tasks/b.md"  # 33 chars
try $base --agent mech-td-r --launch-id other-1 --base-sha "$B" --brief-file "$RD/tasks/b.md"           # launch id not prefixed
try $base --agent mech-td-r --launch-id mech-td-r-1 --base-sha abc --brief-file "$RD/tasks/b.md"        # bad sha
try --repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree "$(mktemp -d)" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60 \
    --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$B" --brief-file "$RD/tasks/b.md"            # non-git worktree
try --repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree "$WT" --max-turns 0 --max-budget-usd 0.5 --timeout-secs 60 \
    --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$B" --brief-file "$RD/tasks/b.md"            # cap out of bounds
try $base --agent mech-td-r --launch-id 'mech-td-r-1;rm' --base-sha "$B" --brief-file "$RD/tasks/b.md" # metachar
try $base --agent mech-td-r --launch-id 'mech-td-r 1' --base-sha "$B" --brief-file "$RD/tasks/b.md"    # whitespace
[ ! -e "$RD/tasks/td-r.spend.jsonl" ] && [ ! -e "$RD/tasks/td-r.done.json" ]
SH
```

Note on the timeout check: `--timeout-secs` is bounded to >= 60 by spec, so the test uses a hidden `--timeout-secs-override-for-test` flag (an `argparse.SUPPRESS` option; the skill never passes it). Keep it explicit and documented in the parser comment.

- [ ] **Step 2: Run to verify they fail** (unknown verb `run-mech`).

- [ ] **Step 3: Implement**

Constants (next to `MECH_REASONS`):

```python
SHELL_SAFE_RE = re.compile(r"[A-Za-z0-9_./+:@-]+\Z")
MECH_AGENT_RE = re.compile(r"mech-[a-z0-9-]{1,27}\Z")
SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
_CAP_SUBTYPES = {"error_max_turns": "max_turns", "error_max_budget_usd": "max_budget"}
```

Helpers (after `append_spend`):

```python
def parse_claude_result(stdout: str):
    """The single result object from `claude -p --output-format json`, or
    None. Tolerates leading noise by scanning lines from the end."""
    for candidate in [stdout] + list(reversed(stdout.splitlines())):
        try:
            obj = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result":
            return obj
    return None


def models_used(result) -> list:
    mu = (result or {}).get("modelUsage")
    return sorted(mu.keys()) if isinstance(mu, dict) else []


def is_downgrade(models: list, alias: str) -> bool:
    """True when the CLI reports models and none belong to the requested
    alias family (alias is a substring of every model id in its family)."""
    return bool(models) and not any(alias in m for m in models)


def own_launch_record(done, workspace, agent, launch_id, start_ts) -> bool:
    if not isinstance(done, dict):
        return False
    if done.get("workspace_id") != workspace or done.get("agent") != agent:
        return False
    if "launch_id" in done:
        return done.get("launch_id") == launch_id
    ts = done.get("ts")
    return isinstance(ts, str) and ts >= start_ts


def wrapper_outcome(subtype, head_sha, base_sha, dirty):
    """(outcome, reason) for a launch whose worker left no record."""
    if subtype in _CAP_SUBTYPES:
        return "paused", _CAP_SUBTYPES[subtype]
    if subtype == "timeout":
        return "paused", "timeout"
    if subtype == "success":
        return "paused", "no_emit"
    usable = head_sha is not None and head_sha != base_sha and not dirty
    return ("paused" if usable else "failed"), "error"


def _git(worktree, *args):
    try:
        cp = subprocess.run(["git", "-C", worktree, *args], capture_output=True,
                            text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return cp.stdout.strip() if cp.returncode == 0 else None


def run_mech(rd, a, timeout_secs) -> int:
    """Launch a headless capped worker; write start/end ledger lines and a
    guaranteed completion record. Exit 0 all writes ok; 2 nothing written;
    3 a post-start write failed."""
    start_ts = now_iso()
    caps = {"max_turns": a.max_turns, "max_budget_usd": a.max_budget_usd,
            "timeout_secs": a.timeout_secs}
    base = {"v": 1, "task_id": a.task_id, "workspace_id": a.workspace,
            "agent": a.agent, "launch_id": a.launch_id}
    try:
        append_spend(rd, a.task_id, dict(base, kind="start", role="mech",
                                         model=a.model, ts=start_ts, **caps))
    except OSError:
        sys.stderr.write("[X] cannot append the spend ledger\n")
        return 2
    brief = Path(a.brief_file).read_text()
    argv = ["claude", "--model", a.model, "--permission-mode", "auto",
            "--name", a.agent, "-p", "--output-format", "json",
            "--max-turns", str(a.max_turns), "--max-budget-usd", str(a.max_budget_usd)]
    subtype, result, exit_code, stdout = "unparseable", None, None, ""
    try:
        proc = subprocess.Popen(argv, cwd=a.worktree, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
    except OSError as e:
        sys.stderr.write(f"[X] cannot launch claude: {e}\n")
    else:
        try:
            stdout, _err = proc.communicate(brief, timeout=timeout_secs)
            exit_code = proc.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
            subtype, exit_code = "timeout", proc.returncode
    if subtype != "timeout":
        result = parse_claude_result(stdout)
        if result is not None:
            subtype = str(result.get("subtype") or "unparseable")
    used = models_used(result)
    head = _git(a.worktree, "rev-parse", "HEAD")
    porcelain = _git(a.worktree, "status", "--porcelain")
    dirty = porcelain is None or porcelain != ""
    done_path = rd / "tasks" / f"{a.task_id}.done.json"
    try:
        existing = json.loads(done_path.read_text())
    except (OSError, ValueError):
        existing = None
    rc = 0
    written_by = "worker"
    if not own_launch_record(existing, a.workspace, a.agent, a.launch_id, start_ts):
        outcome, reason = wrapper_outcome(subtype, head, a.base_sha, dirty)
        done = {"v": 1, "task_id": a.task_id, "workspace_id": a.workspace,
                "agent": a.agent, "phase": "implement", "outcome": outcome,
                "head_sha": head or a.base_sha, "base_sha": a.base_sha,
                "launch_id": a.launch_id, "reason": reason, "dirty": dirty,
                "ts": now_iso()}
        try:
            write_json_atomic(done_path, done)
            written_by = "wrapper"
        except OSError:
            sys.stderr.write("[X] cannot write the completion record\n")
            written_by, rc = "none", 3

    def _num(k, integer=False):
        v = (result or {}).get(k)
        return v if _finite_nonneg(v, integer) else None

    end = dict(base, kind="end", subtype=subtype,
               is_error=bool((result or {}).get("is_error", subtype != "success")),
               num_turns=_num("num_turns", True), total_cost_usd=_num("total_cost_usd"),
               duration_ms=_num("duration_ms", True), models_used=used,
               downgrade=is_downgrade(used, a.model), record_written_by=written_by,
               exit_code=exit_code, session_id=(result or {}).get("session_id"),
               ts=now_iso())
    try:
        append_spend(rd, a.task_id, end)
    except OSError:
        sys.stderr.write("[X] cannot append the spend ledger end line\n")
        rc = 3
    return rc
```

Parser:

```python
    rm = add("run-mech", "--task-id", "--workspace", "--agent", "--launch-id",
             "--model", "--worktree", "--base-sha", "--brief-file")
    rm.add_argument("--max-turns", type=int, required=True)
    rm.add_argument("--max-budget-usd", type=float, required=True)
    rm.add_argument("--timeout-secs", type=int, required=True)
    # Test-only: the documented bound is >= 60s; the unit suite needs a
    # 2s wall clock to prove the kill path without a 60s sleep.
    rm.add_argument("--timeout-secs-override-for-test", type=int,
                    default=None, help=argparse.SUPPRESS)
```

Handler (validation only; all writes happen inside `run_mech`):

```python
    if ns.cmd == "run-mech":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        for name in ("repo_slug", "task_id", "workspace", "agent", "launch_id",
                     "model", "worktree", "base_sha", "brief_file"):
            _require(SHELL_SAFE_RE.match(str(getattr(ns, name))),
                     f"--{name.replace('_', '-')} contains whitespace or a shell metacharacter")
        _require(MECH_AGENT_RE.match(ns.agent), "agent must be mech-<1..27 of [a-z0-9-]>")
        _require(ns.launch_id.startswith(ns.agent + "-"), "launch-id must be prefixed by the agent name")
        _require(ns.model in CAP_MODELS, "model must be a known alias")
        _require(SHA40_RE.match(ns.base_sha), "base-sha must be 40 hex")
        for k in ("max_turns", "max_budget_usd", "timeout_secs"):
            err = _cap_error(k, getattr(ns, k))
            _require(err is None, err or "")
        bf = Path(ns.brief_file)
        _require(bf.is_file() and not bf.is_symlink() and contained(bf, state_root()),
                 "brief-file must be a regular file under STATE_ROOT")
        wt = Path(ns.worktree)
        _require(wt.is_dir() and _git(str(wt), "rev-parse", "--git-dir") is not None,
                 "worktree must be an existing git checkout")
        rd = repo_dir(ns.repo_slug)
        (rd / "tasks").mkdir(parents=True, exist_ok=True)
        timeout = ns.timeout_secs_override_for_test or ns.timeout_secs
        return run_mech(rd, ns, timeout)
```

`_require` already exits 2. `subprocess`, `signal`, `os`, `math` are already imported at the top (used by `run_contract_commands` and the watch).

- [ ] **Step 4: Run both suites** -- 0 FAIL. The timeout check adds about 2 s to the unit suite.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add run-mech headless capped worker wrapper"
```

---

### Task 6: Mech kickoff walkthrough in the contract suite (AC9)

**Files:**
- Modify: `claude/hooks/herdr-orch-contract.test.sh` (append a section 8 before the summary)

**Interfaces:**
- Consumes: `mech-caps`, `mech-contract`, `verify-contract --validate-only`, `run-mech`, `confirm-completion`, `status`, fake `herdr` (already defined in the file), fake `claude` (copy the `make_fake_claude` helper from Task 5 verbatim into this file -- suites do not share helpers).

- [ ] **Step 1: Write the failing walkthrough**

```sh
# 8. mech kickoff: config-generated contract committed on a fresh branch,
# base_sha = post-contract HEAD, pin computed, shell-safety, run-mech through
# pane run, ledger + record, status spend; relaunch; contract-only cannot complete.
make_fake_claude() {  # (same fixture as herdr-orch.test.sh)
    dir=$(mktemp -d)
    cat > "$dir/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_CLAUDE_LOG.argv"
pwd > "$FAKE_CLAUDE_LOG.cwd"
cat > "$FAKE_CLAUDE_LOG.stdin"
echo $$ > "$FAKE_CLAUDE_LOG.pid"
[ -n "$FAKE_CLAUDE_HOOK" ] && sh -c "$FAKE_CLAUDE_HOOK"
sleep "${FAKE_CLAUDE_SLEEP:-0}"
[ -n "$FAKE_CLAUDE_JSON" ] && cat "$FAKE_CLAUDE_JSON"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
    chmod +x "$dir/claude"; printf '%s' "$dir"
}
FAKE=$(make_fake_claude); PATH="$FAKE:$PATH"
export FAKE_CLAUDE_LOG="$FAKE/log"; export FAKE_CLAUDE_JSON="$FAKE/res.json"
F=$($CLI claim-owner --repo-slug "$SLUG" --session M --host h --pid 7 --stale-secs 0)
RD="$ROOT/herdr-orch/$SLUG"
printf '{"v":1,"user":"talon","default_base":"origin/main","mech":{"max_turns":9,"contract_commands":[{"name":"t","run":"true"}]}}' > "$RD/config.json"
$CLI write-capabilities --repo-slug "$SLUG" --session M --fence "$F" \
  --json '{"v":1,"session_id":"M","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
ok "mech model resolves to haiku" "[ \"\$($CLI resolve-model --repo-slug '$SLUG' --role mech --session M)\" = haiku ]"
CAPS=$($CLI mech-caps --repo-slug "$SLUG" --max-budget-usd 1)
ok "mech-caps merges config and override" "[ '$CAPS' = '{\"max_turns\": 9, \"max_budget_usd\": 1.0, \"timeout_secs\": 1800}' ]"
# fresh task branch in a scratch repo standing in for the worktree
WT=$(mktemp -d); git -C "$WT" init -q -b main; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
ORIG=$(git -C "$WT" rev-parse HEAD); git -C "$WT" checkout -q -b talon/td-m/x
REL=$($CLI mech-contract --repo-slug "$SLUG" --task-id td-m --worktree "$WT")
git -C "$WT" add "$REL"; git -C "$WT" -c user.name=t -c user.email=t@x commit -q -m "td-m: Add mech contract"
BASE=$(git -C "$WT" rev-parse HEAD)
ok "launch base is the post-contract HEAD, not origin" "[ '$BASE' != '$ORIG' ]"
SHA=$($CLI verify-contract --repo-slug "$SLUG" --task-id td-m --worktree "$WT" --contract "$REL" --allow-unpinned --validate-only)
ok "generated contract validates and pins" "printf '%s' '$SHA' | grep -qE '^[0-9a-f]{64}$'"
BRIEF="$RD/tasks/td-m.brief.md"; mkdir -p "$RD/tasks"; printf 'lint sweep\n' > "$BRIEF"
LID="mech-td-m-20260901T000000Z"
CMD="python3 claude/hooks/herdr_orch_core.py run-mech --repo-slug $SLUG --task-id td-m --workspace w1 --agent mech-td-m --launch-id $LID --model haiku --worktree $WT --base-sha $BASE --brief-file $BRIEF --max-turns 9 --max-budget-usd 1.0 --timeout-secs 1800"
ok "every launch value is shell-safe" "python3 -c \"import re,sys;sys.exit(0 if all(re.fullmatch(r'[A-Za-z0-9_./+:@-]+',w) for w in '$CMD'.split()) else 1)\""
: > "$BIN/calls.log"
PID=$(herdr worktree create --cwd "$PWD" --branch talon/td-m/x --base origin/main --label td-m | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])")
herdr pane run "$PID" "$CMD"
ok "mech launch goes through pane run in the root pane with run-mech, no claude argv" \
  "grep -q '^pane run w1:p1 python3 claude/hooks/herdr_orch_core.py run-mech ' '$BIN/calls.log' && ! grep -q 'pane run w1:p1 claude' '$BIN/calls.log'"
# the fake herdr only logs; run the same command for real to land state
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.3,"modelUsage":{"claude-haiku-4-5-20251001":{}}}' > "$FAKE_CLAUDE_JSON"
export FAKE_CLAUDE_HOOK="$CLI emit-done --repo-slug $SLUG --task-id td-m --workspace w1 --agent mech-td-m --phase implement --outcome completed --head-sha $BASE --base-sha $BASE --launch-id $LID"
$CMD
$CLI write-task --repo-slug "$SLUG" --task-id td-m --session M --fence "$F" \
  --json "{\"task_id\":\"td-m\",\"base_sha\":\"$BASE\",\"status\":\"in-progress\",\"contract_path\":\"$REL\",\"contract_sha256\":\"$SHA\",\"workers\":[{\"role\":\"mech\",\"phase\":\"implement\",\"workspace_id\":\"w1\",\"agent\":\"mech-td-m\",\"launch_id\":\"$LID\",\"model\":\"haiku\",\"peer_name\":null,\"caps\":$CAPS,\"created_by_this_orch\":true,\"started\":\"t\"}]}"
ok "ledger has start+end and status reports spend" \
  "$CLI status --repo-slug '$SLUG' | python3 -c \"import json,sys;s=json.load(sys.stdin);assert s['td-m']['spend']['usd']==0.3 and s['td-m']['spend']['launches']==1,s\""
ok "contract-only branch with a completed record cannot complete (HEAD == launch base)" \
  "! $CLI confirm-completion --repo-slug '$SLUG' --task-id td-m --workspace w1 --head-sha '$BASE'"
# relaunch: new launch id, second workers[] entry, launches doubles
unset FAKE_CLAUDE_HOOK
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":9,"total_cost_usd":0.7}' > "$FAKE_CLAUDE_JSON"
LID2="mech-td-m-20260901T001000Z"
$CLI run-mech --repo-slug "$SLUG" --task-id td-m --workspace w1 --agent mech-td-m --launch-id "$LID2" --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$BRIEF" --max-turns 9 --max-budget-usd 1.0 --timeout-secs 1800
ok "relaunch supersedes the record by launch id and doubles launches" \
  "python3 -c \"import json;d=json.load(open('$RD/tasks/td-m.done.json'));assert d['launch_id']=='$LID2' and d['reason']=='max_turns',d\" && $CLI status --repo-slug '$SLUG' | python3 -c \"import json,sys;s=json.load(sys.stdin);assert s['td-m']['spend']=={'usd':1.0,'turns':13,'launches':2,'unknown_cost_launches':0,'skipped_lines':0},s\""
```

Note: this section runs AFTER section 6 took ownership with session `T`; `claim-owner --session M --stale-secs 0` takes over again, which is why every fenced write here uses `M`/`$F`.

- [ ] **Step 2: Run** `sh claude/hooks/herdr-orch-contract.test.sh 2>&1 | tail -15` -- expected all new `ok` lines PASS once Tasks 1-5 are in; before them the section errors out (verifies the walkthrough bites). Fix any fake-herdr canned-JSON gaps (the fake's `worktree create` already returns `w1:p1`).

- [ ] **Step 3: Commit**

```bash
git add claude/hooks/herdr-orch-contract.test.sh
git commit -m "herdr: Add mech kickoff walkthrough to the contract suite"
```

---

### Task 7: Skill and reference docs

**Files:**
- Modify: `claude/skills/herdr-orchestration/SKILL.md` (sections 1 step 5, 2, 4, 8, 9)
- Modify: `claude/skills/herdr-orchestration/references/state-layout.md`
- Modify: `claude/skills/herdr-orchestration/references/brief-template.md`
- Modify: `claude/skills/herdr-orchestration/references/event-schema.md`
- Test: `claude/hooks/herdr-orch.test.sh` (doc-pin check, same style as "SKILL.md pins the non-available probe-sample capture bullet" at about line 796)

- [ ] **Step 1: Write the failing doc-pin check**

```sh
check "docs pin the mech tier: role row, run-mech launch, liveness table, ledger schema, brief variant" <<'SH'
S="claude/skills/herdr-orchestration/SKILL.md"; R="claude/skills/herdr-orchestration/references"
grep -q '| Mechanical worker (`mech`)' "$S"
grep -q 'resolve-model --role mech' "$S"
grep -q 'run-mech --repo-slug' "$S"
grep -q '"haiku":true' "$S"                                  # probe writes the fourth alias
grep -q 'mech-caps --repo-slug' "$S"
grep -q 'mech-contract --repo-slug' "$S"
grep -q 'Launch base' "$S"                                   # base_sha = post-contract HEAD
grep -q 'wrapper lost' "$S"                                  # mech liveness table
grep -q '_totals' "$S"
grep -q '"mech": {' "$R/state-layout.md"
grep -q '\.spend\.jsonl' "$R/state-layout.md"
grep -q '"haiku": true' "$R/state-layout.md"
grep -q 'launch_id' "$R/state-layout.md"
grep -q 'Mech brief variant' "$R/brief-template.md"
grep -q -- '--launch-id <launch_id>' "$R/brief-template.md"
grep -q 'spend.jsonl' "$R/event-schema.md"
SH
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Edit the docs.** Exact content to add (keep the existing prose; insert where noted):

**SKILL.md section 1 step 5**, the `write-capabilities` bullet: change the JSON to
`'{"v":1,"session_id":"<id>","available":{"fable":<true|false>,"opus":true,"sonnet":true,"haiku":true}}'`
and the lead-in to "(opus/sonnet/haiku default true)".

**SKILL.md section 2**, after the "Maturity check" paragraph, add:

```markdown
- **Mech item** -- a human-designated mechanical task (`kick off <item> as
  mech [max-turns <int>] [budget <number>]`, or todo frontmatter `tier: mech`
  with optional `mech_max_turns` / `mech_max_budget_usd`; instruction values
  override frontmatter field by field; any other form is not a mech kickoff).
  Never raw: it skips the plan phase and dispatches `phase: implement`,
  `role: mech` on the model `resolve-model --role mech` returns (default
  `haiku -> sonnet`), headless and capped (section 8, Mech launch). Caps come
  from `python3 "$CORE" mech-caps --repo-slug <slug> [--max-turns N]
  [--max-budget-usd X]` (exit 5 refuses the kickoff with its message; never
  clamp by hand). Contract source, in order: (1) committed at HEAD -> use it;
  (2) `config.mech.contract_commands` present, worktree clean, and the branch
  either created by this kickoff or adopted with HEAD == `base_sha` ->
  `python3 "$CORE" mech-contract --repo-slug <slug> --task-id <task_id>
  --worktree <path>` writes it, then `git add` + commit it as
  `<task_id>: Add mech contract` (the only commit the orchestrator ever
  authors; inside the step 3-6 window so step 9 cleanup covers it);
  (3) else refuse: "mech kickoff needs a committed contract or
  `mech.contract_commands` in config; kick off as raw instead". **Launch
  base:** after a generated-contract commit, record `base_sha` as the
  post-commit HEAD (the launch base) so every ahead-of-base check demands
  real worker commits; `base_ref` still names the ref. Then run the
  "Contract pinning" steps below unchanged.
```

Also in step 7's `write-task` bullet add: "for a `mech` dispatch the `workers[]` entry carries `role: "mech"`, `launch_id`, `caps`, and `peer_name: null`".

**SKILL.md section 4**, after the live-state table, add:

```markdown
**Mech workers (`role: mech`) use the ledger, not the agent poll.** The live
launch is the latest `workers[]` entry's `launch_id`; read
`tasks/<task_id>.spend.jsonl`:

| Ledger state for the live `launch_id` | Action |
| --- | --- |
| no `start` line | never began: report; a record older than a minute with no start is a failed launch (relaunch is the human's call) |
| `start` without `end`, start age <= `caps.timeout_secs` + 120s | in-progress (`blocked` on a hook `blocked` hint) |
| `start` without `end`, older | wrapper lost: report `paused: wrapper_lost`; status stays `in-progress`; no auto-relaunch |
| `end` present | correlate `done.json` (below) |

Correlation on `end`: `done.json` must carry this task id, the live
workspace, agent, and `launch_id` (lacking one, a `ts` >= the start line).
`completed` -> facts 1-6 unchanged (the git-ahead check runs against the
launch `base_sha`); `paused` -> stays `in-progress`, report "paused:
<reason or none>, spent $<usd> over <turns> turns of cap <max_turns>/$<max_budget_usd>"
with next actions in order: relaunch as mech with raised caps, or resume on
`impl`; `failed` -> `failed`. No mech transition depends on a Stop hint.
The `abandoned` rule (workspace AND worktree gone) is unchanged.

**Within-role fallback (right after `run-mech` returns).** An `end` line
with `downgrade: true`, or `subtype: error_during_execution` whose `errors`
text names the requested alias or "model", is model-attributable:
`disable-model --model <requested alias>`, re-run `resolve-model --role
mech`, relaunch once with a fresh `launch_id` (new `workers[]` entry; the
old launch's ledger lines stay). Cap 2 attempts per dispatch, then surface.

**Mech relaunch** is the "record exists + worker gone -> resume" path: allowed
only when the live launch has an `end` line (or is wrapper lost) and status
is `in-progress`/`blocked`; mint a new `launch_id`, append a `workers[]`
entry (caps via `mech-caps` from the new instruction/frontmatter), launch
`run-mech` again in the same workspace with `base_sha` unchanged. A `start`
without `end` inside the timeout window is "live" for kickoff idempotency.

**Blocked headless worker.** A `blocked` hint sets `blocked` as today; a
print-mode worker cannot be unblocked interactively -- the wall clock ends
it (`paused: timeout`); recommend relaunching with a brief that pre-answers
the prompt, or on `impl`.

The report line carries each task's `spend` and the summary carries
`_totals` (`usd`, `turns`, `launches`, `unknown_cost_launches`,
`skipped_lines`, `untracked_launches`) and `_orphans` (sidecars with no
primary record -- list for human cleanup; never auto-adopt or relaunch).
```

**SKILL.md section 8**: routing table row after the implementation worker:
`| Mechanical worker (\`mech\`) | haiku -> sonnet | default | human-designated mechanical work, headless \`claude -p\`, turn+budget+wall-clock capped; spend in \`tasks/<task_id>.spend.jsonl\` |`.
Then, after the "Verify-after-launch" block, add:

```markdown
**Mech launch (headless, wrapped).** Caps exist only in print mode, so a mech
worker is launched through the core wrapper in the workspace's root pane:

`herdr pane run <pane_id> "python3 $CORE run-mech --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent <agent> --launch-id <launch_id> --model $MODEL --worktree <worktree_path> --base-sha <base_sha> --brief-file <STATE_ROOT>/<slug>/tasks/<task_id>.brief.md --max-turns <N> --max-budget-usd <X> --timeout-secs <T>"`

Shell-safety: every value must match `[A-Za-z0-9_./+:@-]+`; refuse the launch
naming the offending value otherwise (`run-mech` re-checks and exits 2).
`<agent>` = `agent_name("mech", task_id)`; `<launch_id>` =
`<agent>-<YYYYMMDDTHHMMSSZ>` (UTC now), also placed in the brief. Write the
brief (references/brief-template.md, mech variant) to the `--brief-file` path
first. No `--name` capability check, no D4 banner read, no `ListAgents`
discovery (`peer_name: null`): the wrapper's `end` ledger line carries
`models_used` as the structural model signal. Publish state (section 2 step
7) right after `pane run` returns.
```

**SKILL.md section 9**: add rows
`| in-progress (mech) | ledger \`end\` + \`done.json\` \`paused\` for the live launch | \`paused\` | in-progress | no |`
and
`| in-progress (mech) | ledger \`end\` + \`done.json\` \`failed\` (branch not usable) | \`failed\` | failed | yes |`.

**state-layout.md**: in the `config.json` example add the `"mech": { ... }` block from spec s3 with its validation sentence; the capabilities example becomes `"available": { "fable": false, "opus": true, "sonnet": true, "haiku": true }` with "exactly the four aliases; `haiku` is legal only in `models.mech`"; the task record `workers[]` example gains a second entry `{"role": "mech", "phase": "implement", "workspace_id": "w1", "agent": "mech-proj-123", "peer_name": null, "model": "haiku", "launch_id": "mech-proj-123-20260901T200000Z", "caps": {"max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}, "created_by_this_orch": true, "started": "..."}`; the `done.json` section notes optional `launch_id`, `reason` (token list), `dirty`; add a `### tasks/<task_id>.spend.jsonl -- mech spend ledger` section with the two example lines from spec s6, the accepted-line rules, and the `status` `spend`/`_totals`/`_orphans` shapes. Add `.spend.jsonl` and `.brief.md` to the Layout tree.

**brief-template.md**: add `## Mech brief variant (\`mech-<t>\`)` after the plan variant:

```
You are `<agent-name>` (launch `<launch_id>`) doing mechanical task `<task_id>` in repo `<repo_slug>`.

## Task
<task_id>: <title>

<body>

You are a budget-capped mechanical worker: at most <max_turns> turns and
$<max_budget_usd>. Do only the mechanical task described. Do not brainstorm,
spec, or plan. If the task turns out to need design, commit what is safe and
emit `paused --reason needs_design`. Commit as you go.

## Workspace
- Branch: <branch>
- Worktree: <worktree_path>
- Base: <base_ref> @ <base_sha>   (launch base; your commits must land past it)
- Phase: implement

## Close
1. Commit all work.
2. Run `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path>`;
   `--outcome completed` only on exit 0 (or exit 5, noting "exit 5, no pin").
3. Run `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-done --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --phase implement --outcome completed|failed|paused --head-sha <sha> --base-sha <base_sha> --launch-id <launch_id> [--reason needs_design|blocked_on_human|other]`
4. Stop. Never push, merge, open a PR, or run /handoff.
```

**event-schema.md**: one paragraph after the watch paragraph: "`tasks/<task_id>.spend.jsonl` (the mech spend ledger, written by `$CORE run-mech`) is watched like the completion sidecars so an append wakes the orchestrator; its lines are ledger records, not events, and are folded only by `status`."

- [ ] **Step 4: Run both suites** -- 0 FAIL (the new doc-pin check passes; existing doc pins untouched).

- [ ] **Step 5: Commit**

```bash
git add claude/skills/herdr-orchestration claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Document the mech tier, run-mech launch, and spend ledger"
```

---

### Task 8: Final verification and live check record

**Files:**
- Modify: `docs/plans/2026-09-01-cheap-model-tier.md` close section only (branch-only)

- [ ] **Step 1: Run the task's own contract**

Run: `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 --task-id td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical --worktree "$PWD" --contract claude/contracts/td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical-contract.json --allow-unpinned`
Expected: `PASS 2 commands`.

- [ ] **Step 2: AC11 live check (human-verify; do not block on it).** If a real `claude` is available: write a one-line brief to `STATE_ROOT/<slug>/tasks/td-live.brief.md` ("Reply with the word ok, then run `git status`; do not commit"), and run `run-mech` directly (not through herdr) with `--max-turns 2 --max-budget-usd 0.25 --timeout-secs 120` against a scratch worktree of this repo, with `HERDR_ENV=1 HERDR_WORKSPACE_ID=<a workspace id that has an index under STATE_ROOT>` exported so the worker-status hook can fire. Confirm: an `end` line lands with `models_used` naming a haiku id, a `paused`/`no_emit` record is written, and whether `workspaces/<ws>.events.jsonl` gained a `stopped` line (that answers the print-mode Stop-hook question). Record the answer in the plan close as "Stop hook in print mode: confirmed fired / confirmed did not fire / not run". Cost: under $0.30.

- [ ] **Step 3: Commit the close note** (branch-only file; `git add -f`).

## Acceptance criteria -> verification contract mapping

Contract: `claude/contracts/td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical-contract.json` (two commands: `core-unit-suite` = `sh claude/hooks/herdr-orch.test.sh`, `orchestration-walkthrough-suite` = `sh claude/hooks/herdr-orch-contract.test.sh`). Each suite exits non-zero on any FAIL, so a broken implementation of any row below fails the contract.

| AC | Where it is checked | Contract command |
| --- | --- | --- |
| AC1 mech role resolution, haiku mech-only | Task 1 checks | core-unit-suite |
| AC2 four-alias capabilities, disable haiku | Task 1 CLI check | core-unit-suite |
| AC3 mech-caps validation | Task 2 checks | core-unit-suite |
| AC4 run-mech outcomes (a)-(i) | Task 5 checks 1-4 | core-unit-suite |
| AC5 run-mech validation exits 2 | Task 5 check 5 | core-unit-suite |
| AC6 spend fold fixture, _totals, _orphans | Task 4 checks | core-unit-suite |
| AC7 watch includes .spend.jsonl | Task 4 check 1 | core-unit-suite |
| AC8 emit-done launch_id/reason, mech agent name | Task 3 checks | core-unit-suite |
| AC9 mech kickoff walkthrough, launch base, relaunch, contract-only cannot complete | Task 6 | orchestration-walkthrough-suite |
| AC10 docs describe the tier | Task 7 doc-pin check | core-unit-suite |
| AC11 live mech launch, Stop hook in print mode | Task 8 step 2 | human-verify |

## Self-review notes

- Spec coverage: s1 -> Task 1; s2 -> Tasks 2, 6, 7; s3 -> Task 2; s4 -> Tasks 3, 5, 7; s5 -> Tasks 6, 7; s6 -> Tasks 4, 7; s7 unchanged; AC11 -> Task 8.
- Names used across tasks: `mech_caps`, `mech_contract`, `_cap_error`, `MECH_REASONS`, `append_spend`, `spend_path`, `fold_spend`, `valid_spend_line`, `_finite_nonneg`, `run_mech`, `parse_claude_result`, `models_used`, `is_downgrade`, `own_launch_record`, `wrapper_outcome`, `_git`, `SHELL_SAFE_RE`, `MECH_AGENT_RE`, `SHA40_RE` -- defined once each, in the task that first needs them.
- The `run-mech` handler validates before `run_mech` writes anything, so exit 2 never leaves a partial ledger (AC5); the start line is the first write and its failure is also exit 2 (Task 5 check 3).
