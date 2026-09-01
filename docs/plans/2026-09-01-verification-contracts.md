# Verification Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `verify-contract` verb to the herdr orchestration core and weave its three gates (worker advisory, pre-review enforced, post-rebase merge check) through the skill and brief surfaces.

**Architecture:** Pure validation/execution helpers plus one new read-only CLI verb in `herdr_orch_core.py`; pinning reuses the existing fenced `write-task` (two new fields + `merge_check`). Skill and brief docs gain additive sections only, so the sibling budget-tier task rebases cleanly.

**Tech Stack:** Python 3 stdlib only (existing core constraints), POSIX sh test suites.

**Spec:** `docs/specs/2026-09-01-verification-contracts.md` (branch-only commit; read it first -- every requirement below argues from it).

## Global Constraints

- Stdlib only in `herdr_orch_core.py`; fail safe/closed as documented per exit code.
- No emojis anywhere; `[OK]`/`[X]`/`[WARNING]` text markers only.
- `verify-contract` is read-only with respect to STATE_ROOT -- it never writes state.
- Docs edits to SKILL.md / brief-template.md / state-layout.md must be additive (new numbered facts, new subsections, new close steps) -- do not renumber or rewrite unrelated text; the sibling budget-tier task edits the same files next.
- Commit format `<scope>: <summary>` (<75 chars, imperative); no AI attribution.
- Test suites must stay green: `sh claude/hooks/herdr-orch.test.sh` and `sh claude/hooks/herdr-orch-contract.test.sh` (baseline: both fully PASS at branch base 53c3760).

## Acceptance-criteria mapping (spec requirement)

| Acceptance criterion (spec section) | Verified by |
| --- | --- |
| Contract schema validates / rejects per rules (Schema v1) | `herdr-orch.test.sh` new checks (Task 1) |
| Commands run in order, first failure stops, timeout kills group (verb step 6) | `herdr-orch.test.sh` new checks (Task 2) |
| Exit codes 0-5 per mode matrix (Modes and exit codes) | `herdr-orch.test.sh` new checks (Task 3) |
| Pin/tamper flow + merge_check round-trip (Pinning, Gate 3) | `herdr-orch-contract.test.sh` walkthrough (Task 4) |
| Speculative rebase sequence runnable (Gate 3) | `herdr-orch-contract.test.sh` temp-repo test (Task 4) |
| Docs gates present and consistent (Gates 1-3, state-layout) | human-verify: read the three doc diffs (Tasks 5-7) |

---

### Task 1: Contract schema validation + hashing (core helpers)

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (helpers section, after `valid_capabilities`)
- Test: `claude/hooks/herdr-orch.test.sh` (append checks before the summary block at the end)

**Interfaces:**
- Produces: `validate_contract(rec, task_id) -> str | None` (error message, or None when valid); `contract_sha256(path) -> str` (64-hex of file bytes); constants `CONTRACT_MAX_COMMANDS = 32`, `CONTRACT_MAX_TIMEOUT = 3600`, `CONTRACT_DEFAULT_TIMEOUT = 600`.

- [ ] **Step 1: Write the failing tests** -- append to `claude/hooks/herdr-orch.test.sh` immediately before the final summary lines (the `printf` of totals):

```sh
check "validate_contract accepts v1 and rejects each violation" <<PY
$LOAD
ok={"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}
assert c.validate_contract(ok,"PROJ-1") is None
assert c.validate_contract(ok,"PROJ-2") is not None          # task_id mismatch
assert c.validate_contract({**ok,"v":True},"PROJ-1") is not None   # bool v
assert c.validate_contract({**ok,"v":2},"PROJ-1") is not None
assert c.validate_contract({**ok,"extra":1},"PROJ-1") is not None  # unknown key
assert c.validate_contract({**ok,"commands":[]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","x":1}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":" ","run":"true"}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":""}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true"},{"name":"t","run":"true"}]},"PROJ-1") is not None  # dup name
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":True}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":0}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":3601}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":3600}]},"PROJ-1") is None
big=[{"name":"t%d"%i,"run":"true"} for i in range(33)]
assert c.validate_contract({**ok,"commands":big},"PROJ-1") is not None  # >32
assert c.validate_contract([],"PROJ-1") is not None          # non-dict
sys.exit(0)
PY

check "contract_sha256 hashes file bytes" <<PY
$LOAD
import hashlib
root=tempfile.mkdtemp()
p=os.path.join(root,"c.json");open(p,"w").write("{}")
assert c.contract_sha256(p)==hashlib.sha256(b"{}").hexdigest()
sys.exit(0)
PY
```

