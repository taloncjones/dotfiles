#!/usr/bin/env python3
"""PreToolUse Bash hook: block AI attribution in outbound command payloads.

Closes a gap where ~/.claude/hooks/no_ai_comments.py runs only on Edit|Write,
so commands like `gh pr comment --body "...Generated with Claude Code..."`
or `curl --data '...Co-Authored-By: Claude...'` ship attribution unchecked.

Rule reference: ~/.claude/CLAUDE.md "No AI attribution".
"""

import json
import re
import sys

ATTRIBUTION_PATTERNS = [
    r"generated\s+(?:by|with)\s+\[?\s*(?:claude(?:\s+code)?|anthropic|copilot|chatgpt|gpt|ai)",
    r"written\s+by\s+(?:claude|anthropic|copilot|chatgpt|gpt|ai)",
    r"created\s+by\s+(?:claude|anthropic|copilot|chatgpt|gpt|ai)",
    r"ai[\- ]generated",
    r"co[\-_ ]?authored[\-_ ]?by\s*:?\s*[^\r\n]*?(?:claude|anthropic|copilot|chatgpt|gpt)",
    "\U0001F916\\s*generated",
]

COMBINED_PATTERN = re.compile("|".join(ATTRIBUTION_PATTERNS), re.IGNORECASE)


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") != "Bash":
            sys.exit(0)
        command = data.get("tool_input", {}).get("command", "")
        if not command:
            sys.exit(0)
        match = COMBINED_PATTERN.search(command)
        if match:
            print(
                "Blocked: tool-attribution phrase detected in Bash command "
                f"(matched: {match.group(0)!r}). "
                "See the no-attribution rule in ~/.claude/CLAUDE.md. "
                "Strip the offending phrase from outbound payloads "
                "(gh pr/issue --body, curl --data, etc.).",
                file=sys.stderr,
            )
            sys.exit(2)
        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
