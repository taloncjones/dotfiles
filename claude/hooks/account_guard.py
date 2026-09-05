#!/usr/bin/env python3
"""Warn when a personal session uses the work Claude account or config.

Work repositories allow either account, including deliberate personal-account
overrides when work quota is exhausted. Personal repositories and machines with
CLAUDE_PERSONAL_ONLY=1 must use the personal account. Canonical Git ownership
preserves this boundary for linked worktrees outside their original directory.

The work identity comes from ~/.claude-work, so a work login stored in ~/.claude
is still detected. When identities are unavailable, config paths provide the
fallback check. This also covers launchers that bypass the shell wrapper.
"""

import json
import os
import subprocess
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


def account_of(
    config_dir: str, home: str, *, native_default: bool = False
) -> str | None:
    """Read only the active authentication namespace's account metadata.

    An unset CLAUDE_CONFIG_DIR uses ~/.claude.json; an explicit config path
    uses its own .claude.json even when that path is ~/.claude.
    """
    metadata_root = Path(home) if native_default else Path(config_dir)
    return read_oauth_identity(metadata_root / ".claude.json")


def repository_owner(cwd: str) -> str:
    """Return the canonical Git common directory, or cwd outside a repository."""
    clean_env = {
        key: value
        for key, value in os.environ.items()
        if key not in {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE"}
    }
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--git-common-dir"],
            env=clean_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return real(cwd)
    common_dir = result.stdout.rstrip("\n")
    if result.returncode or not common_dir:
        return real(cwd)
    return real(str(Path(cwd) / common_dir))


def within(path: str, root: str) -> bool:
    return path == root or path.startswith(root + os.sep)


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

    if os.environ.get("CLAUDE_PERSONAL_ONLY") != "1":
        checkout = real(cwd)
        owner = repository_owner(checkout)
        personal_tree = real(f"{home}/Git/personal")
        if (
            not within(checkout, personal_tree)
            and not within(owner, personal_tree)
            and (within(checkout, work_tree) or within(owner, work_tree))
        ):
            return

    actual = real(os.environ.get("CLAUDE_CONFIG_DIR") or personal_cfg)
    work_account = account_of(work_cfg, home)
    active_account = account_of(
        actual, home, native_default="CLAUDE_CONFIG_DIR" not in os.environ
    )

    if actual == work_cfg or (
        work_account is not None and active_account == work_account
    ):
        message = (
            "[WARNING] account_guard: this personal session is using a WORK "
            f"Claude account or configuration ({actual}) in {cwd}. "
            "Do not send personal repository content from this session. "
            "Tell the user and relaunch using the verified personal login, "
            "normally via claude --personal with CLAUDE_CONFIG_DIR unset."
        )
    elif (
        work_account is not None and active_account is not None
    ) or actual == personal_cfg:
        return
    else:
        message = (
            f"[INFO] account_guard: custom CLAUDE_CONFIG_DIR in use ({actual}); "
            "the personal account identity could not be verified for this session."
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


if __name__ == "__main__":
    main()
