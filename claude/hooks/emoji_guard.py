#!/usr/bin/env python3
"""Hook to prevent emojis in edited files.

Runs after Edit tool calls. Exits with code 2 to block if emojis found.
"""

import json
import os
import re
import sys

# Unicode ranges for emojis
EMOJI_PATTERN = re.compile(
    "["
    "\U0001F600-\U0001F64F"  # Emoticons
    "\U0001F300-\U0001F5FF"  # Symbols & pictographs
    "\U0001F680-\U0001F6FF"  # Transport & maps
    "\U0001F700-\U0001F77F"  # Alchemical
    "\U0001F780-\U0001F7FF"  # Geometric extended
    "\U0001F800-\U0001F8FF"  # Supplemental arrows
    "\U0001F900-\U0001F9FF"  # Supplemental symbols
    "\U0001FA00-\U0001FA6F"  # Chess symbols
    "\U0001FA70-\U0001FAFF"  # Symbols extended
    "\U00002702-\U000027B0"  # Dingbats
    "\U0001F1E0-\U0001F1FF"  # Flags
    "]+",
    re.UNICODE,
)

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


def is_workflow_path(path: str) -> bool:
    if not path:
        return False
    normalized = os.path.normpath(path).replace(os.sep, "/")
    searchable = f"/{normalized}/"
    return any(f"/{part}/" in searchable for part in WORKFLOW_PATH_PARTS)


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        if is_workflow_path(tool_input.get("file_path", "")):
            sys.exit(0)

        # Check new_string for emojis (Edit tool)
        new_string = tool_input.get("new_string", "")
        if new_string and EMOJI_PATTERN.search(new_string):
            print("Blocked: Emojis not allowed. Use text like [OK], [X], [WARNING] instead.")
            sys.exit(2)

        # Check content for emojis (Write tool)
        content = tool_input.get("content", "")
        if content and EMOJI_PATTERN.search(content):
            print("Blocked: Emojis not allowed. Use text like [OK], [X], [WARNING] instead.")
            sys.exit(2)

        sys.exit(0)
    except Exception:
        sys.exit(0)  # Don't block on errors


if __name__ == "__main__":
    main()
