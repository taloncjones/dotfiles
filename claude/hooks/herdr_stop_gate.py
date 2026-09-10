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
this task id, workspace id, and a valid lifecycle timestamp/outcome. Native
attempts also match the current launch/phase/runtime/pane/source-HEAD tuple,
the provider-selected account, and the current task's repository. Dispatch
pins HERDR_PERSONAL and HERDR_ACCOUNT_ID without changing authentication.
Legacy entries retain the timestamp comparison with their worker launch.
An accepted record allows the stop; controller verification remains required
before treating the task as completed.

Refusal: exit 2 with three stderr lines -- the marker line, the exact
emit-done / emit-review command to run, and a note to stop again. A fresh
stop cycle (stop_hook_active false) is always refused, exactly once --
this is a single nudge, not a counted budget.

Anti-wedge release: stop_hook_active true means this hook already
refused this same stop cycle once, so it releases unconditionally,
self-contained -- it never refuses a second time under the active flag.
The transcript (<config dir>/projects/*/<session_id>.jsonl, lines
containing the marker) is consulted only to word the systemMessage: a
confirmed prior refusal, an unreadable/ambiguous transcript, and a
marker-less transcript each get their own reason string, but all three
release. A release is exit 0 with a systemMessage JSON on stdout.

State reads use nonblocking, no-follow regular-file descriptors. Native
active-stop release happens before any state or Git reads. Reads only;
never writes under the config dir or anywhere else. Fails
open on any exception (exit 0, silent), matching the other guards.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core  # after the path insert; read-only helpers only

GATED_ROLES = ("impl", "review")
ROLE_NAMES = {
    "impl": {"impl", "implementation", "planner", "mechanical"},
    "review": {"review", "reviewer", "skeptic"},
}
RECORD_SUFFIX = {"impl": ".done.json", "review": ".review.json"}
CORE_CMD = 'python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py"'
# Assembled from two pieces so the literal never appears in this file: a
# worker that prints the hook source must not add a transcript match.
MARKER = "herdr-stop-gate" + ": blocked"
SESSION_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z"
)
TS_RE = re.compile(
    r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?\Z"
)


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


def read_json_object(path, root=None):
    """Parsed JSON object at `path`, or None when the path is a symlink,
    not a regular file, outside the state root, unreadable, or not an
    object. Same posture as core.read_index."""
    p = Path(path)
    root = Path(root) if root is not None else core.state_root()
    try:
        p.relative_to(root)
        data = json.loads(core.read_payload_text(p))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def find_index(ws, root=None, slug=None):
    """Resolve exactly one readable index in the selected account/repository."""
    root = Path(root) if root is not None else core.state_root()
    try:
        names = [slug] if slug else sorted(core.payload_names(root))
    except (OSError, ValueError):
        return None, None
    matches = []
    for name in names:
        if not core.valid_repo_slug(name):
            continue
        rd = root / name
        index = read_json_object(rd / "workspaces" / f"{ws}.json", root)
        if index:
            matches.append((rd, index))
    return matches[0] if len(matches) == 1 else (None, None)


def launch_entry(task, ws, role):
    """Last workers[] entry of `task` on workspace `ws` with `role`, else
    None. The role match keeps a later mech entry on the same workspace
    from post-dating the impl worker's own record."""
    if not task or not isinstance(task.get("workers"), list):
        return None
    found = None
    for entry in task["workers"]:
        if isinstance(entry, dict) and entry.get("workspace_id") == ws:
            if entry.get("role") in ROLE_NAMES.get(role, ()):
                found = entry
            elif "runtime" in entry:
                # A malformed newer native attempt cannot revive an old role.
                found = None
    return found


def launch_time(entry):
    """Launch time of a workers[] entry: `started` when the key exists
    (the documented name), else `ts` (what the live orchestrator writes).
    None when absent or unparseable -- unknown never blocks by itself."""
    if not entry:
        return None
    value = entry.get("started") if "started" in entry else entry.get("ts")
    return parse_ts(value)


def record_accepted(rd, task_id, ws, role, entry=None, root=None, task=None):
    """True iff the role's record exists for this task and workspace, its
    `ts` parses, and matches the latest native attempt exactly. Legacy
    entries keep their timestamp-only compatibility behavior."""
    rec = read_json_object(Path(rd) / "tasks" / f"{task_id}{RECORD_SUFFIX[role]}", root)
    if not rec:
        return False
    if rec.get("task_id") != task_id or rec.get("workspace_id") != ws:
        return False
    ts = parse_ts(rec.get("ts"))
    if ts is None:
        return False
    if isinstance(entry, dict) and "runtime" in entry:
        phase = entry.get("phase")
        outcomes = (
            {"approved", "changes-requested"}
            if role == "review"
            else {"completed", "failed", "paused"}
        )
        if rec.get("outcome") not in outcomes:
            return False
        if task is None:
            task = read_json_object(Path(rd) / "tasks" / f"{task_id}.json", root)
        if not isinstance(task, dict):
            return False
        return phase in ("plan", "implement", "review") and core.attempt_matches(
            task, rec, phase, ws
        )
    launch = launch_time(entry)
    return launch is None or ts >= launch


def block_count(session_id, root=None):
    """Refusals already recorded in this session's transcript, or None when
    it cannot be established: unsafe session id, zero or several files
    matching <config dir>/projects/*/<session_id>.jsonl, unreadable."""
    if not isinstance(session_id, str) or not SESSION_ID_RE.match(session_id):
        return None
    base = (Path(root) if root is not None else core.state_root()).parent
    try:
        matches = []
        for name in core.payload_names(base / "projects"):
            path = base / "projects" / name / f"{session_id}.jsonl"
            try:
                matches.append(core.read_payload_text(path))
            except (OSError, ValueError):
                continue
    except (OSError, ValueError):
        return None
    if len(matches) != 1:
        return None
    return sum(1 for line in matches[0].splitlines() if MARKER in line)


def native_scope(
    task,
    entry,
    selected_scope=None,
    root=None,
    runtime=None,
    repository=None,
    personal=None,
):
    """Return the selected account scope and personal switch for a native row.

    A completion must be routed through the account bound at dispatch, never
    through whichever account happened to run the stop hook."""
    if not isinstance(task, dict) or not isinstance(entry, dict):
        return None
    worktree = task.get("worktree")
    entry_runtime = entry.get("runtime")
    account_id = entry.get("account_id")
    if (
        not isinstance(worktree, str)
        or entry_runtime not in ("claude", "codex")
        or runtime is not None
        and runtime != entry_runtime
        or not isinstance(account_id, str)
    ):
        return None
    try:
        context = core.repository_context(worktree)
        if Path(context["root"]).resolve() != Path(worktree).resolve():
            return None
        if repository is not None and context["root"] != repository["root"]:
            return None
        if personal is not None and entry.get("personal") is not personal:
            return None
        scope = selected_scope or core.account_scope(worktree, entry_runtime)
        selected_root = core.account_payload_root(scope) / "herdr-orch"
        if root is not None and selected_root != Path(root):
            return None
        if scope.get("account_id") == account_id:
            return scope, scope.get("kind") == "personal"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return None
    return None


def _head(worktree):
    try:
        head = core.context_git(worktree, "rev-parse", "HEAD")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return head if isinstance(head, str) and core.SHA40_RE.fullmatch(head) else None


def emit_command(rd, index, ws, task, entry, selection=None):
    """Return a shell-safe completion command, or None when identity is unsafe."""
    slug = Path(rd).name
    task_id = index.get("task_id")
    if not core.valid_repo_slug(slug) or not core.valid_task_id(task_id):
        return None
    native = isinstance(entry, dict) and "runtime" in entry
    if native:
        if selection is None:
            return None
        _scope, personal = selection
        worktree = task.get("worktree") if isinstance(task, dict) else None
        required = (
            "runtime",
            "agent",
            "launch_id",
            "pane_id",
            "source_head_sha",
            "phase",
        )
        if not isinstance(worktree, str) or any(
            not isinstance(entry.get(key), str) or not entry[key] for key in required
        ):
            return None
        if (
            entry["runtime"] not in ("claude", "codex")
            or entry["phase"] not in ("plan", "implement", "review")
            or not core.SHA40_RE.fullmatch(entry["source_head_sha"])
        ):
            return None
        head = _head(worktree)
        if head is None:
            return None
        command = [
            "python3",
            str(Path(core.__file__).resolve()),
            "emit-review" if index.get("role") == "review" else "emit-done",
            "--repo-path",
            worktree,
            "--runtime",
            entry["runtime"],
        ]
        if personal:
            command.append("--personal")
        command += [
            "--repo-slug",
            slug,
            "--task-id",
            task_id,
            "--workspace",
            ws,
            "--agent",
            entry["agent"],
            "--launch-id",
            entry["launch_id"],
            "--pane-id",
            entry["pane_id"],
            "--source-head-sha",
            entry["source_head_sha"],
        ]
        if index.get("role") == "review":
            command += [
                "--reviewed-head-sha",
                head,
                "--outcome",
                "<approved|changes-requested>",
                "--blocking-count",
                "<count>",
                "--findings-ref",
                "<path>",
            ]
        else:
            base = task.get("base_sha") if isinstance(task, dict) else None
            if (
                entry["phase"] not in ("plan", "implement")
                or not isinstance(base, str)
                or not core.SHA40_RE.fullmatch(base)
            ):
                return None
            command += [
                "--phase",
                entry["phase"],
                "--outcome",
                "<completed|failed|paused>",
                "--head-sha",
                head,
                "--base-sha",
                base,
            ]
        return shlex.join(command)

    agent = (
        entry.get("agent")
        if entry and isinstance(entry.get("agent"), str) and entry.get("agent")
        else "<agent>"
    )
    agent = shlex.quote(agent)
    if index.get("role") == "review":
        return (
            f"{CORE_CMD} emit-review --repo-slug {slug} --task-id {task_id} "
            f"--workspace {ws} --agent {agent} "
            '--reviewed-head-sha "$(git rev-parse HEAD)" '
            "--outcome '<approved|changes-requested>' --blocking-count '<count>' "
            "--findings-ref '<path>'"
        )
    phase = (
        entry.get("phase")
        if entry and entry.get("phase") in ("plan", "implement")
        else "<phase>"
    )
    base = (
        task.get("base_sha")
        if task and isinstance(task.get("base_sha"), str) and task.get("base_sha")
        else "<base_sha>"
    )
    phase, base = shlex.quote(phase), shlex.quote(base)
    return (
        f"{CORE_CMD} emit-done --repo-slug {slug} --task-id {task_id} "
        f"--workspace {ws} --agent {agent} --phase {phase} "
        "--outcome '<completed|failed|paused>' "
        f'--head-sha "$(git rev-parse HEAD)" --base-sha {base}'
    )


def refuse(command):
    print(
        f"{MARKER} -- emit-done (or emit-review) before stopping; the "
        "orchestrator only recognizes the record.",
        file=sys.stderr,
    )
    print(
        "Run: " + (command or "do not publish; lifecycle identity is unverified"),
        file=sys.stderr,
    )
    print("Then stop again; the gate releases on that attempt.", file=sys.stderr)
    return 2


def release(reason, task_id):
    print(
        json.dumps(
            {
                "systemMessage": f"herdr-stop-gate: released without a completion record "
                f"({reason}); the orchestrator will see idle with no "
                f"record for {task_id}"
            }
        )
    )
    return 0


def evaluate(payload, native=False):
    """Classify a Stop event without emitting runtime-specific hook output."""
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "Stop":
        return {"action": "allow"}
    if native and type(payload.get("stop_hook_active")) is not bool:
        return {"action": "allow"}
    if os.environ.get("HERDR_ENV") != "1":
        return {"action": "allow"}
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return {"action": "allow"}
    if payload.get("stop_hook_active") is True and (
        native or "HERDR_PERSONAL" in os.environ or "HERDR_ACCOUNT_ID" in os.environ
    ):
        # Active bound workers release even when their account metadata breaks.
        return {"action": "release", "reason": "active stop cycle", "task_id": None}
    runtime = "codex" if native else "claude"
    scope = None
    context = None
    root = core.state_root()
    slug = None
    personal = None
    account_id = None
    if "HERDR_PERSONAL" in os.environ or "HERDR_ACCOUNT_ID" in os.environ:
        value = os.environ.get("HERDR_PERSONAL")
        account_id = os.environ.get("HERDR_ACCOUNT_ID")
        if value not in ("0", "1") or not account_id:
            return {
                "action": "refuse",
                "command": None,
                "reason": "lifecycle account metadata is invalid",
                "task_id": None,
            }
        personal = value == "1"
    cwd = payload.get("cwd", os.getcwd() if native else None)
    if cwd is not None:
        if not isinstance(cwd, str) or not cwd:
            return {"action": "allow"}
        try:
            context = core.repository_context(cwd)
            scope = core.account_scope(
                context["root"], runtime, personal=personal is True
            )
            if account_id is not None and account_id != scope["account_id"]:
                return {
                    "action": "refuse",
                    "command": None,
                    "reason": "lifecycle account selection is unverified",
                    "task_id": None,
                }
            root = core.account_payload_root(scope) / "herdr-orch"
            try:
                remote = core.context_git(
                    context["root"], "remote", "get-url", "origin"
                )
            except subprocess.CalledProcessError:
                remote = ""
            slug = core.repo_slug(remote, context["common_dir"])
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            return {"action": "allow"}
    rd, index = find_index(ws, root, slug)
    if index is None:
        return {"action": "allow"}
    role = index.get("role")
    task_id = index.get("task_id")
    if (
        role not in GATED_ROLES
        or not isinstance(task_id, str)
        or not core.valid_task_id(task_id)
    ):
        return {"action": "allow"}
    task = read_json_object(Path(rd) / "tasks" / f"{task_id}.json", root)
    entry = launch_entry(task, ws, role)
    selection = (
        native_scope(task, entry, scope, root, runtime, context, personal)
        if isinstance(entry, dict) and "runtime" in entry
        else None
    )
    workers = task.get("workers", []) if isinstance(task, dict) else []
    strict = (
        native
        or account_id is not None
        or isinstance(workers, list)
        and any(isinstance(worker, dict) and "runtime" in worker for worker in workers)
    )
    if strict and (
        not isinstance(task, dict)
        or task.get("task_id") != task_id
        or task.get("repo_slug") != Path(rd).name
    ):
        selection = None
    if (not strict or selection is not None) and record_accepted(
        rd, task_id, ws, role, entry, root, task
    ):
        return {"action": "allow"}
    if payload.get("stop_hook_active") is True:
        if native:
            return {
                "action": "release",
                "reason": "prior refusal recorded",
                "task_id": task_id,
            }
        count = block_count(payload.get("session_id"), root)
        if count is None:
            return {
                "action": "release",
                "reason": "transcript unavailable",
                "task_id": task_id,
            }
        if count == 0:
            return {
                "action": "release",
                "reason": "transcript evidence missing",
                "task_id": task_id,
            }
        return {
            "action": "release",
            "reason": "prior refusal recorded",
            "task_id": task_id,
        }
    command = (
        None
        if strict and selection is None
        else emit_command(rd, index, ws, task, entry, selection)
    )
    reason = "completion record is missing or does not match the current attempt"
    if strict and selection is None:
        reason = "lifecycle account selection is unverified"
    return {
        "action": "refuse",
        "command": command,
        "reason": reason,
        "task_id": task_id,
    }


def decide(payload):
    """Exit status for one Claude Stop payload: 0 allow/release, 2 refuse."""
    result = evaluate(payload)
    if result["action"] == "allow":
        return 0
    if result["action"] == "release":
        return release(result["reason"], result["task_id"])
    return refuse(result["command"])


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
