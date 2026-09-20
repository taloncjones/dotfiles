#!/usr/bin/env python3
"""SessionStart hook: list saved handoffs for the current repository.

Runs the handoff helper's `list` for the session's cwd and prints one line per
ready record (task, role, parent, first brief line) and a kickoff hint, so a
cleared, compacted, resumed, or restarted session can pick its task back up
without the user restating it. It never attaches the session to a record,
never selects one, and does not know whether another session already holds
a task; the user still runs kickoff with an explicit task ID.

Advisory only: every failure path (no repository, no state, helper missing,
helper timeout, malformed payload) exits 0 silently. Uses the account scope
the helper derives from the repository; a deliberate --personal override in a
work repository is not visible here, so those records are listed by running
the helper by hand.

This hook runs the helper with the session's own python3 (via sys.executable),
so the notice depends on that interpreter being 3.11 or newer and otherwise
silently does not appear, the same dependency the other SessionStart hooks
that import workflow_context already have.
"""

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "skills" / "handoff" / "scripts" / "handoff.py"
TIMEOUT_SECS = 5
MAX_RECORDS = 10


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError, ValueError):
        payload = {}
    cwd = payload.get("cwd") if isinstance(payload, dict) else None
    cwd = cwd or os.getcwd()
    if not HELPER.is_file():
        return 0
    try:
        result = subprocess.run(
            [sys.executable, str(HELPER), "list", "--repo", cwd, "--runtime", "claude"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECS,
            check=False,
        )
        data = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0
    tasks = data.get("tasks") if isinstance(data, dict) else None
    if not isinstance(tasks, list):
        return 0
    ready = [
        task
        for task in tasks
        if isinstance(task, dict)
        and task.get("status") == "ready"
        and isinstance(task.get("task_id"), str)
    ]
    ready.sort(key=lambda task: str(task.get("created_at", "")), reverse=True)
    lines = []
    for task in ready[:MAX_RECORDS]:
        task_id = task["task_id"]
        role = task.get("role")
        parent = task.get("parent")
        tag = role if isinstance(role, str) else "no role"
        if isinstance(parent, str):
            tag = f"{tag} of {parent}"
        created = task.get("created_at")
        day = ""
        if isinstance(created, str):
            try:
                day = datetime.fromisoformat(created).date().isoformat() + " "
            except ValueError:
                day = ""
        summary = task.get("summary")
        summary = summary if isinstance(summary, str) else ""
        lines.append(f"  {task_id} [{tag}] {day}{summary}".rstrip())
    if not lines:
        return 0
    if len(ready) > MAX_RECORDS:
        lines.append(f"  and {len(ready) - MAX_RECORDS} more; run the handoff list command to see all")
    message = "\n".join(
        ["Saved handoffs for this repository:", *lines, "Run /kickoff <task> to resume one."]
    )
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": message,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001
        sys.exit(0)
