# Worker Stop Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Stop` hook that refuses an orchestrated worker's stop until its completion record exists, tells it the exact `emit-done`/`emit-review` line to run, and releases after two refusals, while staying inert for every other session and never writing state.

**Architecture:** One new stdlib-Python hook, `claude/hooks/herdr_stop_gate.py`, modeled on `herdr_worktree_guard.py` (fail-open, exit 2 plus stderr to refuse) and on `herdr_worker_status.py` (workspace index lookup through `herdr_orch_core`). It reads the workspace index, the task record, and the completion record under the herdr state root read-only, counts its own earlier refusals from the session transcript, and prints a filled-in emit command on refusal. Registration is one template entry after the existing Stop hook; tests are appended to `claude-hooks.test.sh`.

**Tech Stack:** Python 3 stdlib only (`json`, `os`, `re`, `sys`, `datetime`, `pathlib`); POSIX `sh` tests with the suite's `PASS`/`FAIL` counters; JSON template; markdown docs.

**Spec:** `docs/specs/2026-09-06-herdr-stop-gate.md`

**Status:** branch-only document; dropped before merge together with the spec. Review gates on 2026-09-06: Codex was out of usage credits until 23:08, so both `codex-spec-review` and `codex-plan-review` were substituted by an independent Opus review with the same prompts (spec: needs-rework, three highs folded; plan: minor-fixes, both criticals folded). Re-run the two Codex reviews before implement dispatch if a second-model pass is wanted. The task contract at `claude/contracts/td-2026-09-06-block-worker-stops-until-the-completion-record-exi-contract.json` stays and is run by the orchestrator at completion.

## Global Constraints

- Files that may change (spec AC10): `claude/hooks/herdr_stop_gate.py` (new), `claude/hooks/claude-hooks.test.sh`, `claude/settings.json.tmpl`, `CLAUDE.md`. Nothing else outside `docs/` and `claude/contracts/`. The contract's `changed-files-within-scope` and `forbidden-files-untouched` commands enforce this; in particular never touch `claude/hooks/herdr_orch_core.py`, `claude/hooks/herdr_worker_status.py`, `claude/skills/herdr-orchestration/`, `claude/skills/co-review/`, `git/hooks/commit-msg`, `install/common/codex-*`.
- The hook never writes: no file under `CLAUDE_CONFIG_DIR`, no counter, no `events.jsonl` line, no subprocess. Reads only (spec D6, AC7).
- Constants, verbatim (spec D4, D5): `MAX_BLOCKS = 2`; marker text `herdr-stop-gate: blocked` assembled from two string pieces so the literal never appears in the source; refusal is exit 2 with exactly three stderr lines; release is exit 0 with one JSON object on stdout carrying `systemMessage`; every other outcome is exit 0 with no output.
- Timestamp parsing: the regex parser of spec D2, never `datetime.fromisoformat` (rejects a trailing `Z` before Python 3.11). Only APIs stable since Python 3.8.
- Stdlib Python only; POSIX sh (no bashisms) in the test suite; must pass on `ubuntu-latest` CI and macOS. Every fixture under `mktemp -d`.
- No emojis, no AI attribution, ASCII only in added lines of the hook, the test suite, and the template (`CLAUDE.md` neighbors use em dashes; match them there). LF endings. Commit format `<scope>: <summary>`, imperative, under 75 chars.
- Test baselines (spec, 2026-09-06 at `682d9db`): sandboxed hooks suite `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh` 77/0; `sh claude/hooks/herdr-orch.test.sh` 106/0; `sh claude/hooks/herdr-orch-contract.test.sh` 65/0. Every task ends with the hooks suite green; Task 4 runs everything plus the contract.
- `claude-hooks.test.sh` runs under `set -e`: every hook invocation that may exit non-zero sits inside an `if` (the existing `hwg: deny is exit 2` check is the pattern); a bare failing pipeline would abort the whole suite.
- Line numbers below were read at main `682d9db`. `talon/claude-codex-parity` edits the `guard_case` region of `claude-hooks.test.sh` (lines 41-100 and 374-480) and may shift numbers; anchor on the quoted neighbor text. All new tests go at the END of the suite, immediately before the two summary lines `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` and `[ "$FAIL" = 0 ]`.

## File Structure

| File | Responsibility |
|---|---|
| `claude/hooks/herdr_stop_gate.py` | The hook: `parse_ts`, `read_json_object`, `find_index`, `launch_entry`, `launch_time`, `record_accepted`, `block_count`, `emit_command`, `refuse`, `release`, `decide`, `main`. |
| `claude/hooks/claude-hooks.test.sh` | `gate_fixture` and `gate_case` helpers plus every `gate:` labelled check, appended before the summary lines. |
| `claude/settings.json.tmpl` | `Stop` group gains the gate after `herdr_worker_status.py`. |
| `CLAUDE.md` | One bullet documenting the hook, after the `herdr_worktree_guard.py` bullet (line 78). |

Task order: 1 hook skeleton with activation, provenance, refusal text; 2 launch time and recency; 3 continuation cap and release; 4 registration, docs, read-only proof, full verification.

## Acceptance criteria to contract mapping

