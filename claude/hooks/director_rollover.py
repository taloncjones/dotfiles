#!/usr/bin/env python3
"""SessionStart hook: re-establish a herdr director's lease after /clear or
compaction, in place, and orient the fresh context.

/clear gives the director a new session id but keeps its process, pid, and
messaging socket (probed live 2026-09-22), so the core's resume-owner verb
can adopt the lease under the new id. This hook only gates and wraps:
source clear|compact, HERDR_ENV=1, agent_type director, a UUID session id,
and a messaging socket. resume-owner does the rest and exits 3 when this
process does not already hold the lease, which stays silent here.

Always exits 0. A failure after the gates prints the WARNING block so the
director re-runs its preflight instead of acting unfenced.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

CORE = Path(__file__).resolve().parent / "herdr_orch_core.py"
TIMEOUT_SECS = 20
SESSION_ID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
WARNING = (
    "[WARNING] herdr director rollover: lease NOT re-established (error).\n"
    "Run the herdr-orchestration section-1 preflight; if it reports BUSY, stop\n"
    "and ask the human (takeover is a human decision)."
)


def emit(text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                             "additionalContext": text}}))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict):
        return 0
    if payload.get("hook_event_name") != "SessionStart":
        return 0
    if payload.get("source") not in ("clear", "compact"):
        return 0
    if os.environ.get("HERDR_ENV") != "1" or payload.get("agent_type") != "director":
        return 0
    session = payload.get("session_id")
    cwd = payload.get("cwd")
    sock = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET", "")
    if not isinstance(session, str) or not SESSION_ID_RE.fullmatch(session):
        return 0
    if not sock or not isinstance(cwd, str) or not cwd:
        return 0
    try:
        result = subprocess.run(
            [sys.executable, str(CORE), "resume-owner", "--repo-path", cwd,
             "--session", session, "--messaging-socket", sock],
            capture_output=True, text=True, timeout=TIMEOUT_SECS, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        emit(WARNING)
        return 0
    if result.returncode == 3:
        return 0
    text = result.stdout.strip()
    emit(text if result.returncode in (0, 1) and text else WARNING)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001
        sys.exit(0)
