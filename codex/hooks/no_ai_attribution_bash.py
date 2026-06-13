#!/usr/bin/env python3
"""PreToolUse hook: block attribution phrases in shell command payloads."""

import json
import re
import sys

SHELL_TOOL_NAMES = {
    "bash",
    "shell",
    "exec_command",
    "shell_command",
    "unified_exec",
}

ATTRIBUTION_PATTERNS = [
    r"generated\s+(?:by|with)\s+\[?\s*(?:claude(?:\s+code)?|anthropic|copilot|chatgpt|gpt|codex|ai)",
    r"written\s+by\s+(?:claude|anthropic|copilot|chatgpt|gpt|codex|ai)",
    r"created\s+by\s+(?:claude|anthropic|copilot|chatgpt|gpt|codex|ai)",
    r"ai[\- ]generated",
    r"co[\-_ ]?authored[\-_ ]?by\s*:?\s*[^\r\n]*?(?:claude|anthropic|copilot|chatgpt|gpt|codex)",
    r"\U0001F916\s*generated",
]

COMBINED_PATTERN = re.compile("|".join(ATTRIBUTION_PATTERNS), re.IGNORECASE)


def shell_command(tool_input: dict) -> str:
    """Return the shell command from Codex or Claude-style hook payloads."""
    command = tool_input.get("command")
    if isinstance(command, str):
        return command

    cmd = tool_input.get("cmd")
    if isinstance(cmd, str):
        return cmd

    args = tool_input.get("args")
    if isinstance(args, dict):
        command = args.get("cmd") or args.get("command")
        if isinstance(command, str):
            return command

    return ""


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    tool_name = data.get("tool_name") or data.get("toolName")
    if tool_name and tool_name.lower() not in SHELL_TOOL_NAMES:
        return

    command = shell_command(data.get("tool_input") or data.get("toolInput") or {})
    if not command:
        return

    match = COMBINED_PATTERN.search(command)
    if not match:
        return

    message = (
        "Blocked: attribution phrase detected in shell command "
        f"(matched: {match.group(0)!r}). "
        "Remove attribution from outbound payloads before running the command."
    )
    print(json.dumps({"decision": "block", "reason": message}))
    sys.exit(2)


if __name__ == "__main__":
    main()