| Spec AC | Task | Contract command(s) |
|---|---|---|
| AC1 refused without record, message shape | 1 | `blocks-worker-without-record` |
| AC2 allowed with fresh record | 1 (2 adds recency) | `allows-worker-with-fresh-record` |
| AC3 stale, foreign, unknown launch, mech entry | 1 (foreign), 2 (rest) | `blocks-stale-record`, `blocks-foreign-workspace-record`, `blocks-foreign-task-record`, `allows-record-when-launch-unknown`, `launch-time-ignores-mech-entry` |
| AC4 role to file | 1 | `review-role-uses-review-record`, `impl-role-ignores-review-record` |
| AC5 non-workers allowed | 1 | `allows-non-worker-sessions` |
| AC6 cap | 3 | `cap-second-block`, `cap-release-after-two`, `cap-release-without-transcript`, `cap-release-on-zero-markers`, `cap-fresh-cycle-blocks-again` |
| AC7 read-only | 4 | `state-root-untouched` |
| AC8 fail-open | 1, 2 | `fails-open-on-bad-input` |
| AC9 registration, suite | 4 | `template-registers-gate-after-status-hook`, `hooks-suite-sandboxed`, `hooks-suite-has-gate-labels`, `orch-suite-unchanged` |
| AC10 docs, scope | 4 | `claude-md-documents-gate`, `changed-files-within-scope`, `forbidden-files-untouched`, `ascii-added-lines`, `hook-compiles-and-executable` |

---

### Task 1: Hook skeleton: activation, record provenance, refusal text

**Files:**
- Create: `claude/hooks/herdr_stop_gate.py`
- Modify: `claude/hooks/claude-hooks.test.sh` (append before the summary lines, currently lines 512-513)

**Interfaces:**
- Consumes from `herdr_orch_core`: `state_root() -> Path`, `read_index(rd, ws) -> dict | None`, `valid_workspace_id(ws) -> bool`, `valid_task_id(tid) -> bool`, `contained(path, root) -> bool`.
- Produces: `read_json_object(path) -> dict | None`; `find_index(ws) -> (Path | None, dict | None)`; `launch_entry(task, ws, role) -> dict | None`; `record_accepted(rd, task_id, ws, role, launch=None) -> bool` (Task 2 adds the `ts` and recency checks); `emit_command(rd, index, ws, task, entry) -> str`; `refuse(n, command) -> int` (returns 2); `decide(payload) -> int`; constants `MAX_BLOCKS`, `MARKER`, `GATED_ROLES`, `RECORD_SUFFIX`, `CORE_CMD`.
- Test helpers: `gate_fixture DIR WS ROLE REC MARKERS`, `gate_case LABEL EXPECT WS ROLE REC MARKERS PAYLOAD [NAME=VALUE...]`, variables `HSG`, `GATE_SID`, `GATE_P_F`, `GATE_LAST` (used by Tasks 2-4).

- [ ] **Step 1: Add the test helpers and the Task 1 cases**

Insert immediately before the line `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` at the end of `claude/hooks/claude-hooks.test.sh`:

