#!/usr/bin/env python3
"""Codex PreToolUse adapter for the shared orchestrator edit guard."""

import contextlib
import importlib.util
import io
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[2] / "claude" / "hooks" / "orch_edit_guard.py"
SPEC = importlib.util.spec_from_file_location("shared_orch_edit_guard", SOURCE)
guard = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(guard)

PATCH_PATH = re.compile(
    r"^\*\*\* (?:Update|Add|Delete) File: (.+)$|^\*\*\* Move to: (.+)$",
    re.MULTILINE,
)


def hook_input(payload):
    value = payload.get("tool_input") or payload.get("toolInput") or {}
    return value if isinstance(value, dict) else {}


def session_id(payload, tool_input):
    for value in (
        payload.get("thread_id"),
        payload.get("threadId"),
        payload.get("session_id"),
        payload.get("sessionId"),
        tool_input.get("thread_id"),
        tool_input.get("session_id"),
    ):
        if isinstance(value, str):
            return value
    return ""


def command(tool_input):
    for key in ("cmd", "command"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    args = tool_input.get("args")
    if isinstance(args, dict):
        return command(args)
    return ""


def working_directory(tool_input):
    for key in ("workdir", "cwd"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    args = tool_input.get("args")
    return working_directory(args) if isinstance(args, dict) else ""


def paths(tool_input, raw_input):
    result = []
    for key in ("file_path", "filePath", "path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            result.append(value)
    for patch in (tool_input.get("input"), tool_input.get("patch"), raw_input):
        if isinstance(patch, str):
            result.extend(
                endpoint
                for match in PATCH_PATH.finditer(patch)
                for endpoint in match.groups()
                if endpoint
            )
    return list(dict.fromkeys(path for path in result if path and path != "/dev/null"))


def normalize(payload):
    tool_input = hook_input(payload)
    raw_input = payload.get("tool_input") or payload.get("toolInput")
    tool = str(payload.get("tool_name") or payload.get("toolName") or "").lower()
    cwd = working_directory(tool_input) or payload.get("cwd") or "."
    base = {
        "hook_event_name": "PreToolUse",
        "session_id": session_id(payload, tool_input),
        "cwd": cwd,
        "caller_cwd": payload.get("cwd")
        if isinstance(payload.get("cwd"), str)
        else cwd,
        "tool_use_id": payload.get("tool_use_id") or payload.get("toolUseId"),
        "tool_name": "",
        "tool_input": {},
    }
    if tool in {"bash", "shell", "exec_command", "shell_command", "unified_exec"}:
        base["tool_name"] = "Bash"
        base["tool_input"] = {"command": command(tool_input)}
    elif tool in {"edit", "write", "multiedit", "apply_patch"}:
        base["tool_name"] = "Write"
        base["tool_input"] = {"file_paths": paths(tool_input, raw_input)}
    return base


def main():
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        print("{}")
        return 0
    normalized = normalize(payload) if isinstance(payload, dict) else {}
    if not normalized.get("tool_name"):
        print("{}")
        return 0
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        result = guard.decide(normalized, runtime="codex")
    if result == 2:
        print(json.dumps({"decision": "block", "reason": stderr.getvalue().strip()}))
        return 2
    print("{}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- a broken guard must fail open
        print("{}")
        sys.exit(0)
