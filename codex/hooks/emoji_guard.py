#!/usr/bin/env python3
"""Codex hook: block emojis in file edit payloads."""

import json
import os
import re
import sys

FILE_TOOL_NAMES = {
    "edit",
    "write",
    "multiedit",
    "apply_patch",
}

WORKFLOW_PATH_PARTS = {
    ".claude/agents",
    ".claude/commands",
    ".claude/hooks",
    ".claude/rules",
    ".claude/skills",
    ".codex/agents",
    ".codex/hooks",
    ".codex/prompts",
    ".codex/rules",
    ".codex/skills",
    "claude/agents",
    "claude/commands",
    "claude/hooks",
    "claude/rules",
    "claude/skills",
    "codex/agents",
    "codex/hooks",
    "codex/prompts",
    "codex/rules",
    "codex/skills",
    "git/hooks",
}

EMOJI_PATTERN = re.compile(
    "["
    "\U0001F600-\U0001F64F"
    "\U0001F300-\U0001F5FF"
    "\U0001F680-\U0001F6FF"
    "\U0001F700-\U0001F77F"
    "\U0001F780-\U0001F7FF"
    "\U0001F800-\U0001F8FF"
    "\U0001F900-\U0001F9FF"
    "\U0001FA00-\U0001FA6F"
    "\U0001FA70-\U0001FAFF"
    "\U00002702-\U000027B0"
    "\U0001F1E0-\U0001F1FF"
    "]+",
    re.UNICODE,
)


def hook_input(data: dict) -> dict:
    value = data.get("tool_input") or data.get("toolInput") or {}
    return value if isinstance(value, dict) else {}


def file_path(tool_input: dict) -> str:
    for key in ("file_path", "filePath", "path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def is_workflow_path(path: str) -> bool:
    if not path:
        return False
    normalized = os.path.normpath(path).replace(os.sep, "/")
    searchable = f"/{normalized}/"
    return any(f"/{part}/" in searchable for part in WORKFLOW_PATH_PARTS)


def payload_text(tool_input: dict) -> str:
    parts = []
    for key in ("new_string", "newString", "content", "patch"):
        value = tool_input.get(key)
        if isinstance(value, str):
            parts.append(value)
    return "\n".join(parts)


def block() -> None:
    reason = "Blocked: emojis are not allowed. Use text like [OK], [X], or [WARNING]."
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(2)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    tool_name = data.get("tool_name") or data.get("toolName") or ""
    if tool_name and tool_name.lower() not in FILE_TOOL_NAMES:
        return

    tool_input = hook_input(data)
    if is_workflow_path(file_path(tool_input)):
        return

    if EMOJI_PATTERN.search(payload_text(tool_input)):
        block()


if __name__ == "__main__":
    main()