```sh
# herdr_stop_gate.py: exit 2 (refuse) when an orchestrated worker stops
# without its completion record, 0 otherwise. Every fixture is a throwaway
# config dir under mktemp with the documented herdr-orch layout; the hook
# must never write into it (checked by the read-only case at the end).
HSG=claude/hooks/herdr_stop_gate.py
GATE_SID=11111111-1111-1111-1111-111111111111
GATE_P_F='{"hook_event_name":"Stop","session_id":"11111111-1111-1111-1111-111111111111","stop_hook_active":false}'
GATE_LAST=

# gate_fixture DIR WS ROLE REC MARKERS
#   ROLE    impl | review | mech | noindex (no workspaces/<ws>.json)
#   REC     comma list: none | notask (no tasks/PROJ-1.json) | dirtask (a
#           directory in its place) | mechentry (a later mech workers[]
#           entry on the same workspace) | <done|review>:<fresh|stale|badts>:<ws>:<task>
#   MARKERS nofile | dup (two transcripts) | N lines in projects/p/<sid>.jsonl
gate_fixture() {
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json,os,sys
root,ws,role,rec,markers=sys.argv[1:6]
SID="11111111-1111-1111-1111-111111111111"
rd=os.path.join(root,"herdr-orch","slug-x")
os.makedirs(os.path.join(rd,"workspaces"));os.makedirs(os.path.join(rd,"tasks"))
parts=rec.split(",")
if role!="noindex":
    json.dump({"task_id":"PROJ-1","repo_slug":"slug-x","role":role},open(os.path.join(rd,"workspaces",ws+".json"),"w"))
if "dirtask" in parts:
    os.makedirs(os.path.join(rd,"tasks","PROJ-1.json"))
elif "notask" not in parts:
    workers=[{"role":"impl","phase":"implement","workspace_id":ws,"agent":"impl-proj-1","ts":"2026-09-06T12:00:00Z"}]
    if role=="review":
        workers.append({"role":"review","phase":"review","workspace_id":ws,"agent":"rev-proj-1","ts":"2026-09-06T12:30:00Z"})
    if "mechentry" in parts:
        workers.append({"role":"mech","phase":"implement","workspace_id":ws,"agent":"mech-proj-1","launch_id":"mech-proj-1-20260906T140000Z","ts":"2026-09-06T14:00:00Z"})
    json.dump({"v":1,"task_id":"PROJ-1","base_sha":"b"*40,"workers":workers},open(os.path.join(rd,"tasks","PROJ-1.json"),"w"))
for spec in parts:
    if spec in ("none","notask","dirtask","mechentry"):
        continue
    kind,when,who,tid=spec.split(":")
    ts={"fresh":"2026-09-06T13:00:00Z","stale":"2026-09-06T11:00:00Z","badts":"2026-09-06 13:00:00"}[when]
    json.dump({"v":1,"task_id":tid,"workspace_id":who,"phase":"implement","outcome":"completed","ts":ts},open(os.path.join(rd,"tasks","PROJ-1."+kind+".json"),"w"))
if markers!="nofile":
    line='{"type":"user","message":{"role":"user","content":"Stop hook feedback: herdr-stop-gate: blocked (1 of 2)"}}\n'
    dirs=["p","q"] if markers=="dup" else ["p"]
    n=1 if markers=="dup" else int(markers)
    for d in dirs:
        os.makedirs(os.path.join(root,"projects",d))
        open(os.path.join(root,"projects",d,SID+".jsonl"),"w").write(line*n)
PY
}

# gate_case LABEL EXPECT WS ROLE REC MARKERS PAYLOAD [NAME=VALUE ...]
#   EXPECT  allow | block-N (refusal number N) | release-<text on stdout>
#   Trailing NAME=VALUE pairs override the environment (HERDR_ENV= unsets
#   the herdr flag for the hook's purposes). GATE_LAST keeps the fixture
#   dir so a caller can inspect out/err afterwards.
gate_case() {
    label="$1"; expect="$2"; ws="$3"; role="$4"; rec="$5"; markers="$6"; payload="$7"; shift 7
    gd=$(mktemp -d)
    gate_fixture "$gd" "$ws" "$role" "$rec" "$markers"
    # The suite runs under set -e: a refusing hook must sit inside an if.
    if printf '%s' "$payload" | env CLAUDE_CONFIG_DIR="$gd" HERDR_ENV=1 HERDR_WORKSPACE_ID="$ws" "$@" "$HSG" >"$gd/out" 2>"$gd/err"; then
        rc=0
    else
        rc=$?
    fi
    ok=0
    case "$expect" in
        allow)
            [ "$rc" = 0 ] && [ ! -s "$gd/out" ] && [ ! -s "$gd/err" ] && ok=1 ;;
        block-*)
            [ "$rc" = 2 ] && [ ! -s "$gd/out" ] && [ "$(wc -l <"$gd/err" | tr -d ' ')" = 3 ] \
                && head -n 1 "$gd/err" | grep -q "^herdr-stop-gate: blocked (${expect#block-} of 2) -- emit-done (or emit-review) before stopping; the orchestrator only recognizes the record\.$" \
                && sed -n 3p "$gd/err" | grep -q '^Then stop again\. The gate releases after 2 blocks even without a record\.$' \
                && ok=1 ;;
        release-*)
            [ "$rc" = 0 ] && [ ! -s "$gd/err" ] && grep -q 'herdr-stop-gate: released' "$gd/out" \
                && grep -q "${expect#release-}" "$gd/out" && ok=1 ;;
    esac
    if [ "$ok" = 1 ]; then
        printf 'PASS  gate: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  gate: %s (rc=%s out=%s err=%s)\n' "$label" "$rc" "$(cat "$gd/out")" "$(head -n 1 "$gd/err")" >&2
        FAIL=$((FAIL + 1))
    fi
    GATE_LAST="$gd"
}

gate_case "impl worker without record is refused" block-1 w1 impl none nofile "$GATE_P_F"
if sed -n 2p "$GATE_LAST/err" | grep -Fxq 'Run: python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-done --repo-slug slug-x --task-id PROJ-1 --workspace w1 --agent impl-proj-1 --phase implement --outcome completed|failed|paused --head-sha "$(git rev-parse HEAD)" --base-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; then
    printf 'PASS  gate: refusal prints the filled emit-done line\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: refusal prints the filled emit-done line (got: %s)\n' "$(sed -n 2p "$GATE_LAST/err")" >&2; FAIL=$((FAIL + 1))
fi
gate_case "impl worker with own fresh record is allowed" allow w1 impl done:fresh:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "record from another workspace is refused" block-1 w1 impl done:fresh:w9:PROJ-1 nofile "$GATE_P_F"
gate_case "record for another task is refused" block-1 w1 impl done:fresh:w1:PROJ-2 nofile "$GATE_P_F"
gate_case "review worker is refused by a done record" block-1 w1 review done:fresh:w1:PROJ-1 nofile "$GATE_P_F"
if sed -n 2p "$GATE_LAST/err" | grep -Fxq 'Run: python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w1 --agent rev-proj-1 --reviewed-head-sha "$(git rev-parse HEAD)" --outcome approved|changes-requested --blocking-count <n> --findings-ref <path>'; then
    printf 'PASS  gate: review refusal prints the filled emit-review line\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: review refusal prints the filled emit-review line (got: %s)\n' "$(sed -n 2p "$GATE_LAST/err")" >&2; FAIL=$((FAIL + 1))
fi
gate_case "review worker with review record is allowed" allow w1 review review:fresh:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "impl worker is refused by a review record alone" block-1 w1 impl review:fresh:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "missing task record prints placeholders" block-1 w1 impl notask nofile "$GATE_P_F"
if sed -n 2p "$GATE_LAST/err" | grep -Fq -- '--agent <agent> --phase <phase> --outcome completed|failed|paused --head-sha "$(git rev-parse HEAD)" --base-sha <base_sha>'; then
    printf 'PASS  gate: placeholders stand in for missing task record fields\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: placeholders stand in for missing task record fields (got: %s)\n' "$(sed -n 2p "$GATE_LAST/err")" >&2; FAIL=$((FAIL + 1))
fi
gate_case "no HERDR_ENV is allowed" allow w1 impl none nofile "$GATE_P_F" HERDR_ENV=
gate_case "no index for the workspace is allowed" allow w1 noindex none nofile "$GATE_P_F"
gate_case "invalid workspace id is allowed" allow ..x impl none nofile "$GATE_P_F"
gate_case "mech role is allowed" allow w1 mech none nofile "$GATE_P_F"
gate_case "non-Stop payload is allowed" allow w1 impl none nofile '{"hook_event_name":"Notification","notification_type":"permission_prompt"}'
gate_case "non-JSON stdin is allowed" allow w1 impl none nofile 'not json'
gate_case "JSON array stdin is allowed" allow w1 impl none nofile '[]'
```

