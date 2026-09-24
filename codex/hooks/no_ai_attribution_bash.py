#!/usr/bin/env python3
"""PreToolUse hook: block attribution phrases in shell command payloads.

Agent names come from git/hooks/agent-tokens, shared with the commit-msg hook.
"""

import json
import re
import sys
from pathlib import Path

SHELL_TOOL_NAMES = {
    "bash",
    "shell",
    "exec_command",
    "shell_command",
    "unified_exec",
}

TOKENS_FILE = Path(__file__).resolve().parents[2] / "git" / "hooks" / "agent-tokens"


# "aider" collides with common surnames (Raider), so it alone needs a leading
# word boundary; every other token stays a plain substring match so a glued
# prefix (AutoGPT) is still caught, matching the base hook and commit-msg.
BOUNDARY_TOKENS = frozenset({"aider"})


def load_pattern():
    """Compile the attribution patterns around the shared agent token list."""
    tokens = TOKENS_FILE.read_bytes().decode("ascii").split("\n")
    if tokens and tokens[-1] == "":
        tokens.pop()
    if not tokens or not all(re.fullmatch(r"[a-z0-9]+", t) for t in tokens):
        raise ValueError(f"{TOKENS_FILE} is empty or invalid")
    agents = "|".join(tokens)
    substring_agents = "|".join(t for t in tokens if t not in BOUNDARY_TOKENS)
    boundary_agents = "|".join(t for t in tokens if t in BOUNDARY_TOKENS)
    coauthor_agents = substring_agents
    if boundary_agents:
        coauthor_agents = rf"{substring_agents}|\b(?:{boundary_agents})"
    patterns = [
        rf"generated\s+(?:by|with)\s+\[?\s*(?:{agents}|ai)",
        rf"written\s+by\s+(?:{agents}|ai)",
        rf"created\s+by\s+(?:{agents}|ai)",
        r"ai[\- ]generated",
        rf"co[\-_ ]?authored[\-_ ]?by\s*:?\s*[^\r\n]*?(?:{coauthor_agents})",
        "\U0001f916\\s*generated",
    ]
    return re.compile("|".join(patterns), re.IGNORECASE)


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

    try:
        pattern = load_pattern()
    except (OSError, ValueError) as exc:
        print(
            f"no_ai_attribution_bash: {exc}; attribution check skipped.",
            file=sys.stderr,
        )
        return

    match = pattern.search(command)
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
