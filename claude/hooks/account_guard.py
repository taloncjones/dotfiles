#!/usr/bin/env python3
"""SessionStart hook: warn loudly when the Claude account does not match the
directory convention.

The claude() zsh wrapper routes launches under ~/Git/work to the work config
dir (~/.claude-work), but plenty of launch paths bypass the wrapper entirely:
the desktop app, IDE extensions, `command claude`, scripts, cron. Those all
land on whatever CLAUDE_CONFIG_DIR says (usually the personal default).

This hook checks the ACCOUNT actually in use, not just the config-directory
path. It derives the work identity from the account ~/.claude-work is logged
into (never a hard-coded employer name -- this repo is public), then compares
the running session's account against it:

  cwd under $CLAUDE_WORK_TREE (default ~/Git/work)  -> expects the work account
  anywhere else                                     -> expects a non-work account

A warning fires only on a true mismatch (work account in a personal directory,
or vice versa). This kills the false positive an IDE launch used to trigger --
~/.claude logged into the work account, opened on a work repo, is correct even
though the path is the "personal" dir -- while still catching the real error a
path-only check missed: a personal repo opened while signed into work.

When the account cannot be resolved (work dir never logged in, cloud container,
malformed config), it falls back to the original path-based routing check so
behavior is unchanged on those machines. Emits nothing (exit 0, no output)
when routing is correct.
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


def read_oauth_identity(path: Path) -> str | None:
    """Return a stable account token (uuid, else email) from a .claude.json, or
    None if the file is absent, unreadable, or has no oauthAccount."""
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    account = data.get("oauthAccount")
    if not isinstance(account, dict):
        return None
    return account.get("accountUuid") or account.get("emailAddress")


def account_of(config_dir: str, personal_cfg: str, home: str) -> str | None:
    """Resolve the logged-in account for a config dir. The per-dir
    $config_dir/.claude.json wins; for the default ~/.claude dir the legacy
    home-root ~/.claude.json is a fallback (that is where the default dir's
    oauthAccount actually lives)."""
    candidates = [Path(config_dir) / ".claude.json"]
    if config_dir == personal_cfg:
        candidates.append(Path(home) / ".claude.json")
    for candidate in candidates:
        identity = read_oauth_identity(candidate)
        if identity:
            return identity
    return None


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
    expected_is_work = in_work_tree

    work_account = account_of(work_cfg, personal_cfg, home)
    active_account = account_of(actual, personal_cfg, home)

    message = None

    if work_account is not None and active_account is not None:
        # Account-aware path: classify by the account actually in use.
        active_is_work = active_account == work_account
        if active_is_work == expected_is_work:
            return
        actual_label = "WORK" if active_is_work else "PERSONAL"
        expected_label = "work" if expected_is_work else "personal"
        message = (
            f"[WARNING] account_guard: this session is signed into the "
            f"{actual_label} Claude account, but the directory ({cwd}) is a "
            f"{expected_label} location. Likely cause: a launcher that bypasses "
            "the claude() zsh wrapper (desktop app, IDE, script). Tell the user "
            "at the first opportunity; suggest relaunching via the wrapper or "
            "CLAUDE_CONFIG_DIR, and avoid account-specific actions (logins, "
            "plugin installs, billing-sensitive work) until confirmed."
        )
    else:
        # Fallback: account identity unavailable (work dir never logged in,
        # cloud container, malformed config). Use the original path-based check.
        expected = work_cfg if in_work_tree else personal_cfg
        if actual == expected:
            return
        if actual not in (work_cfg, personal_cfg):
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