Note the `review` fixture appends a second `workers[]` entry with role `review`, agent `rev-proj-1`, so the review refusal quotes that agent; the impl entry stays first. `gate_fixture` writes `..x.json` for the invalid-id case, which is harmless because the hook rejects the id before looking.

- [ ] **Step 2: Run the suite to see the new cases fail**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: every `gate:` line is `FAIL` (the hook file does not exist, so each run exits 127), summary `77 passed, 18 failed`.

- [ ] **Step 3: Write the hook**

Create `claude/hooks/herdr_stop_gate.py` (then `chmod +x`):

```python
#!/usr/bin/env python3
"""Stop hook: refuse an orchestrated worker's stop until its completion
record exists.

A worker's brief says "run emit-done, then stop", but nothing enforced it:
a worker that forgot, hit a denied action, or ran out of context went idle
with no record and the orchestrator had to inspect the pane by hand. This
hook makes the record structural. It is inert unless ALL hold: the payload
is a Stop event, HERDR_ENV=1, HERDR_WORKSPACE_ID is a safe id, a workspace
index under STATE_ROOT resolves it, and the index role is impl or review.
Orchestrator sessions, plain sessions, and headless mech/think runs (which
inherit the orchestrator's workspace id, never indexed) are never gated.

Gate: tasks/<task_id>.done.json (impl) or .review.json (review) must carry
this task id and workspace id and a `ts` at or after the worker's launch
time (the last workers[] entry on this workspace with this role in
tasks/<task_id>.json; unknown launch time skips the recency test). An
accepted record allows the stop silently.

Refusal: exit 2 with three stderr lines -- the marker line with the
refusal number, the exact emit-done / emit-review command to run, and the
release rule. Continuation cap: earlier refusals are counted read-only
from the session transcript (<config dir>/projects/*/<session_id>.jsonl,
lines containing the marker). With stop_hook_active true, a count of
MAX_BLOCKS releases (cap reached); an unreadable, ambiguous, or
marker-less transcript also releases, so the gate never refuses more than
MAX_BLOCKS times in a row whatever the transcript does. A release is exit
0 with a systemMessage JSON on stdout. A fresh stop cycle
(stop_hook_active false) is always refused once.

Reads only; never writes under the config dir or anywhere else. Fails
open on any exception (exit 0, silent), matching the other guards.
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core  # after the path insert; read-only helpers only

MAX_BLOCKS = 2
GATED_ROLES = ("impl", "review")
RECORD_SUFFIX = {"impl": ".done.json", "review": ".review.json"}
CORE_CMD = "python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py"
# Assembled from two pieces so the literal never appears in this file: a
# worker that prints the hook source must not add a transcript match.
MARKER = "herdr-stop-gate" + ": blocked"
SESSION_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
TS_RE = re.compile(
    r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?\Z")



def read_json_object(path):
    """Parsed JSON object at `path`, or None when the path is a symlink,
    not a regular file, outside the state root, unreadable, or not an
    object. Same posture as core.read_index."""
    p = Path(path)
    try:
        if p.is_symlink() or not p.is_file() \
                or not core.contained(p, core.state_root()):
            return None
        with open(p) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def find_index(ws):
    """(repo_dir, index) for the first readable workspace index in sorted
    path order, else (None, None). The repo dir is derived from the index
    path, never from payload data."""
    try:
        candidates = sorted(core.state_root().glob(f"*/workspaces/{ws}.json"))
    except OSError:
        return None, None
    for idx in candidates:
        rd = idx.parent.parent
        index = core.read_index(rd, ws)
        if index:
            return rd, index
    return None, None


def launch_entry(task, ws, role):
    """Last workers[] entry of `task` on workspace `ws` with `role`, else
    None. The role match keeps a later mech entry on the same workspace
    from post-dating the impl worker's own record."""
    if not task or not isinstance(task.get("workers"), list):
        return None
    found = None
    for entry in task["workers"]:
        if isinstance(entry, dict) and entry.get("workspace_id") == ws \
                and entry.get("role") == role:
            found = entry
    return found


def record_accepted(rd, task_id, ws, role, launch=None):
    """True iff the role's record exists for this task and workspace."""
    rec = read_json_object(Path(rd) / "tasks" / f"{task_id}{RECORD_SUFFIX[role]}")
    if not rec:
        return False
    return rec.get("task_id") == task_id and rec.get("workspace_id") == ws


def emit_command(rd, index, ws, task, entry):
    """The exact emit-done (impl) or emit-review (review) line for this
    worker; fields the task record lacks stay literal <placeholders>."""
    slug = Path(rd).name
    task_id = index["task_id"]
    agent = entry.get("agent") if entry and isinstance(entry.get("agent"), str) \
        and entry.get("agent") else "<agent>"
    if index["role"] == "review":
        return (f"{CORE_CMD} emit-review --repo-slug {slug} --task-id {task_id} "
                f"--workspace {ws} --agent {agent} "
                f"--reviewed-head-sha \"$(git rev-parse HEAD)\" "
                f"--outcome approved|changes-requested --blocking-count <n> "
                f"--findings-ref <path>")
    phase = "<phase>"
    if entry and entry.get("phase") in ("plan", "implement"):
        phase = entry["phase"]
    base = task.get("base_sha") if task and isinstance(task.get("base_sha"), str) \
        and task.get("base_sha") else "<base_sha>"
    return (f"{CORE_CMD} emit-done --repo-slug {slug} --task-id {task_id} "
            f"--workspace {ws} --agent {agent} --phase {phase} "
            f"--outcome completed|failed|paused "
            f"--head-sha \"$(git rev-parse HEAD)\" --base-sha {base}")


def refuse(n, command):
    print(f"{MARKER} ({n} of {MAX_BLOCKS}) -- emit-done (or emit-review) before "
          "stopping; the orchestrator only recognizes the record.", file=sys.stderr)
    print("Run: " + command, file=sys.stderr)
    print(f"Then stop again. The gate releases after {MAX_BLOCKS} blocks even "
          "without a record.", file=sys.stderr)
    return 2


def decide(payload):
    """Exit status for one Stop payload: 0 allow/release, 2 refuse."""
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "Stop":
        return 0
    if os.environ.get("HERDR_ENV") != "1":
        return 0
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return 0
    rd, index = find_index(ws)
    if index is None:
        return 0
    role = index.get("role")
    task_id = index.get("task_id")
    if role not in GATED_ROLES or not isinstance(task_id, str) \
            or not core.valid_task_id(task_id):
        return 0
    task = read_json_object(Path(rd) / "tasks" / f"{task_id}.json")
    entry = launch_entry(task, ws, role)
    if record_accepted(rd, task_id, ws, role):
        return 0
    return refuse(1, emit_command(rd, index, ws, task, entry))


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    return decide(payload)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: never trap a worker
        sys.exit(0)
```

