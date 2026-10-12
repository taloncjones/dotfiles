#!/usr/bin/env python3
"""PostToolUse hook: nudge a herdr director that keeps doing task work itself.

Counts the director's own work-shaped tool calls since its last dispatch
and, every HINT_EVERY, adds one line telling it to hand the slice to a
worker or a subagent. Silent, and exit 0, for every other session and on
any error. State: <rd>/delegate-hint.json for the owned repo slug.
"""
import json
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HOOKS = Path(__file__).resolve().parent
sys.path.insert(0, str(HOOKS))

HINT_EVERY = 20
STATE_FILE = "delegate-hint.json"
ADAPTER_WORDS = {"herdr_dispatch.py", "herdr_dispatch_cli.py", "$DISPATCH", "${DISPATCH}"}
CORE_WORDS = {"herdr_orch_core.py", "$CORE", "${CORE}"}
RUNTIME_WORDS = {"agent_runtime.py", "$RUNTIME", "${RUNTIME}"}
ADAPTER_DISPATCH_VERBS = {"launch", "advance", "accept-review", "dispatch-gate", "reprompt"}
CORE_DISPATCH_VERBS = {"run-mech", "run-think"}
NEUTRAL_HEADS = {"cd", "pushd", "popd", "export", "unset", "set", "true", ":", "sleep"}
DISPATCH_TOOLS = {"Agent", "Task", "Workflow"}
WORK_TOOLS = {"Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"}
PATH_TOOLS = {"Read", "Grep", "Glob"}
# A command's class is its highest segment class: a test run next to an
# orchestration call is still work.
RANK = {"other": 0, "orchestration": 1, "work": 2, "dispatch": 3}


def segment_class(words):
    words = rm_guard.strip_prefixes(words)
    if not words or rm_guard.basename(words[0]) in NEUTRAL_HEADS:
        return "other"
    if rm_guard.basename(words[0]) in ("gh", "herdr"):
        return "orchestration"
    for i, word in enumerate(words):
        name = rm_guard.basename(word)
        verb = words[i + 1] if i + 1 < len(words) else ""
        if name in ADAPTER_WORDS:
            return "dispatch" if verb in ADAPTER_DISPATCH_VERBS else "orchestration"
        if name in CORE_WORDS:
            return "dispatch" if verb in CORE_DISPATCH_VERBS else "orchestration"
        if name in RUNTIME_WORDS:
            return "orchestration"
    return "work"


def bash_class(command):
    best = "other"
    for kind, tokens, _previous, _following in guard.segment_groups(rm_guard.tokenize(command)):
        if kind == "seg":
            cls = segment_class(tokens)
            if RANK[cls] > RANK[best]:
                best = cls
    return best


def own_path(value):
    """True for a path under the account roots or the resolved skills dir."""
    if not isinstance(value, str) or not value:
        return False
    path = os.path.realpath(os.path.expanduser(value))
    home = os.path.expanduser("~")
    roots = [os.path.realpath(os.path.join(home, ".claude")),
             os.path.realpath(os.path.join(home, ".claude-work")),
             os.path.realpath(HOOKS.parent / "skills")]
    return any(path == root or path.startswith(root + os.sep) for root in roots)


def call_class(payload):
    tool = payload.get("tool_name")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if tool in DISPATCH_TOOLS:
        return "dispatch"
    if tool in WORK_TOOLS:
        return "work"
    if tool in PATH_TOOLS:
        return "orchestration" if own_path(ti.get("file_path") or ti.get("path")) else "work"
    if tool == "Bash" and isinstance(ti.get("command"), str):
        return bash_class(ti["command"])
    return "other"


def task_label(payload):
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if payload.get("tool_name") != "Bash" or not isinstance(ti.get("command"), str):
        return None
    words = rm_guard.tokenize(ti["command"])
    label = None
    for i, word in enumerate(words[:-1]):
        if word == "--task-id" and core.valid_task_id(words[i + 1]):
            label = words[i + 1]
    return label


def is_director(payload):
    """Cheap gate: runs before any heavy import so other sessions exit fast."""
    return (os.environ.get("HERDR_ENV") == "1" and payload.get("agent_type") == "director"
            and not payload.get("agent_id"))


def load_modules():
    global core, guard, rm_guard
    import herdr_orch_core as core  # noqa: E402
    import orch_edit_guard as guard  # noqa: E402
    import rm_guard  # noqa: E402


def director_rd(payload):
    """The owned slug's state dir for a director session, else None."""
    session, cwd = payload.get("session_id"), payload.get("cwd")
    if not isinstance(session, str) or not isinstance(cwd, str):
        return None
    owned = guard.owned_slugs(session, "claude", guard.selected_scope(cwd, "claude"), {})
    return owned[sorted(owned)[0]]["rd"] if owned else None


def read_state(path, session):
    try:
        rec = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None, 0
    if not isinstance(rec, dict):
        return None, 0
    count = rec.get("count")
    if (rec.get("v") != 1 or rec.get("session_id") != session or not isinstance(count, int)
            or isinstance(count, bool) or count < 0):
        return None, 0
    return (rec.get("task_id") if isinstance(rec.get("task_id"), str) else None), count


def main():
    try:
        payload = json.loads(sys.stdin.read())
        if not isinstance(payload, dict):
            return 0
        if not is_director(payload):
            return 0
        load_modules()
        rd = director_rd(payload)
        if rd is None:
            return 0
        cls, label = call_class(payload), task_label(payload)
        path = Path(rd) / STATE_FILE
        old = read_state(path, payload["session_id"])
        task, count = old
        if label is not None and label != task:
            task, count = label, 0
        if cls == "dispatch":
            count = 0
        elif cls == "work":
            count += 1
        if (task, count) != old or not path.exists():
            core.write_json_atomic(path, {"v": 1, "session_id": payload["session_id"],
                                          "task_id": task, "count": count})
        if cls == "work" and count % HINT_EVERY == 0:
            text = (f"[INFO] herdr: {count} work tool calls on {task or 'this session'} since the "
                    "last dispatch; hand this slice to a worker (a launch or dispatch-gate) or an "
                    "Explore/general-purpose subagent instead of running it here.")
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                                     "additionalContext": text}}))
    except Exception:  # noqa: BLE001 -- advisory hook: never fail the tool call
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