- [ ] **Step 2: Run to verify failure**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep -E 'FAIL.*(validate_contract|contract_sha256)'`
Expected: both new checks FAIL (AttributeError: no `validate_contract`).

- [ ] **Step 3: Implement** -- in `claude/hooks/herdr_orch_core.py`, after `valid_capabilities`:

```python
CONTRACT_MAX_COMMANDS = 32
CONTRACT_MAX_TIMEOUT = 3600
CONTRACT_DEFAULT_TIMEOUT = 600


def _nonempty_str(v) -> bool:
    return isinstance(v, str) and bool(v.strip())


def validate_contract(rec, task_id):
    """Error message for an invalid contract, None when valid. Fail closed:
    unknown keys, bool-typed ints, blank strings, dup names all reject."""
    if not isinstance(rec, dict):
        return "contract must be a JSON object"
    if set(rec.keys()) != {"v", "task_id", "commands"}:
        return "contract keys must be exactly v, task_id, commands"
    v = rec.get("v")
    if not isinstance(v, int) or isinstance(v, bool) or v != 1:
        return "v must be the integer 1"
    if rec.get("task_id") != task_id:
        return "contract task_id does not match the task"
    cmds = rec.get("commands")
    if not isinstance(cmds, list) or not cmds:
        return "commands must be a non-empty list"
    if len(cmds) > CONTRACT_MAX_COMMANDS:
        return f"commands exceeds max {CONTRACT_MAX_COMMANDS}"
    names = set()
    for cmd in cmds:
        if not isinstance(cmd, dict):
            return "each command must be an object"
        if not set(cmd.keys()) <= {"name", "run", "timeout_secs"}:
            return "command keys must be within name, run, timeout_secs"
        if not _nonempty_str(cmd.get("name")) or not _nonempty_str(cmd.get("run")):
            return "command name and run must be non-empty strings"
        if cmd["name"] in names:
            return f"duplicate command name: {cmd['name']}"
        names.add(cmd["name"])
        t = cmd.get("timeout_secs", CONTRACT_DEFAULT_TIMEOUT)
        if not isinstance(t, int) or isinstance(t, bool) or not (
            1 <= t <= CONTRACT_MAX_TIMEOUT
        ):
            return f"timeout_secs must be an int in [1, {CONTRACT_MAX_TIMEOUT}]"
    return None


def contract_sha256(path) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()
```

- [ ] **Step 4: Run to verify pass**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -5`
Expected: all checks PASS, zero FAIL.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add contract schema validation and hashing to core"
```

### Task 2: Contract command runner with process-group timeout

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (below `contract_sha256`)
- Test: `claude/hooks/herdr-orch.test.sh` (append)

**Interfaces:**
- Consumes: `CONTRACT_DEFAULT_TIMEOUT` (Task 1).
- Produces: `run_contract_commands(commands, worktree) -> int` (0 all passed; 1 first failure/timeout; prints `ok <name>` per pass, `FAIL <name> exit=<n|timeout>` on stop, `PASS <n> commands` at the end).

- [ ] **Step 1: Write the failing tests** -- append:

```sh
check "run_contract_commands: pass, first-failure stop, timeout killpg" <<PY
$LOAD
import time
root=tempfile.mkdtemp()
cmds=[{"name":"a","run":"true"},{"name":"b","run":"true"}]
assert c.run_contract_commands(cmds,root)==0
marker=os.path.join(root,"ran")
cmds=[{"name":"a","run":"false"},{"name":"b","run":"touch "+marker}]
assert c.run_contract_commands(cmds,root)==1
assert not os.path.exists(marker)                 # stopped at first failure
cmds=[{"name":"slow","run":"sleep 30","timeout_secs":1}]
t0=time.time()
assert c.run_contract_commands(cmds,root)==1
assert time.time()-t0 < 10                        # killed, not waited out
cmds=[{"name":"cwd","run":"touch ran"}]
assert c.run_contract_commands(cmds,root)==0 and os.path.exists(marker)  # cwd=worktree
sys.exit(0)
PY
```

- [ ] **Step 2: Run to verify failure**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep -E 'FAIL.*run_contract'`
Expected: FAIL (no `run_contract_commands`).