Then: `chmod +x claude/hooks/herdr_stop_gate.py`.

- [ ] **Step 4: Run the suite to see the Task 1 cases pass**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: 18 `PASS  gate:` lines, summary `95 passed, 0 failed`.

- [ ] **Step 5: Syntax and lint**

Run: `python3 -m py_compile claude/hooks/herdr_stop_gate.py && sh -n claude/hooks/claude-hooks.test.sh && ruff check --isolated --select E,F,W --ignore E402 claude/hooks/herdr_stop_gate.py`
Expected: no output from the first two; ruff reports `All checks passed!`. `--isolated` skips this machine's user-level ruff config (it flags the existing hooks too, so it is not a repo gate); `E402` is the deliberate import after the `sys.path` insert, the same shape as `herdr_worker_status.py`. Lines stay within 88 columns.

- [ ] **Step 6: Commit**

```bash
git add claude/hooks/herdr_stop_gate.py claude/hooks/claude-hooks.test.sh
git commit -m "hooks: Add herdr stop gate refusing worker stops without a record"
```

---

### Task 2: Launch time and recency

**Files:**
- Modify: `claude/hooks/herdr_stop_gate.py` (`parse_ts`, new `launch_time`, `record_accepted`, `decide`)
- Modify: `claude/hooks/claude-hooks.test.sh` (append after the Task 1 cases, before the summary lines)

**Interfaces:**
- Consumes: Task 1's `launch_entry`, `record_accepted`, `gate_case`, `GATE_P_F`.
- Produces: `parse_ts(value) -> datetime | None` (tz-aware UTC, new in this task together with the `datetime` import); `launch_time(entry) -> datetime | None`; `record_accepted(rd, task_id, ws, role, launch)` now also requires a parseable `ts` and, when `launch` is not None, `ts >= launch`.

- [ ] **Step 1: Add the Task 2 cases**

Insert after the last Task 1 `gate_case` line (`JSON array stdin is allowed`):

```sh
gate_case "stale record from before launch is refused" block-1 w1 impl done:stale:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "record with unparseable ts is refused" block-1 w1 impl done:badts:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "record accepted when launch time is unknown" allow w1 impl notask,done:fresh:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "unreadable task record makes launch unknown" allow w1 impl dirtask,done:fresh:w1:PROJ-1 nofile "$GATE_P_F"
gate_case "unreadable task record still refuses without record" block-1 w1 impl dirtask nofile "$GATE_P_F"
gate_case "later mech entry does not move the launch time" allow w1 impl mechentry,done:fresh:w1:PROJ-1 nofile "$GATE_P_F"
if python3 - <<'PY'
import importlib.util
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("g", "claude/hooks/herdr_stop_gate.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
utc = timezone.utc
assert g.parse_ts("2026-09-06T18:38:51Z") == datetime(2026, 9, 6, 18, 38, 51, tzinfo=utc)
assert g.parse_ts("2026-09-06T18:38:51") == datetime(2026, 9, 6, 18, 38, 51, tzinfo=utc)
assert g.parse_ts("2026-09-06T18:38:51.921Z") == datetime(2026, 9, 6, 18, 38, 51, tzinfo=utc)
assert g.parse_ts("2026-09-06T18:38:51+02:00") == datetime(2026, 9, 6, 16, 38, 51, tzinfo=utc)
assert g.parse_ts("2026-09-06T18:38:51-0130") == datetime(2026, 9, 6, 20, 8, 51, tzinfo=utc)
for bad in ("2026-09-06", "2026-09-06 18:38:51Z", "", None, 5, "2026-13-06T18:38:51Z", "2026-09-06T18:38:51Zx"):
    assert g.parse_ts(bad) is None, bad
assert g.launch_time({"started": "2026-09-06T12:00:00Z", "ts": "2026-09-06T13:00:00Z"}) == datetime(2026, 9, 6, 12, 0, 0, tzinfo=utc)
assert g.launch_time({"started": "garbage", "ts": "2026-09-06T13:00:00Z"}) is None
assert g.launch_time({"ts": "2026-09-06T13:00:00Z"}) == datetime(2026, 9, 6, 13, 0, 0, tzinfo=utc)
assert g.launch_time({}) is None and g.launch_time(None) is None
PY
then
    printf 'PASS  gate: parse_ts and launch_time follow the spec parser\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: parse_ts and launch_time follow the spec parser\n' >&2; FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the suite to see them fail**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: `FAIL` for `stale record from before launch is refused`, `record with unparseable ts is refused`, and `parse_ts and launch_time follow the spec parser` (AttributeError: no `launch_time`); the other four new cases already pass (provenance alone accepts them); summary `99 passed, 3 failed`.

- [ ] **Step 3: Implement the parser and recency**

Add the import line `from datetime import datetime, timedelta, timezone` directly after `import sys` (Task 1 left it out so ruff's unused-import check stayed green). Then add `parse_ts` directly before `read_json_object`:

```python
def parse_ts(value):
    """UTC datetime for `YYYY-MM-DDTHH:MM:SS[.fff][Z|+HH:MM|-HHMM]`, else
    None. Not datetime.fromisoformat: that rejects a trailing Z before
    Python 3.11 and core.now_iso always writes one."""
    if not isinstance(value, str):
        return None
    m = TS_RE.match(value)
    if not m:
        return None
    try:
        dt = datetime(*(int(g) for g in m.groups()[:6]), tzinfo=timezone.utc)
    except ValueError:
        return None
    tz = m.group(7)
    if tz and tz != "Z":
        digits = tz[1:].replace(":", "")
        offset = timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
        dt = dt - offset if tz[0] == "+" else dt + offset
    return dt
