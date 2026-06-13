#!/usr/bin/env python3
"""SessionStart hook: warn loudly when the Claude account does not match the
directory convention.

The claude() zsh wrapper routes launches under ~/Git/work to the work config
dir (~/.claude-work), but plenty of launch paths bypass the wrapper entirely:
the desktop app, IDE extensions, `command claude`, scripts, cron. Those all
land on whatever CLAUDE_CONFIG_DIR says (usually the personal default). This
hook runs inside EVERY session regardless of launcher and injects a visible
warning into context when the account and the directory disagree, so a work
session on the personal account (or vice versa) cannot start silently.

Expected mapping:
  cwd under $CLAUDE_WORK_TREE (default ~/Git/work)  -> $CLAUDE_WORK_CONFIG_DIR
                                                       (default ~/.claude-work)
  anywhere else                                      -> ~/.claude

Emits nothing (exit 0, no output) when routing is correct.
"""

import json
import os
import sys
from pathlib import Path


def real(p: str) -> str:
    try:
        return str(Path(p).expanduser().resolve())
    except OSError:
        return str(Path(p).expanduser())


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        payload = {}

    cwd = payload.get("cwd") or os.getcwd()
    home = str(Path.home())
    work_tree = real(os.environ.get("CLAUDE_WORK_TREE", f"{home}/Git/work"))
    work_cfg = real(os.environ.get("CLAUDE_WORK_CONFIG_DIR", f"{home}/.claude-work"))
    personal_cfg = real(f"{home}/.claude")

    actual = real(os.environ.get("CLAUDE_CONFIG_DIR", personal_cfg))
    in_work_tree = real(cwd).startswith(work_tree + os.sep) or real(cwd) == work_tree
    expected = work_cfg if in_work_tree else personal_cfg

    if actual == expected:
        return

    if actual not in (work_cfg, personal_cfg):
        # Deliberate custom config dir: respect it, but leave a breadcrumb.
        message = (
            f"[INFO] account_guard: custom CLAUDE_CONFIG_DIR in use ({actual}); "
            "directory-based personal/work routing is bypassed for this session."
        )
    else:
        actual_label = "WORK" if actual == work_cfg else "PERSONAL"
        expected_label = "work" if expected == work_cfg else "personal"
        message = (
            f"[WARNING] account_guard: this session is running on the {actual_label} "
            f"Claude account but the directory ({cwd}) routes to the {expected_label} "
            f"account ({expected}). Likely cause: a launcher that bypasses the "
            "claude() zsh wrapper (desktop app, IDE, script). Tell the user at the "
            "first opportunity; suggest relaunching via the wrapper or "
            "CLAUDE_CONFIG_DIR, and avoid account-specific actions (logins, "
            "plugin installs, billing-sensitive work) until confirmed."
        )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": message,
        }
    }))


if __name__ == "__main__":
    main()