- [ ] **Step 3: Implement**

```python
def run_contract_commands(commands, worktree) -> int:
    """Run each contract command via sh -c in the worktree, streaming output.
    Own process group per command; on timeout the whole group is SIGKILLed
    (best-effort -- a double-forked daemon can escape). First failure stops
    the run. Returns 0 iff every command exited 0."""
    import signal
    import subprocess

    for cmd in commands:
        t = cmd.get("timeout_secs", CONTRACT_DEFAULT_TIMEOUT)
        proc = subprocess.Popen(
            ["sh", "-c", cmd["run"]], cwd=worktree, start_new_session=True
        )
        try:
            rc = proc.wait(timeout=t)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
            print(f"FAIL {cmd['name']} exit=timeout", flush=True)
            return 1
        if rc != 0:
            print(f"FAIL {cmd['name']} exit={rc}", flush=True)
            return 1
        print(f"ok {cmd['name']}", flush=True)
    print(f"PASS {len(commands)} commands", flush=True)
    return 0
```

- [ ] **Step 4: Run to verify pass**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add contract command runner with group timeout"
```

### Task 3: `verify-contract` CLI verb

**Files:**
- Modify: `claude/hooks/herdr_orch_core.py` (`main()`: new subparser + handler)
- Test: `claude/hooks/herdr-orch.test.sh` (append)

**Interfaces:**
- Consumes: `validate_contract`, `contract_sha256`, `run_contract_commands`, `contained`, `valid_repo_slug`, `valid_task_id`, `repo_dir`, `state_root`, `_require`.
- Produces: CLI verb `verify-contract --repo-slug S --task-id T --worktree P [--contract RELPATH] [--allow-unpinned] [--validate-only]`. Exit codes: 0 pass/valid, 1 command fail/timeout, 2 usage/schema (via `_require`'s `SystemExit(2)`), 3 contract file missing, 4 hash mismatch, 5 no pin. `--validate-only` prints the sha256 on success.

- [ ] **Step 1: Write the failing tests** -- append (shell-mode checks, following the suite's existing shell-check idiom):

```sh
check "verify-contract: unpinned validate/run/missing/schema exits" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$WT/c.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract c.json --allow-unpinned --validate-only | grep -qE '^[0-9a-f]{64}$'
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract c.json --allow-unpinned
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract missing.json --allow-unpinned 2>/dev/null; [ $? -eq 3 ] || exit 1
printf '{"v":1,"task_id":"WRONG","commands":[{"name":"t","run":"true"}]}' > "$WT/bad.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract bad.json --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"false"}]}' > "$WT/f.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract f.json --allow-unpinned 2>/dev/null; [ $? -eq 1 ] || exit 1
exit 0
SH