```

Add after `launch_entry`:

```python
def launch_time(entry):
    """Launch time of a workers[] entry: `started` when the key exists
    (the documented name), else `ts` (what the live orchestrator writes).
    None when absent or unparseable -- unknown never blocks by itself."""
    if not entry:
        return None
    value = entry.get("started") if "started" in entry else entry.get("ts")
    return parse_ts(value)
```

Replace `record_accepted`:

```python
def record_accepted(rd, task_id, ws, role, launch=None):
    """True iff the role's record exists for this task and workspace, its
    `ts` parses, and (when the launch time is known) `ts` is not before
    it. Second resolution, equality accepted, no tolerance: any window
    wide enough to matter would re-accept the previous phase's record."""
    rec = read_json_object(Path(rd) / "tasks" / f"{task_id}{RECORD_SUFFIX[role]}")
    if not rec:
        return False
    if rec.get("task_id") != task_id or rec.get("workspace_id") != ws:
        return False
    ts = parse_ts(rec.get("ts"))
    if ts is None:
        return False
    return launch is None or ts >= launch
```

In `decide`, replace `if record_accepted(rd, task_id, ws, role):` with:

```python
    if record_accepted(rd, task_id, ws, role, launch_time(entry)):
```

- [ ] **Step 4: Run the suite to see them pass**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: 25 `PASS  gate:` lines, summary `102 passed, 0 failed`.

- [ ] **Step 5: Lint and commit**

Run: `python3 -m py_compile claude/hooks/herdr_stop_gate.py && ruff check --isolated --select E,F,W --ignore E402 claude/hooks/herdr_stop_gate.py && sh -n claude/hooks/claude-hooks.test.sh`
Expected: `All checks passed!`, nothing else.

```bash
git add claude/hooks/herdr_stop_gate.py claude/hooks/claude-hooks.test.sh
git commit -m "hooks: Gate stops on record recency against the worker launch time"
```

---

### Task 3: Continuation cap and release

**Files:**
- Modify: `claude/hooks/herdr_stop_gate.py` (new `block_count`, `release`; `decide`)
- Modify: `claude/hooks/claude-hooks.test.sh` (append after the Task 2 cases)

**Interfaces:**
- Consumes: Task 1's `refuse`, `emit_command`, `decide`; `gate_case`, `gate_fixture` MARKERS modes `N`, `nofile`, `dup`.
- Produces: `block_count(session_id) -> int | None`; `release(reason, task_id) -> int` (returns 0); `decide` implements the spec D4 table.

- [ ] **Step 1: Add the Task 3 cases**

Insert after the `parse_ts and launch_time follow the spec parser` block:

```sh
GATE_P_T='{"hook_event_name":"Stop","session_id":"11111111-1111-1111-1111-111111111111","stop_hook_active":true}'
gate_case "second refusal counts the transcript" block-2 w1 impl none 1 "$GATE_P_T"
gate_case "released after two refusals" "release-cap reached" w1 impl none 2 "$GATE_P_T"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); m=d.get("systemMessage"); sys.exit(0 if isinstance(m, str) and "PROJ-1" in m and list(d) == ["systemMessage"] else 1)' "$GATE_LAST/out"; then
    printf 'PASS  gate: release is one systemMessage object naming the task\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: release is one systemMessage object naming the task (got: %s)\n' "$(cat "$GATE_LAST/out")" >&2; FAIL=$((FAIL + 1))
