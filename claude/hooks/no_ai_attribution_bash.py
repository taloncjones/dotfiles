#!/usr/bin/env python3
"""PreToolUse Bash hook: block AI attribution in outbound command payloads.

Closes a gap where ~/.claude/hooks/no_ai_comments.py runs only on Edit|Write,
so commands like `gh pr comment --body "...Generated with Claude Code..."`
or `curl --data '...Co-Authored-By: Claude...'` ship attribution unchecked.

Agent names come from git/hooks/agent-tokens, shared with the commit-msg hook.

Rule reference: ~/.claude/CLAUDE.md "No AI attribution".
"""

import json
import re
import sys
from pathlib import Path

TOKENS_FILE = Path(__file__).resolve().parents[2] / "git" / "hooks" / "agent-tokens"


def load_pattern():
    """Compile the attribution patterns around the shared agent token list."""
    tokens = TOKENS_FILE.read_bytes().decode("ascii").split("\n")
    if tokens and tokens[-1] == "":
        tokens.pop()
    if not tokens or not all(re.fullmatch(r"[a-z0-9]+", t) for t in tokens):
        raise ValueError(f"{TOKENS_FILE} is empty or invalid")
    agents = "|".join(tokens)
    patterns = [
        rf"generated\s+(?:by|with)\s+\[?\s*(?:{agents}|ai)",
        rf"written\s+by\s+(?:{agents}|ai)",
        rf"created\s+by\s+(?:{agents}|ai)",
        r"ai[\- ]generated",
        rf"co[\-_ ]?authored[\-_ ]?by\s*:?\s*[^\r\n]*?\b(?:{agents})",
        "\U0001f916\\s*generated",
    ]
    return re.compile("|".join(patterns), re.IGNORECASE)


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") != "Bash":
            sys.exit(0)
        command = data.get("tool_input", {}).get("command", "")
        if not command:
            sys.exit(0)
        try:
            pattern = load_pattern()
        except (OSError, ValueError) as exc:
            print(
                f"no_ai_attribution_bash: {exc}; attribution check skipped.",
                file=sys.stderr,
            )
            sys.exit(0)
        match = pattern.search(command)
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