check "verify-contract: pinned mode enforces pin, hash, path match" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$WT/c.json"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"in-progress"}'
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" 2>/dev/null
[ $? -eq 5 ] || exit 1                                                              # no pin
set -e
SHA=$(python3 -c "import hashlib;print(hashlib.sha256(open('$WT/c.json','rb').read()).hexdigest())")
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"in-progress","contract_path":"c.json","contract_sha256":"'"$SHA"'"}'
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT"           # pass
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract other.json 2>/dev/null; [ $? -eq 2 ] || exit 1                         # path mismatch
MARKER="$WT/tampered-ran"
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"touch tampered-ran"}]}' > "$WT/c.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" 2>/dev/null
[ $? -eq 4 ] || exit 1                                                              # tamper
[ ! -f "$MARKER" ] || exit 1                                                        # never ran
exit 0
SH

check "verify-contract: rejects escape paths and symlinked contracts" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d); OUT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$OUT/c.json"
ln -s "$OUT/c.json" "$WT/link.json"
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract ../escape.json --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract link.json --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1   # --allow-unpinned needs --contract
exit 0
SH
```

- [ ] **Step 2: Run to verify failure**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | grep -cE 'FAIL.*verify-contract'`
Expected: `3` (argparse: invalid choice 'verify-contract').

- [ ] **Step 3: Implement** -- in `main()`. Subparser (with the other `add(...)` calls):

```python
    vc = add("verify-contract", "--task-id", "--worktree")
    vc.add_argument("--contract", default=None)
    vc.add_argument("--allow-unpinned", action="store_true")
    vc.add_argument("--validate-only", action="store_true")
```

Handler (with the other read-only verbs, before the final `return 2`):

```python
    if ns.cmd == "verify-contract":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        wt = Path(ns.worktree)
        _require(wt.is_dir(), "worktree must be an existing directory")
        _require(
            not ns.allow_unpinned or ns.contract,
            "--allow-unpinned requires --contract",
        )
        rel = ns.contract
        expected_sha = None
        if not ns.allow_unpinned:
            tf = repo_dir(ns.repo_slug) / "tasks" / f"{ns.task_id}.json"
            _require(contained(tf, state_root()), "escapes state root")
            try:
                task = json.loads(tf.read_text())
            except (OSError, ValueError):
                task = {}
            pin_path = task.get("contract_path")
            expected_sha = task.get("contract_sha256")
            if not isinstance(pin_path, str) or not isinstance(expected_sha, str):
                sys.stderr.write("[X] no contract pinned for task\n")
                return 5
            _require(
                rel is None or rel == pin_path,
                "--contract does not match the pinned contract_path",
            )
            rel = pin_path
        cf = wt / rel
        # contained() resolves symlinks, so an in-tree symlink to an outside
        # file already fails containment; the explicit is_symlink() rejection
        # also covers a symlink to another file INSIDE the worktree.
        _require(
            contained(cf, wt) and not cf.is_symlink(),
            "contract path escapes the worktree or is a symlink",
        )
        if not cf.is_file():
            sys.stderr.write("[X] contract file missing\n")
            return 3
        actual_sha = contract_sha256(cf)
        if expected_sha is not None and actual_sha != expected_sha:
            sys.stderr.write("[X] contract hash mismatch (tamper or drift)\n")
            return 4
        try:
            rec = json.loads(cf.read_text())
        except ValueError:
            rec = None
        err = validate_contract(rec, ns.task_id)
        _require(err is None, f"invalid contract: {err}")
        if ns.validate_only:
            print(actual_sha)
            return 0
        return run_contract_commands(rec["commands"], str(wt))
```

- [ ] **Step 4: Run to verify pass**

Run: `sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/hooks/herdr_orch_core.py claude/hooks/herdr-orch.test.sh
git commit -m "herdr: Add verify-contract verb with pin and mode matrix"
```

### Task 4: Walkthrough + speculative-rebase tests

**Files:**
- Modify: `claude/hooks/herdr-orch-contract.test.sh` (append before the summary block)

**Interfaces:**
- Consumes: CLI verbs from Task 3; the suite's existing `$CLI`, `$ROOT`, `$SLUG`, fence `$F`, task PROJ-1 fixtures, `ok` helper.

- [ ] **Step 1: Append the contract-lifecycle walkthrough**:

