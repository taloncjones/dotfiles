#!/usr/bin/env python3
"""Stop/Notification hook: append a lifecycle HINT for an orchestrated worker.

No-ops unless HERDR_ENV=1, a basename-safe HERDR_WORKSPACE_ID, and a workspace
index the orchestrator placed under STATE_ROOT. Derives all paths from the fixed
state root; never trusts a payload path. Notifications map to `blocked` only for
permission/input-needed types. Fails OPEN (always exit 0). After appending,
pushes one wake line to the owning orchestrator's inbox socket
(core.post_wake) when owner.json names one.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core

# Notification types that mean "the worker is waiting on a human" (a hard block).
# Per the Claude Code hooks reference: permission_prompt and elicitation_dialog
# block; idle_prompt is idle-not-blocked (Stop + completion correlation cover it).
# Verify against the live payload; unknown types are treated as non-blocking.
_BLOCKING_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog"}


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        payload = {}
    if os.environ.get("HERDR_ENV") != "1":
        return 0
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return 0
    root = core.state_root()
    try:
        candidates = list(root.glob(f"*/workspaces/{ws}.json"))
    except OSError:
        return 0
    for idx in candidates:
        rd = idx.parent.parent
        index = core.read_index(rd, ws)
        if not index:
            continue
        role = index.get("role")
        if payload.get("hook_event_name") == "Notification":
            if (payload.get("notification_type") or "") not in _BLOCKING_NOTIFICATIONS:
                return 0  # idle_prompt and other notifications are not a hard block
            event = "blocked"
        elif role == "review":
            event = "review-stopped"
        else:
            event = "stopped"
        # Audit line first, wake second, each independently fail-open: a wake
        # without its audit line is harmless (check-in finds nothing new); a
        # lost wake is not.
        try:
            core.append_event(rd, ws, event, task_id=index.get("task_id"), role=role)
        except Exception:  # noqa: BLE001 -- never block the worker
            pass
        try:
            core.post_wake(rd, ws, event,
                           own_socket=os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET", ""))
        except Exception:  # noqa: BLE001
            pass
        break
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: never block a worker's session
        sys.exit(0)
