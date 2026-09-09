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
import sys
from pathlib import Path

CONTEXT_LIB = Path(__file__).resolve().parents[1] / "skills" / "lib"
if str(CONTEXT_LIB) not in sys.path:
    sys.path.insert(0, str(CONTEXT_LIB))

try:
    from workflow_context import account_scope
except Exception:  # noqa: BLE001
    account_scope = None


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


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        payload = {}

    cwd = payload.get("cwd") or os.getcwd()
    home = str(Path.home())
    work_cfg = real(os.environ.get("CLAUDE_WORK_CONFIG_DIR", f"{home}/.claude-work"))
    personal_cfg = real(f"{home}/.claude")

    if account_scope is None:
        message = (
            "[WARNING] account_guard: account scope is unverified. "
            "Verify the launch scope before sending repository context."
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
        return

    try:
        scope = account_scope(cwd, "claude")
    except ValueError:
        message = (
            "[WARNING] account_guard: canonical repository ownership is ambiguous. "
            "Do not send repository context until relaunched with an explicit personal scope."
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
        return
    if scope["kind"] == "work" or (
        not scope["personal_repository"]
        and os.environ.get("CLAUDE_PERSONAL_ONLY") != "1"
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
