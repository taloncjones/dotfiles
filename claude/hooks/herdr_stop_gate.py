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
from datetime import datetime, timedelta, timezone
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


def launch_time(entry):
    """Launch time of a workers[] entry: `started` when the key exists
    (the documented name), else `ts` (what the live orchestrator writes).
    None when absent or unparseable -- unknown never blocks by itself."""
    if not entry:
        return None
    value = entry.get("started") if "started" in entry else entry.get("ts")
    return parse_ts(value)


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
    if record_accepted(rd, task_id, ws, role, launch_time(entry)):
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