fi
gate_case "released when transcript is missing" "release-transcript unavailable" w1 impl none nofile "$GATE_P_T"
gate_case "released when transcript has no marker" "release-transcript evidence missing" w1 impl none 0 "$GATE_P_T"
gate_case "released when two transcripts match the session" "release-transcript unavailable" w1 impl none dup "$GATE_P_T"
gate_case "released when the session id is unsafe" "release-transcript unavailable" w1 impl none 2 '{"hook_event_name":"Stop","session_id":"../x","stop_hook_active":true}'
gate_case "fresh cycle is refused again after a release" block-3 w1 impl none 2 "$GATE_P_F"
gate_case "active hook with a fresh record is allowed silently" allow w1 impl done:fresh:w1:PROJ-1 2 "$GATE_P_T"
gate_case "stop_hook_active must be boolean true to release" block-3 w1 impl none 2 '{"hook_event_name":"Stop","session_id":"11111111-1111-1111-1111-111111111111","stop_hook_active":"true"}'
```

The last case pins the type check: a string `"true"` is not the platform's boolean, so the hook treats it as a fresh cycle and refuses; the transcript already holds two markers, hence refusal number 3.

- [ ] **Step 2: Run the suite to see them fail**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: `FAIL` for `second refusal counts the transcript` (prints `(1 of 2)`), all four `released ...` cases and the systemMessage check (exit 2 instead of 0), and both `block-3` cases (print `(1 of 2)`); `active hook with a fresh record` passes; summary `103 passed, 9 failed`.

- [ ] **Step 3: Implement the cap**

Add after `record_accepted`:

```python
def block_count(session_id):
    """Refusals already recorded in this session's transcript, or None when
    it cannot be established: unsafe session id, zero or several files
    matching <config dir>/projects/*/<session_id>.jsonl, unreadable."""
    if not isinstance(session_id, str) or not SESSION_ID_RE.match(session_id):
        return None
    base = core.state_root().parent  # the config dir itself, not herdr-orch
    try:
        matches = list(base.glob(f"projects/*/{session_id}.jsonl"))
    except OSError:
        return None
    if len(matches) != 1:
        return None
    try:
        with open(matches[0], errors="replace") as f:
            return sum(1 for line in f if MARKER in line)
    except OSError:
        return None
```

Add after `refuse`:

```python
def release(reason, task_id):
    print(json.dumps({
        "systemMessage": f"herdr-stop-gate: released without a completion record "
                         f"({reason}); the orchestrator will see idle with no "
                         f"record for {task_id}"}))
    return 0
```

Replace the tail of `decide` (from `if record_accepted(...)` to the end) with:

```python
    if record_accepted(rd, task_id, ws, role, launch_time(entry)):
        return 0
    count = block_count(payload.get("session_id"))
    if payload.get("stop_hook_active") is True:
        # Each release row below is a loop backstop: an active stop hook
        # proves a refusal already happened, so no countable evidence means
        # the transcript is not recording the marker and the cap can never
        # be reached by counting. Never refuse more than MAX_BLOCKS in a row.
        if count is None:
            return release("transcript unavailable", task_id)
        if count == 0:
            return release("transcript evidence missing", task_id)
        if count >= MAX_BLOCKS:
            return release("cap reached", task_id)
    return refuse((count or 0) + 1, emit_command(rd, index, ws, task, entry))
```

- [ ] **Step 4: Run the suite to see them pass**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: 35 `PASS  gate:` lines, summary `112 passed, 0 failed`.

- [ ] **Step 5: Lint and commit**

Run: `python3 -m py_compile claude/hooks/herdr_stop_gate.py && ruff check --isolated --select E,F,W --ignore E402 claude/hooks/herdr_stop_gate.py && sh -n claude/hooks/claude-hooks.test.sh`
Expected: `All checks passed!`, nothing else.

```bash
git add claude/hooks/herdr_stop_gate.py claude/hooks/claude-hooks.test.sh
git commit -m "hooks: Release the stop gate after two refusals counted from the transcript"
```

---

### Task 4: Registration, docs, read-only proof, full verification

**Files:**
- Modify: `claude/settings.json.tmpl:226` (the `Stop` group)
- Modify: `CLAUDE.md:78` (insert one bullet after the `herdr_worktree_guard.py` bullet)
- Modify: `claude/hooks/claude-hooks.test.sh` (append after the Task 3 cases)

**Interfaces:**
- Consumes: everything above; the existing live drift check (`settings: ... registers every template hook`) picks the new command up unchanged.
- Produces: nothing new in code; the template and doc lines the contract greps for.

- [ ] **Step 1: Add the registration and read-only cases**

Insert after the `stop_hook_active must be boolean true to release` case:

```sh
# Static registration: the template's Stop group is one `*` matcher listing
# the status hook then the gate. Order is documentary (a group's hooks run
# in parallel) but pinned so an edit cannot drop or reorder the pair.
if python3 - <<'PY'
import json
import sys

group = json.load(open("claude/settings.json.tmpl"))["hooks"]["Stop"]
cmds = [h["command"] for e in group for h in e["hooks"]]
sys.exit(0 if cmds == ["~/.claude/hooks/herdr_worker_status.py",
                        "~/.claude/hooks/herdr_stop_gate.py"]
         and [e.get("matcher") for e in group] == ["*"] else 1)
PY
then
    printf 'PASS  gate: template lists the Stop hooks in order, gate last\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: template lists the Stop hooks in order, gate last\n' >&2; FAIL=$((FAIL + 1))
fi

