#!/usr/bin/env python3
"""SessionStart hook: re-establish a herdr director's lease after /clear or
compaction, in place, and orient the fresh context.

/clear gives the director a new session id but keeps its process, pid, and
messaging socket (probed live 2026-09-22), so the core's resume-owner verb
can adopt the lease under the new id. This hook only gates and wraps:
source clear|compact, HERDR_ENV=1, agent_type director, a UUID session id,
and a messaging socket. resume-owner does the rest and exits 3 when this
process does not already hold the lease, which stays silent here.

After a /clear it also starts a detached `resume-helper` that types one
`resume director` line into the pane once the fresh context is idle, so a
rollover needs no keystroke. The helper holds no authority of its own: it
sends only while the canonical lease is the one this hook claimed.

Always exits 0. A failure after the gates prints the WARNING block so the
director re-runs its preflight instead of acting unfenced.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HOOKS = Path(__file__).resolve().parent
CORE = HOOKS / "herdr_orch_core.py"
TIMEOUT_SECS = 20
SESSION_ID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
LEASE_LINE_RE = re.compile(r"^repo_slug=(\S+) session=(\S+) fence=(\d+)$", re.M)
WARNING = (
    "[WARNING] herdr director rollover: lease NOT re-established (error).\n"
    "Run the herdr-orchestration section-1 preflight; if it reports BUSY, stop\n"
    "and ask the human (takeover is a human decision)."
)
AUTO_RESUME = 'auto-resume: a "resume director" line will arrive in this pane when it is idle.'
RESUME_LINE = "resume director"
RESUME_POLL_SECS = 1
RESUME_SETTLE_SECS = 3
RESUME_MAX_WAIT_SECS = 120


def emit(text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                             "additionalContext": text}}))


def load_core():
    sys.path.insert(0, str(HOOKS))
    import herdr_orch_core as core
    return core


def spawn_resume_helper(info, session, cwd) -> bool:
    """Start the detached helper; False on any unmet precondition, so the
    INFO block never promises a line that will not come."""
    pane = os.environ.get("HERDR_PANE_ID", "")
    m = LEASE_LINE_RE.search(info)
    if not m or m.group(2) != session or not shutil.which("herdr"):
        return False
    core = load_core()
    if not core.SHELL_SAFE_RE.fullmatch(pane) or not core.valid_repo_slug(m.group(1)):
        return False
    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "resume-helper",
             "--pane", pane, "--repo-path", cwd, "--repo-slug", m.group(1),
             "--session", session, "--fence", m.group(3)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    except OSError:
        return False
    return True


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
    if (result.returncode == 0 and text and payload["source"] == "clear"
            and spawn_resume_helper(text, session, cwd)):
        text += "\n" + AUTO_RESUME
    emit(text if result.returncode in (0, 1) and text else WARNING)
    return 0


def resume_helper(argv) -> int:
    ap = argparse.ArgumentParser(prog="director_rollover.py resume-helper")
    for flag in ("--pane", "--repo-path", "--repo-slug", "--session"):
        ap.add_argument(flag, required=True)
    ap.add_argument("--fence", type=int, required=True)
    # Test seams only.
    ap.add_argument("--poll-secs", type=float, default=RESUME_POLL_SECS, help=argparse.SUPPRESS)
    ap.add_argument("--settle-secs", type=float, default=RESUME_SETTLE_SECS, help=argparse.SUPPRESS)
    ap.add_argument("--max-wait-secs", type=float, default=RESUME_MAX_WAIT_SECS,
                    help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    core = load_core()
    from herdr_dispatch import AGENT_STATES
    from herdr_dispatch_cli import run_herdr
    core.select_payload(argparse.Namespace(repo_path=a.repo_path, runtime="claude",
                                           personal=False, repo_slug=a.repo_slug))
    rd = core.repo_dir(a.repo_slug)
    exe = shutil.which("herdr")
    env = dict(os.environ)
    start = time.monotonic()

    def canonical():
        with core.owner_transaction(rd) as tx:
            return dict(tx.current or {})

    def poll():
        """(ready, pane text, reason) for one observation of the pane."""
        try:
            listed = run_herdr(exe, ["agent", "list"], env=env, timeout_secs=budget())
            rows = listed.get("agents") if isinstance(listed, dict) else None
            agent_ready = any(isinstance(r, dict) and r.get("pane_id") == a.pane
                              and r.get("agent_status") in AGENT_STATES for r in rows or [])
            text = run_herdr(exe, ["pane", "read", a.pane, "--source", "detection",
                                   "--lines", "60"], env=env, json_result=False,
                             timeout_secs=budget())
        except Exception:  # noqa: BLE001 -- DispatchError lives in a lazily imported module
            return False, None, "poll-error"
        if not agent_ready:
            return False, text, "agent-not-idle"
        if core.current_input(text) != "":
            return False, text, "input-not-empty"
        return True, text, "ready"

    def expired():
        return time.monotonic() - start >= a.max_wait_secs

    def budget():
        # No herdr call may carry the helper past its send deadline.
        return max(0.1, min(10.0, a.max_wait_secs - (time.monotonic() - start)))

    def send(settled):
        # Lock waits are unbounded (herdr_coordination flock), so check the
        # deadline after acquiring, compare the lease, and re-read the pane
        # inside the same transaction before sending.
        with core.owner_transaction(rd) as tx:
            if expired():
                return "timeout", "lock-wait"
            if dict(tx.current or {}) != snapshot:
                return "superseded", "lease"
            ready, text, reason = poll()
            if not (ready and text == settled):
                return None, reason
            if expired():
                return "timeout", "deadline"
            try:
                run_herdr(exe, ["pane", "run", a.pane, RESUME_LINE], env=env,
                          json_result=False, timeout_secs=budget())
            except Exception:  # noqa: BLE001
                return "send-failed", "send-error"
            return "sent", "ready"

    def watch():
        # reason starts as lock-wait: a timeout before any poll ever
        # completes means the stall was in canonical()'s lock acquisition
        # itself. Once a poll completes, its diagnosis replaces it, so a
        # slow canonical() call on a LATER iteration reports the last real
        # observation instead of relabeling it lock-wait.
        stable_since, settled, reason = None, None, "lock-wait"
        while not expired():
            current = canonical()
            if expired():
                return "timeout", reason
            if current != snapshot:
                return "superseded", "lease"
            ready, text, reason = poll()
            if not ready:
                stable_since, settled = None, None
            elif text != settled:
                stable_since, settled = time.monotonic(), text
            elif time.monotonic() - stable_since >= a.settle_secs:
                result, reason = send(settled)
                if result is not None:
                    return result, reason
                stable_since, settled = None, None
            time.sleep(a.poll_secs)
        return "timeout", reason

    snapshot = canonical()
    if expired():
        outcome, reason = "timeout", "lock-wait"
    elif snapshot.get("session_id") != a.session or snapshot.get("fence") != a.fence:
        outcome, reason = "superseded", "lease"
    else:
        outcome, reason = watch()
    record = {"v": 1, "ts": core.now_iso(), "session": a.session, "pane": a.pane,
              "outcome": outcome, "reason": reason,
              "waited_secs": round(time.monotonic() - start, 1)}
    try:
        core.append_payload(rd / "rollover.jsonl",
                            (json.dumps(record, separators=(",", ":")) + "\n").encode())
    except (OSError, ValueError):
        pass
    return 0


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["resume-helper"]:
            sys.exit(resume_helper(sys.argv[2:]))
        sys.exit(main())
    except Exception:  # noqa: BLE001
        sys.exit(0)