```sh
# N. verification contract: author -> pin -> verify -> tamper -> merge_check
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$WT/contract.json"
SHA=$($CLI verify-contract --repo-slug "$SLUG" --task-id PROJ-1 --worktree "$WT" \
  --contract contract.json --allow-unpinned --validate-only)
ok "plan-phase validate-only prints the pin hash" "printf '%s' '$SHA' | grep -qE '^[0-9a-f]{64}$'"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress","contract_path":"contract.json","contract_sha256":"'"$SHA"'"}'
ok "pinned verify passes for the impl phase" \
  "$CLI verify-contract --repo-slug '$SLUG' --task-id PROJ-1 --worktree '$WT' >/dev/null"
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"},{"name":"x","run":"true"}]}' > "$WT/contract.json"
ok "tampered contract is exit 4" \
  "$CLI verify-contract --repo-slug '$SLUG' --task-id PROJ-1 --worktree '$WT' 2>/dev/null; [ \$? -eq 4 ]"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"reviewed","contract_path":"contract.json","contract_sha256":"'"$SHA"'","merge_check":{"base_main_sha":"m1","branch_head_sha":"h1","result":"pass","ts":"t"}}'
ok "merge_check round-trips through write-task" \
  "python3 -c \"import json,sys;d=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.json'));sys.exit(0 if d['merge_check']['result']=='pass' else 1)\""
```

- [ ] **Step 2: Append the speculative-rebase temp-repo test** (real git; proves the documented gate-3 sequence runnable):

```sh
# N+1. speculative merge check: detached worktree rebase + verify, conflict abort
GR=$(mktemp -d)
git -C "$GR" init -q -b main
git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$GR" checkout -q -b task
printf '{"v":1,"task_id":"PROJ-9","commands":[{"name":"t","run":"test -f feature.txt"}]}' > "$GR/contract.json"
echo f > "$GR/feature.txt"
git -C "$GR" add contract.json feature.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -q -m task-work
git -C "$GR" checkout -q main
echo m > "$GR/main.txt"; git -C "$GR" add main.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -q -m main-advance
BR=$(git -C "$GR" rev-parse task); MAIN=$(git -C "$GR" rev-parse main)
TMP="$GR-spec"
git -C "$GR" worktree add --detach -q "$TMP" "$BR"
git -C "$TMP" -c user.email=t@t -c user.name=t rebase -q "$MAIN"
F2=$($CLI claim-owner --repo-slug slug-rebase --session S --host h --pid 1)
SHA9=$(python3 -c "import hashlib;print(hashlib.sha256(open('$TMP/contract.json','rb').read()).hexdigest())")
$CLI write-task --repo-slug slug-rebase --task-id PROJ-9 --session S --fence "$F2" \
  --json '{"task_id":"PROJ-9","contract_path":"contract.json","contract_sha256":"'"$SHA9"'"}'
ok "verify-contract passes on the rebased detached tree" \
  "$CLI verify-contract --repo-slug slug-rebase --task-id PROJ-9 --worktree '$TMP' >/dev/null"
git -C "$GR" worktree remove --force "$TMP"
ok "temp worktree cleaned up" "[ ! -d '$TMP' ]"
git -C "$GR" checkout -q main
echo conflict > "$GR/feature.txt"; git -C "$GR" add feature.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -q -m conflicting
MAIN2=$(git -C "$GR" rev-parse main)
git -C "$GR" worktree add --detach -q "$TMP" "$BR"
if git -C "$TMP" -c user.email=t@t -c user.name=t rebase -q "$MAIN2" >/dev/null 2>&1; then RB=0; else RB=1; fi
ok "conflicting rebase reports failure for conflict result" "[ $RB -eq 1 ]"
git -C "$TMP" rebase --abort 2>/dev/null || true
git -C "$GR" worktree remove --force "$TMP"
```

Note the task-branch checkout for `contract.json` happens ON the task branch
(the `checkout -q -b task` precedes the write) so the contract rides the
rebased commits, matching the spec's gate-3 claim.