# Read-only: a content hash of the whole fixture config dir is identical
# after a refusal, a counted refusal, a release, and an allow.
gd=$(mktemp -d)
gate_fixture "$gd" w1 impl done:stale:w1:PROJ-1 1
gate_snapshot() {
    python3 - "$1" <<'PY'
import hashlib,os,sys
root=sys.argv[1]
for dp,dn,fn in os.walk(root):
    for f in sorted(fn):
        if f in ("out","err"): continue
        p=os.path.join(dp,f)
        print(os.path.relpath(p,root), hashlib.sha256(open(p,"rb").read()).hexdigest())
PY
}
before=$(gate_snapshot "$gd")
gate_run() {   # payload -> exit status, without tripping set -e
    if printf '%s' "$1" | env CLAUDE_CONFIG_DIR="$gd" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 "$HSG" >"$gd/out" 2>"$gd/err"; then
        echo 0
    else
        echo $?
    fi
}
rc1=$(gate_run "$GATE_P_F")
rc2=$(gate_run "$GATE_P_T")
rc3=$(gate_run "$GATE_P_T")
after=$(gate_snapshot "$gd")
if [ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$rc3" = 2 ] && [ -n "$before" ] && [ "$before" = "$after" ]; then
    printf 'PASS  gate: hook leaves the config dir byte-identical\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  gate: hook leaves the config dir byte-identical (rc=%s/%s/%s)\n' "$rc1" "$rc2" "$rc3" >&2; FAIL=$((FAIL + 1))
fi
```

The three runs are: fresh cycle (refusal 1), active hook with one marker (refusal 2), and the same again (still refusal 2: the transcript is a fixture and does not grow). A release run would print to stdout only; it is exercised in Task 3, and the snapshot skips the `out`/`err` capture files by name.

- [ ] **Step 2: Run the suite to see the registration case fail**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: `FAIL  gate: template lists the Stop hooks in order, gate last`; the read-only case passes; summary `113 passed, 1 failed`.

- [ ] **Step 3: Register the hook in the template**

In `claude/settings.json.tmpl`, replace the `Stop` group line

```json
    "Stop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "~/.claude/hooks/herdr_worker_status.py" } ] }
    ],
```

with

```json
    "Stop": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/herdr_worker_status.py" },
        { "type": "command", "command": "~/.claude/hooks/herdr_stop_gate.py" }
      ] }
    ],
```

Leave the `Notification` group as it is.

- [ ] **Step 4: Document the hook in CLAUDE.md**

Insert after the `herdr_worktree_guard.py` bullet (line 78) this single bullet (the em dash matches its neighbors; `CLAUDE.md` is exempt from the ASCII check):

```markdown
- `claude/hooks/herdr_stop_gate.py` — Stop hook that refuses an orchestrated worker's stop (`HERDR_ENV=1` and a workspace index with role `impl` or `review`) until `tasks/<task_id>.done.json` (or `.review.json` for a reviewer) for that workspace is dated at or after the worker's launch, printing the exact `emit-done`/`emit-review` line to run; releases after 2 refusals, counted read-only from the session transcript, so a worker that cannot emit still hands back; never writes state and is inert for every other session (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)
```

- [ ] **Step 5: Run the suite to see everything pass**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'gate:|passed'`
Expected: 37 `PASS  gate:` lines, summary `114 passed, 0 failed`.

Run unsandboxed once to see the live drift check react: `sh claude/hooks/claude-hooks.test.sh 2>&1 | grep 'settings:'`
Expected on this machine: `FAIL  settings: /Users/talon/.claude missing template hooks (run update to reconcile)` (and the same for `.claude-work`) listing `Stop: ~/.claude/hooks/herdr_stop_gate.py`. That is the intended signal; `update` reconciles after merge. Do NOT run `update` from the worktree.

- [ ] **Step 6: Run every suite and the contract**

Run: `bash bin/dotfiles-tests 2>&1 | tail -4`
Expected: `=== dotfiles-tests: 20 suites passed, 0 failed` when run with `HOME` sandboxed for the hooks suite; unsandboxed, only the two live-settings drift lines above fail and only inside `claude/hooks/claude-hooks.test.sh`. Run `HOME="$(mktemp -d)" bash bin/dotfiles-tests` to see the clean verdict (the other suites do not depend on `HOME`).

Run: `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 --task-id td-2026-09-06-block-worker-stops-until-the-completion-record-exi --worktree "$PWD" --contract claude/contracts/td-2026-09-06-block-worker-stops-until-the-completion-record-exi-contract.json --allow-unpinned`
Expected: `ok <name> exit=0` for all 26 commands then `PASS 26 commands`, exit 0. Run it AFTER the Step 7 commit so the `changed-files-within-scope` diff sees the final tree (it compares committed `HEAD` with `682d9db`).

- [ ] **Step 7: Commit**

```bash
git add claude/settings.json.tmpl CLAUDE.md claude/hooks/claude-hooks.test.sh
git commit -m "config: Register the herdr stop gate and document it"
```

Then re-run the contract command from Step 6 and confirm `PASS 26 commands`.

---

## Re-anchoring after the parity merge

The implement phase runs after `talon/claude-codex-parity` merges. It rewrites the `guard_case` helper and the fixture-driven `guard:` cases in `claude-hooks.test.sh` and touches `account_guard.py`, `herdr_worktree_guard.py`, and the template `env` block. None of that overlaps this plan: all new test code goes after the last `settings:` loop, immediately before the two summary lines, and the `Stop` group and `CLAUDE.md` line 78 are untouched by parity. If line numbers drift, search for `printf '\n%d passed, %d failed\n'` (test insertion point), `"Stop": [` (template), and `herdr_worktree_guard.py` (the CLAUDE.md bullet to insert after). Re-record the hooks-suite baseline after the merge: the counts above assume 77 sandboxed checks at `682d9db`; parity adds guard cases, so add its delta to every expected total.

## Verification gaps to name at the close

- `systemMessage` on a Stop hook's exit-0 stdout is asserted from the hooks reference, not demonstrated live; the tests pin the JSON shape only. A live check is one refused stop in a real worker pane after `update`.
- The transcript location for the work account (`~/.claude-work/projects/`) is inferred from the personal-account probe; the personal path was confirmed live on 2026-09-06.
