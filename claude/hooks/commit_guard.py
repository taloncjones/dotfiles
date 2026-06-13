#!/usr/bin/env python3
"""Hook to prevent AI attribution in git commits.

Blocks commits containing:
- Claude/Anthropic/AI references in messages
- Co-authored-by lines mentioning Claude
- Generated-with attribution
- Emojis in commit messages

Runs before Bash tool calls that involve git commit.
"""

import json
import re
import sys

# Prohibited terms in commit messages
PROHIBITED_TERMS = [
    r"\bclaude\b",
    r"\banthropic\b",
    r"\bai[- ]generated\b",
    r"\bgenerated[- ]by[- ]ai\b",
    r"\bcopilot\b",
    r"\bchatgpt\b",
    r"\bgpt-?\d\b",
]

PROHIBITED_PATTERN = re.compile("|".join(PROHIBITED_TERMS), re.IGNORECASE)

# Co-authored-by pattern
COAUTHOR_PATTERN = re.compile(
    r"co-authored-by:.*?(claude|anthropic|ai\b)",
    re.IGNORECASE
)

# Generated-with pattern
GENERATED_PATTERN = re.compile(
    r"generated[- ]with:.*?(claude|anthropic)",
    re.IGNORECASE
)

# Emoji pattern
EMOJI_PATTERN = re.compile(
    "["
    "\U0001F600-\U0001F64F"
    "\U0001F300-\U0001F5FF"
    "\U0001F680-\U0001F6FF"
    "\U0001F900-\U0001F9FF"
    "\U0001FA00-\U0001FAFF"
    "\U00002702-\U000027B0"
    "]+",
    re.UNICODE,
)


def check_commit_message(message: str) -> tuple[bool, str]:
    """Check commit message for prohibited content."""

    # Strip the "scope: " prefix before checking prohibited terms,
    # since scope names like "claude:" are legitimate directory names.
    body = re.sub(r"^[a-zA-Z0-9_-]+:\s*", "", message, count=1)

    # Check for prohibited terms
    if PROHIBITED_PATTERN.search(body):
        return False, "Commit message contains prohibited AI attribution terms"

    # Check for co-authored-by with AI
    if COAUTHOR_PATTERN.search(message):
        return False, "Commit contains co-authored-by line with AI attribution"

    # Check for generated-with
    if GENERATED_PATTERN.search(message):
        return False, "Commit contains generated-with AI attribution"

    # Check for emojis
    if EMOJI_PATTERN.search(message):
        return False, "Commit message contains emojis"

    return True, ""


def extract_commit_message(command: str) -> str | None:
    """Extract commit message from git commit command."""

    # Match -m "message" or -m 'message'
    match = re.search(r'-m\s+["\'](.+?)["\']', command, re.DOTALL)
    if match:
        return match.group(1)

    # Match -m message (unquoted, take rest of args)
    match = re.search(r'-m\s+(\S+)', command)
    if match:
        return match.group(1)

    # Match heredoc style: -m "$(cat <<'EOF' ... EOF)"
    match = re.search(r'-m\s+"\$\(cat\s+<<[\'"]?EOF[\'"]?\s*\n(.+?)\nEOF', command, re.DOTALL)
    if match:
        return match.group(1)

    return None


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        tool_name = data.get("tool_name", "")

        # Only check Bash commands
        if tool_name != "Bash":
            sys.exit(0)

        command = tool_input.get("command", "")

        # Only check git commit commands
        if "git commit" not in command:
            sys.exit(0)

        # Allow commits in .claude directory (configuration)
        if "/.claude/" in command:
            sys.exit(0)

        # Extract and check commit message
        message = extract_commit_message(command)
        if message:
            ok, reason = check_commit_message(message)
            if not ok:
                print(f"Blocked: {reason}", file=sys.stderr)
                print("Remove AI attribution and emojis from commit message.", file=sys.stderr)
                sys.exit(2)

        sys.exit(0)
    except Exception:
        # Don't block on errors
        sys.exit(0)


if __name__ == "__main__":
    main()
