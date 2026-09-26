#!/usr/bin/env python3
"""Exec-time half of the herdr PR post gate: runs in place of `gh`.

bin/herdr-shims/gh execs this with its own path and the final argv, after
the shell has done all quoting, substitution and continuation -- the shapes
four review rounds used to hide a write from pr_post_guard.py's text hook.
Classification, session binding and the typed go are pr_post_guard's; this
file finds the real gh, spends the go, checks a delete targets our own
marker, and execs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "co-review" / "scripts"))
import pr_post_guard
from pr_ready_gate import MARKER_PREFIX

OWNERSHIP_READ_TIMEOUT = 30


def real_gh() -> str | None:
    """DOTFILES_REAL_GH, else the first gh on PATH that is not a shim. Any
    shim copy is skipped by content, so no PATH layout can exec-loop."""
    override = os.environ.get("DOTFILES_REAL_GH")
    if override:
        return override if _runnable(override) else None
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(entry, "gh")
        if entry and _runnable(candidate):
            return candidate
    return None


def _runnable(path: str) -> bool:
    return os.path.isfile(path) and os.access(path, os.X_OK) and not pr_post_guard.is_shim(path)


def delete_target(args: list[str]) -> tuple[str | None, str | None]:
    """(path, hostname) of a `gh api ... DELETE <path>` argv."""
    _method, path, host, _field = pr_post_guard.parse_api(args[args.index("api") + 1:])
    return path, host


def _fetch_env() -> dict[str, str]:
    """The caller's env, including token and host, with gh's output forced
    plain: a TTY or color override would corrupt the JSON (spec R5)."""
    env = dict(os.environ)
    env.pop("GH_FORCE_TTY", None)
    env.pop("CLICOLOR_FORCE", None)
    env["NO_COLOR"] = "1"
    env["GH_PAGER"] = "cat"
    return env


def _gh_json(target: str, argv: list[str]):
    done = subprocess.run(
        [target, *argv], capture_output=True, text=True, env=_fetch_env(),
        timeout=OWNERSHIP_READ_TIMEOUT, check=True,
    )
    return json.loads(done.stdout)


def own_marker(target: str, args: list[str]) -> bool:
    """A delete may remove only this account's own co-review marker (review
    finding 5): its author is the authenticated user and its body starts
    with the marker. Any read failure refuses."""
    path, host = delete_target(args)
    if not path:
        return False
    extra = ["--hostname", host] if host else []
    try:
        comment = _gh_json(target, ["api", path, *extra])
        me = _gh_json(target, ["api", "user", *extra])
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    if not isinstance(comment, dict) or not isinstance(me, dict):
        return False
    user = comment.get("user")
    login = user.get("login") if isinstance(user, dict) else None
    body = comment.get("body")
    return (
        isinstance(login, str) and login == me.get("login")
        and isinstance(body, str) and body.startswith(MARKER_PREFIX)
    )


def gate(args: list[str]) -> str | None:
    kind, denial = pr_post_guard.resolved_kind(pr_post_guard.classify_gh(args))
    if denial:
        return f"Blocked: {denial}."
    if not kind:
        return None
    sid = pr_post_guard.shim_session_id()
    directory = pr_post_guard.gate_dir()
    return (
        pr_post_guard.check_go([kind], sid, directory, time.time())
        or pr_post_guard.spend_go([kind], sid, directory)
    )


def main(argv: list[str]) -> int:
    reason = gate(argv[2:])
    if reason:
        print(f"gh shim: {reason}", file=sys.stderr)
        return 1
    target = real_gh()
    if target is None:
        print("gh shim: real gh not found on PATH", file=sys.stderr)
        return 127
    if pr_post_guard.classify_gh(argv[2:]) == "delete" and not own_marker(target, argv[2:]):
        print(
            "gh shim: Blocked: a delete may only remove this account's own co-review marker comment.",
            file=sys.stderr,
        )
        return 1
    os.execv(target, ["gh", *argv[2:]])
    return 127  # unreachable: execv replaces this process or raises


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001 -- fail closed: never exec on error
        print(f"gh shim: Blocked: internal error ({type(exc).__name__}).", file=sys.stderr)
        sys.exit(1)
