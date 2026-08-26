#!/usr/bin/env python3
"""Hook to gate force pushes behind an explicit permission prompt.

Bash(git push:*) is allowlisted, so a plain permission rule cannot
distinguish `git push` from `git push --force` -- force flags can appear at
any argument position, and allow/deny rules are literal prefixes. This hook
closes that gap: any git push carrying a history-rewriting flag downgrades
the auto-approval to an "ask" decision, so the user sees a prompt.

Runs before Bash tool calls. Fails open on internal errors.
"""

import json
import re
import sys

FORCE_TOKENS = ("-f", "--force")
FORCE_PREFIXES = ("--force-with-lease", "--force-if-includes")

# Split a compound command line into segments so a force flag in one command
# does not implicate a git push in another (`git push && rm -f x`).
SEGMENT_SPLIT = re.compile(r"[|;&]+")

GIT_PUSH = re.compile(r"\bgit\b.*\bpush\b")


def is_force_push(command: str) -> bool:
    for segment in SEGMENT_SPLIT.split(command):
        if not GIT_PUSH.search(segment):
            continue
        tokens = segment.split()
        start = tokens.index("push") + 1 if "push" in tokens else 0
        for tok in tokens[start:]:
            if tok in FORCE_TOKENS or tok.startswith(FORCE_PREFIXES):
                return True
            # Forced refspec: `git push origin +main`
            if tok.startswith("+") and len(tok) > 1:
                return True
    return False


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            sys.exit(0)

        command = data.get("tool_input", {}).get("command", "")
        if not is_force_push(command):
            sys.exit(0)

        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": (
                    "Force push rewrites remote history; the git push "
                    "allowlist rule does not cover it. Confirm to proceed."
                ),
            }
        }))
        sys.exit(0)
    except Exception:
        # Fail open: a crashed guard must never block work.
        sys.exit(0)


if __name__ == "__main__":
    main()
