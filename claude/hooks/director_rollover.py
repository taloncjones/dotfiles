#!/usr/bin/env python3
"""SessionStart hook: warn an unarmed director pane, and re-establish a herdr
director's lease after a rollover.

A director session inherits the lease in one of two ways, each a core verb:
- startup in a pane a rollover opened (HERDR_ROLLOVER_TOKEN set):
  adopt-rollover takes the lease the old director named this pane for.
- clear|compact in place: /clear keeps the process, pid, and messaging socket
  (probed live 2026-09-22), so resume-owner adopts the lease under the new
  session id.
Either verb exits 3 when it has nothing to adopt, which stays silent here.

An unarmed pane (first `gh` on PATH is not the herdr shim) gets the
UNARMED_WARNING on any source and returns before the lease gate on purpose:
the lease work is moot until the pane is relaunched. Only `gh` is probed,
matching pr_post_guard.

After the lease part, every source (startup, resume, clear, compact) appends
the repo's live decisions block from `herdr_orch_core.py decisions`; a failed
read adds a one-line WARNING. adopt-rollover already prints the carried notes,
so the decisions call then passes --no-carry.

Always exits 0. A failure after the gates prints the WARNING block so the
director re-runs its preflight instead of acting unfenced.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

HOOKS = Path(__file__).resolve().parent
CORE = HOOKS / "herdr_orch_core.py"
TIMEOUT_SECS = 20
SESSION_ID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
WARNING = (
    "[WARNING] herdr director rollover: lease NOT re-established (error).\n"
    "Run the herdr-orchestration section-1 preflight; if it reports BUSY, stop\n"
    "and ask the human (takeover is a human decision)."
)
DECISIONS_WARNING = (
    "[WARNING] herdr decisions: not loaded; run python3 ~/.claude/hooks/"
    "herdr_orch_core.py decisions --repo-path {cwd}"
)
UNARMED_WARNING = (
    "[WARNING] herdr director unarmed: `gh` on this pane's PATH is not the\n"
    "herdr gh shim, so pr_post_guard.py will fail closed on every gh-mentioning\n"
    "Bash call, including read-only queries. This pane's claude()/director()\n"
    "shell predates the arming logic, or a plain `reload` left it stale.\n"
    "Run /exit, then `exec zsh -l` to drop this shell, then relaunch with\n"
    "`director`."
)


def emit(text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                             "additionalContext": text}}))


def pane_unarmed() -> bool:
    """True when the first `gh` on this hook's PATH is not the herdr shim
    (pr_post_guard.shim_armed, which wraps is_shim)."""
    sys.path.insert(0, str(HOOKS))
    import pr_post_guard
    return not pr_post_guard.shim_armed()


def lease_verb(source):
    """The core verb that re-establishes the lease for this SessionStart
    source, or None when this start inherits nothing."""
    if source == "startup":
        return "adopt-rollover" if os.environ.get("HERDR_ROLLOVER_TOKEN") else None
    if source in ("clear", "compact"):
        return "resume-owner"
    return None


def decisions_text(cwd, no_carry):
    """The decisions block for this repo, "" when there is none, or the
    one-line WARNING when the verb fails (the director then reads it by hand)."""
    if not CORE.is_file():  # a hook copied away from the core has nothing to read
        return ""
    cmd = [sys.executable, str(CORE), "decisions", "--repo-path", cwd]
    if no_carry:
        cmd.append("--no-carry")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                                timeout=TIMEOUT_SECS, check=False)
    except (OSError, subprocess.SubprocessError):
        return DECISIONS_WARNING.format(cwd=shlex.quote(cwd))
    if result.returncode == 3:
        return ""
    if result.returncode != 0:
        return DECISIONS_WARNING.format(cwd=shlex.quote(cwd))
    return result.stdout.strip()


def lease_text(verb, session, cwd, sock):
    """(text, adopted): the lease block for verb, or "" when it has nothing to
    say; adopted is True when adopt-rollover exited 0."""
    try:
        result = subprocess.run(
            [sys.executable, str(CORE), verb, "--repo-path", cwd,
             "--session", session, "--messaging-socket", sock],
            capture_output=True, text=True, timeout=TIMEOUT_SECS, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return WARNING, False
    if result.returncode == 3:
        return "", False
    text = result.stdout.strip()
    ok = result.returncode in (0, 1) and text
    return (text if ok else WARNING), verb == "adopt-rollover" and result.returncode == 0


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict):
        return 0
    if payload.get("hook_event_name") != "SessionStart":
        return 0
    if os.environ.get("HERDR_ENV") != "1" or payload.get("agent_type") != "director":
        return 0
    try:
        unarmed = pane_unarmed()
    except Exception:  # noqa: BLE001 -- the hook must exit 0 on any import failure
        unarmed = False
    if unarmed:
        emit(UNARMED_WARNING)
        return 0
    source = payload.get("source")
    if source not in ("startup", "resume", "clear", "compact"):
        return 0
    verb = lease_verb(source)
    session = payload.get("session_id")
    cwd = payload.get("cwd")
    sock = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET", "")
    parts = []
    adopted = False
    if (verb is not None and isinstance(session, str) and SESSION_ID_RE.fullmatch(session)
            and sock and isinstance(cwd, str) and cwd):
        text, adopted = lease_text(verb, session, cwd, sock)
        if text:
            parts.append(text)
    if isinstance(cwd, str) and cwd:
        text = decisions_text(cwd, no_carry=adopted)
        if text:
            parts.append(text)
    if parts:
        emit("\n\n".join(parts))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001
        sys.exit(0)