- [ ] **Step 3: Run both suites**

Run: `sh claude/hooks/herdr-orch-contract.test.sh 2>&1 | tail -5 && sh claude/hooks/herdr-orch.test.sh 2>&1 | tail -3`
Expected: all PASS, zero FAIL.

- [ ] **Step 4: Commit**

```bash
git add claude/hooks/herdr-orch-contract.test.sh
git commit -m "herdr: Add contract lifecycle and speculative-rebase walkthrough tests"
```

### Task 5: state-layout.md schema docs

**Files:**
- Modify: `claude/skills/herdr-orchestration/references/state-layout.md`

**Interfaces:**
- Consumes: field names from Tasks 1-3 (`contract_path`, `contract_sha256`, `merge_check`).

- [ ] **Step 1: Add the task-record fields.** In the `tasks/<task_id>.json` schema JSON block, add after `"review_outcome": null,`:

```json
  "contract_path": "docs/plans/PROJ-123-contract.json",
  "contract_sha256": "<64hex>",
  "merge_check": null,
```

After that schema's existing explanatory paragraph ("`workers` is a list..."), append:

```markdown
`contract_path` (worktree-relative) and `contract_sha256` are the
verification-contract pin, written by the orchestrator at implement dispatch
(the sha256 of the committed contract blob; see the contract section below).
Records predating the feature lack both fields -- `verify-contract` then
exits 5 and the skill's grandfather rule applies. `merge_check` records the
latest post-rebase speculative merge check:

```json
{
  "base_main_sha": "<40hex>",
  "branch_head_sha": "<40hex>",
  "result": "pass|fail|conflict",
  "ts": "..."
}
```

Only `pass`/`fail`/`conflict` are ever recorded; infrastructure or integrity
trouble writes nothing (retried next check-in). Any `merge_check` whose SHAs
do not match live HEAD and current `origin/<default>` is stale -- ignored and
re-run; it is nulled whenever `review_head_sha` is cleared.
```

- [ ] **Step 2: Add the contract-file section.** Append a new `###` section at the end of the file:

```markdown
### `docs/plans/<task_id>-contract.json` -- verification contract (branch-committed)

The only per-task artifact NOT under `STATE_ROOT`: committed on the task
branch (`git add -f`; docs/ is gitignored) under the branch-only convention,
authored by the plan worker, pinned by hash into the task record at
implement dispatch, and executed by the `verify-contract` verb (worker gate,
pre-review gate, post-rebase merge gate -- SKILL.md sections 2, 4, and 6).

```json
{
  "v": 1,
  "task_id": "PROJ-123",
  "commands": [
    {"name": "core-tests", "run": "sh claude/hooks/herdr-orch.test.sh", "timeout_secs": 600}
  ]
}
```

Validation is fail-closed: `v` must be integer 1; `task_id` must match; 1-32
commands, each `{name, run[, timeout_secs 1-3600]}` with unique non-blank
names and no unknown keys. Commands run via `sh -c` from the worktree root
and must be repo-local, deterministic, and worktree-safe: no STATE_ROOT
writes, no machine-state mutation, no network, no secret echo. Full
requirements: `docs/specs/2026-09-01-verification-contracts.md` (branch-only)
and the authoring rules echoed in `brief-template.md`.
```

- [ ] **Step 3: Regression guard and commit**

Run: `sh claude/hooks/claude-hooks.test.sh 2>&1 | tail -3` (docs change must not affect it)

```bash
git add claude/skills/herdr-orchestration/references/state-layout.md
git commit -m "herdr: Document contract pin, merge_check, and contract schema"
```

### Task 6: SKILL.md gate wiring

**Files:**
- Modify: `claude/skills/herdr-orchestration/SKILL.md`

**Interfaces:**
- Consumes: verb syntax from Task 3; record fields from Task 5.

All edits are additive; do not renumber existing steps/facts.

