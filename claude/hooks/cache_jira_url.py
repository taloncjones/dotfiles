#!/usr/bin/env python3
"""PostToolUse hook: Cache Jira URL from Atlassian MCP tool responses."""

import json
import os
import re
import sys
from pathlib import Path

CACHE_FILE = Path.home() / ".claude" / "cache" / "jira-url"


def extract_jira_url(text: str) -> str | None:
    """Extract Atlassian site URL from text."""
    match = re.search(r"https://[a-zA-Z0-9-]+\.atlassian\.net", text)
    return match.group(0) if match else None


def main() -> None:
    # Already cached, skip
    if CACHE_FILE.exists():
        return

    try:
        hook_input = json.load(sys.stdin)
    except json.JSONDecodeError:
        return

    # Get tool result as string
    result = hook_input.get("tool_result", "")
    if isinstance(result, dict):
        result = json.dumps(result)

    url = extract_jira_url(str(result))
    if url:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(url)


if __name__ == "__main__":
    main()
