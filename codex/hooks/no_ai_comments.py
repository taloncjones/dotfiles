#!/usr/bin/env python3
"""Codex hook: block tool-attribution comments in code edit payloads."""

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

EXCLUDED_EXTENSIONS = {".md", ".mdx", ".rst", ".txt"}

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

ATTRIBUTION_PATTERNS = [
    r"generated\s+by\s+(?:claude|ai|copilot|gpt|chatgpt|anthropic|codex)",
    r"generated\s+with\s+(?:claude|ai|copilot|gpt|chatgpt|anthropic|codex)",
    r"written\s+by\s+(?:claude|ai|copilot|gpt|chatgpt|anthropic|codex)",
    r"created\s+by\s+(?:claude|ai|copilot|gpt|chatgpt|anthropic|codex)",
    r"ai[\- ]generated",
    r"#\s*(?:claude|codex)\s+(?:generated|wrote|created|made)",
    r"//\s*(?:claude|codex)\s+(?:generated|wrote|created|made)",
    r"/\*\s*(?:claude|codex)\s+(?:generated|wrote|created|made)",
]

COMBINED_PATTERN = re.compile("|".join(ATTRIBUTION_PATTERNS), re.IGNORECASE)


def hook_input(data: dict) -> dict:
    value = data.get("tool_input") or data.get("toolInput") or {}
    return value if isinstance(value, dict) else {}


def file_path(tool_input: dict) -> str:
    for key in ("file_path", "filePath", "path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def is_excluded_file(path: str) -> bool:
    return os.path.splitext(path.lower())[1] in EXCLUDED_EXTENSIONS


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
    reason = "Blocked: tool-attribution comments are not allowed in code."
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
    path = file_path(tool_input)
    if is_workflow_path(path) or is_excluded_file(path):
        return

    if COMBINED_PATTERN.search(payload_text(tool_input)):
        block()


if __name__ == "__main__":
    main()