- [ ] **Step 1: Section 2 (kickoff, plan-ready path).** In the plan-ready bullet of the section-2 intro, after "dispatch an `implement` worker directly," insert: "(only after the contract pinning steps at the end of this section; a plan-ready item without a committed contract is treated as raw)". Then append at the end of section 2, after step 9:

```markdown
**Contract pinning (implement dispatch, both paths).** Before launching any
`implement` worker (plan-ready kickoff here, or phase advancement in section
2a), pin the task's verification contract into the fenced task record:
require the task worktree clean (`git status --porcelain` empty) and the
contract tracked at HEAD (`git cat-file -e
HEAD:docs/plans/<task_id>-contract.json`); then run
`python3 "$CORE" verify-contract --repo-slug <slug> --task-id <task_id>
--worktree <path> --contract docs/plans/<task_id>-contract.json
--allow-unpinned --validate-only` -- it prints the sha256 -- and `write-task`
the record with `contract_path` and `contract_sha256` set. A missing or
invalid contract blocks the dispatch exactly like a missing plan. The pin is
written once; the orchestrator never re-pins on its own -- a later hash
mismatch is an integrity halt surfaced to the human, and only an explicit
human instruction (after a deliberate committed contract change) re-runs
these pinning steps.
```

- [ ] **Step 2: Section 2a (phase advancement).** In step 2 ("Verify the plan landed:"), extend the sentence: ", including `docs/plans/<task_id>-contract.json` -- then run the section-2 contract pinning steps now, before the implement launch in step 3."

- [ ] **Step 3: Section 4 (completion correlation).** Append fact 6 after fact 5 (the phase gate):

```markdown
6. **Contract gate:** the task worktree is clean (`git status --porcelain`
   empty), `python3 "$CORE" verify-contract --repo-slug <slug> --task-id
   <task_id> --worktree <path>` exits 0, and `git rev-parse HEAD` afterwards
   still equals the correlated HEAD (an advance during the run discards the
   result; re-correlate next check-in). On exit 1 the task stays
   `in-progress`: surface the failing command output and recommend
   resuming/re-briefing the implement worker -- never dispatch review. Exit 4
   (hash mismatch) or exit 5 on a record CARRYING a pin is an integrity
   halt: surface it and stop advancing this task; never re-pin to clear it.
   Exit 5 on a record with NO `contract_path` field is the grandfather path
   (task predates contracts): warn `[WARNING] no contract pinned
   (pre-contract task)` and treat this gate as passed. This gate augments
   facts 1-5; it never replaces them.
```

- [ ] **Step 4: Section 6 (surface for merge).** After the vibe-audit paragraph and before the final "Surface:" paragraph, insert:

```markdown
**Post-rebase contract check (speculative merge check).** After
`confirm-review` and the vibe-audit gate clear, and before surfacing:
`git fetch`, capture `MAIN_SHA` (`origin/<default>`) and live HEAD. A
recorded `merge_check` with `result: "pass"` matching both exactly means
skip and surface. Otherwise, in a scratch location OUTSIDE the task
worktree: `git worktree add --detach <tmp> <head>`; `git -C <tmp> rebase
<MAIN_SHA>`. On conflict: `git -C <tmp> rebase --abort`, record
`result: "conflict"`. On a clean rebase:
`python3 "$CORE" verify-contract --repo-slug <slug> --task-id <task_id>
--worktree <tmp>` and record `result: "pass"` (exit 0) or `"fail"` (exit 1).
Always `git worktree remove --force <tmp>` (a failed removal is surfaced for
manual cleanup but does not invalidate the result). Write the `merge_check`
object (`base_main_sha`, `branch_head_sha`, `result`, `ts`) via `write-task`.
Fetch/worktree/rebase infrastructure errors and verify exits 2/3 record
NOTHING -- surface and retry next check-in; exit 4 (or 5 on a pinned record)
is the integrity halt of section 4. Surface merge-ready ONLY on a matching
`result: "pass"`; on `fail`/`conflict` the task stays `reviewed` unsurfaced,
with the cause and the recommended fix path reported (rebase/fix -> new HEAD
-> stale-review reset -> fresh cycle). This is an advisory compatibility
check, not a serializing queue: the human merge remains the serialization
point. A grandfathered pinless task skips this check with the section-4
`[WARNING]`. The branch itself never moves here, so this check can never
trip the stale-review rule.
```

