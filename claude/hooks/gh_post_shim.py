#!/usr/bin/env python3
"""Exec-time half of the herdr PR post gate: runs in place of `gh`.

bin/herdr-shims/gh execs this with its own path and the final argv, after
the shell has done all quoting, substitution and continuation -- the shapes
four review rounds used to hide a write from pr_post_guard.py's text hook.
Classification, session binding and the typed go are pr_post_guard's; this
file only finds the real gh, spends the go, and execs.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_post_guard


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
    os.execv(target, ["gh", *argv[2:]])
    return 127  # unreachable: execv replaces this process or raises


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001 -- fail closed: never exec on error
        print(f"gh shim: Blocked: internal error ({type(exc).__name__}).", file=sys.stderr)
        sys.exit(1)
