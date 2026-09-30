#!/usr/bin/env python3
"""SessionStart hook: say when herdr tasks await a director that is not running.

Worker wakes sent while no director runs are lost, so a reviewed or
completed task can wait until someone happens to start one. This hook runs
the core's read-only `pending` verb for the session's repository and, when
tasks are pending and owner.json holds no live lease, adds one [INFO] line.

Advisory only: every failure path exits 0 silently. It writes no state and
never starts, wakes, or dispatches a director. Uses the account the
repository selects; a deliberate --personal override in a work repository
is not visible here.
"""

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HOOKS = Path(__file__).resolve().parent
CORE = HOOKS / "herdr_orch_core.py"
TIMEOUT_SECS = 5


def repo_slug_for(cwd: str) -> str:
    """The slug the core's select_payload checks --repo-slug against."""
    sys.path.insert(0, str(HOOKS))
    import herdr_orch_core as core

    return core._context_slug(core.repository_context(cwd))


def notice_line(tasks: list) -> str:
    oldest = tasks[0]
    count = "1 task awaits" if len(tasks) == 1 else f"{len(tasks)} tasks await"
    since = ""
    stamp = oldest.get("since")
    if isinstance(stamp, str):
        try:
            since = " since " + datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").date().isoformat()
        except ValueError:
            since = ""
    return (f"[INFO] herdr: {count} the director (oldest {oldest['task_id']}{since}); "
            "run director in a herdr pane")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError, ValueError):
        payload = {}
    cwd = payload.get("cwd") if isinstance(payload, dict) else None
    cwd = cwd or os.getcwd()
    if not CORE.is_file():
        return 0
    slug = repo_slug_for(cwd)
    result = subprocess.run(
        [sys.executable, str(CORE), "pending", "--repo-slug", slug,
         "--repo-path", cwd, "--runtime", "claude"],
        capture_output=True, text=True, timeout=TIMEOUT_SECS, check=False,
    )
    if result.returncode != 0:
        return 0
    data = json.loads(result.stdout)
    tasks = data.get("tasks") if isinstance(data, dict) else None
    if not isinstance(tasks, list) or not tasks or data.get("lease") == "live":
        return 0
    if not all(isinstance(t, dict) and isinstance(t.get("task_id"), str) for t in tasks):
        return 0
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": notice_line(tasks),
        }
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- advisory hook: any failure is silent
        sys.exit(0)