- [ ] **Step 5: Section 4 stale-review rule.** In the stale-verdict recovery step "(c) clear `review_head_sha` to `null`", extend with: "and reset `merge_check` to `null` (a stale review invalidates any recorded merge check)".

- [ ] **Step 6: Verify and commit.** Re-read sections 2, 2a, 4, and 6 top to bottom, checking that existing numbering and cross-references are untouched and the new text references only verbs/fields that exist (Tasks 3 and 5).

```bash
git add claude/skills/herdr-orchestration/SKILL.md
git commit -m "herdr: Wire contract gates into kickoff, completion, and merge surface"
```

### Task 7: brief-template.md worker gates

**Files:**
- Modify: `claude/skills/herdr-orchestration/references/brief-template.md`

**Interfaces:**
- Consumes: verb syntax from Task 3.

- [ ] **Step 1: Implement-phase close.** In the main (implement) brief's `## Close` block, insert a new step 2 between "Commit all work." and the emit-done step, renumbering the following steps of this template block only:

```markdown
2. Run
   `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path>`.
   You may use `--outcome completed` in the next step ONLY if it exits 0. If
   you cannot make the contract pass, emit `failed` or `paused` instead --
   never `completed`. (Exit 5 means no contract is pinned for this task --
   note that in your close and proceed; the orchestrator applies its
   grandfather rule.)
```

- [ ] **Step 2: Plan-phase brief.** In the plan-phase variant's task section, after the pipeline sentence ending "codex-plan-review.", append:

```markdown
Author the task's verification contract at
`docs/plans/<task_id>-contract.json` alongside the plan: 1-32 commands, each
`{"name", "run"[, "timeout_secs" 1-3600]}`, that are falsifiable (a broken
implementation must fail at least one), repo-local, deterministic, and
worktree-safe (no STATE_ROOT writes, no machine-state mutation, no network,
no secret echo). Include in the plan a mapping table pairing each acceptance
criterion with its contract command (or an explicit "human-verify" entry).
Validate it --
`python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path> --contract docs/plans/<task_id>-contract.json --allow-unpinned --validate-only`
must exit 0 -- and commit it with the plan (`git add -f`).
```

- [ ] **Step 3: Verify and commit.** Confirm both templates still read as complete standalone briefs (every placeholder in `<...>` form, close steps numbered correctly).

```bash
git add claude/skills/herdr-orchestration/references/brief-template.md
git commit -m "herdr: Add contract gates to worker briefs"
```

### Task 8: Final verification (dogfood)

**Files:** none new.

- [ ] **Step 1: Full suites**

Run: `sh claude/hooks/herdr-orch.test.sh && sh claude/hooks/herdr-orch-contract.test.sh && sh claude/hooks/claude-hooks.test.sh`
Expected: every suite ends with zero FAIL.

- [ ] **Step 2: This task's own contract.** The plan phase committed `docs/plans/td-2026-09-01-add-verification-contracts-to-orchestrated-tasks-contract.json`. Run it through the now-implemented verb from the worktree root:

```bash
python3 claude/hooks/herdr_orch_core.py verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-01-add-verification-contracts-to-orchestrated-tasks \
  --worktree "$(pwd)" \
  --contract docs/plans/td-2026-09-01-add-verification-contracts-to-orchestrated-tasks-contract.json \
  --allow-unpinned
```
Expected: `ok` per command, `PASS 2 commands`, exit 0. (Unpinned: the live orchestrator predates pinning; this is gate 1 in its advisory form.)

- [ ] **Step 3: Clean close.** Worktree clean, all commits in place; follow the kickoff brief's close sequence.
