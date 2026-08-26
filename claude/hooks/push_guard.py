#!/usr/bin/env python3
"""Hook to gate force pushes behind explicit user confirmation.

Bash(git push:*) is allowlisted, so a plain permission rule cannot
distinguish `git push` from `git push --force` -- force flags can appear at
any argument position, and allow/deny rules are literal prefixes. This hook
blocks any git push that rewrites remote history. A permissionDecision
"ask" could be auto-approved in auto permission mode, so the hook denies
(exit 2) instead; after the user explicitly confirms in conversation, the
push is re-run prefixed with DOTFILES_ALLOW_FORCE_PUSH=1.

Known holes, accepted: force spellings hidden by quoting of short flags
(`git push "-f"`), and server-side ref rewrites (`gh api ... force=true`).
The template's ask rules on the common `git push --force*` prefixes remain
as a static backstop if this hook ever crashes (it fails open).

Runs before Bash tool calls.
"""

import json
import re
import shlex
import sys

OVERRIDE = "DOTFILES_ALLOW_FORCE_PUSH=1"

FORCE_LONG = ("--force", "--force-with-lease", "--force-if-includes", "--mirror")

# git global options that take a separate argument (must be skipped when
# looking for the subcommand): git -C <path> -c <kv> push ...
GIT_OPTS_WITH_ARG = ("-C", "-c", "--git-dir", "--work-tree", "--namespace")

# Split a compound command line into segments so a force flag in one command
# does not implicate a git push in another (`git push && rm -f x`).
SEGMENT_SPLIT = re.compile(r"[|;&\n]+")

GIT_PUSH_TEXT = re.compile(r"\bgit\b.*\bpush\b")


def git_subcommand(tokens: list[str]) -> tuple[str | None, list[str]]:
    """Return (subcommand, args after it) for a bare git invocation in the
    token list, or (None, []) when no bare `git` is present."""
    if "git" not in tokens:
        return None, []
    i = tokens.index("git") + 1
    while i < len(tokens):
        tok = tokens[i]
        if tok in GIT_OPTS_WITH_ARG:
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        return tok, tokens[i + 1:]
    return None, []


def has_force_arg(args: list[str]) -> bool:
    for tok in args:
        if tok in FORCE_LONG or tok.startswith(tuple(f + "=" for f in FORCE_LONG)):
            return True
        # Bundled short options: -f, -fu, -uf ...
        if re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", tok):
            return True
        # Forced refspec: `git push origin +main`
        if tok.startswith("+") and len(tok) > 1:
            return True
    return False


def is_force_push(command: str) -> bool:
    for segment in SEGMENT_SPLIT.split(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        sub, args = git_subcommand(tokens)
        if sub == "push":
            if has_force_arg(args):
                return True
            continue
        if sub is not None:
            # A different git subcommand; trust the parse (a commit message
            # mentioning "push --force" is not a push).
            continue
        # No bare git invocation in this segment: catch pushes wrapped in
        # another command (`sh -c 'git push --force'`) by substring. Only
        # unambiguous long spellings, to keep false positives rare.
        if GIT_PUSH_TEXT.search(segment) and any(f in segment for f in FORCE_LONG):
            return True
    return False


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            sys.exit(0)

        command = data.get("tool_input", {}).get("command", "")
        if OVERRIDE in command:
            sys.exit(0)
        if not is_force_push(command):
            sys.exit(0)

        print(
            "Blocked: force push rewrites remote history and the git push "
            "allowlist rule does not cover it.",
            file=sys.stderr,
        )
        print(
            "Ask the user for explicit confirmation, then re-run prefixed "
            "with " + OVERRIDE + " -- never add the prefix without that "
            "confirmation.",
            file=sys.stderr,
        )
        sys.exit(2)
    except Exception:
        # Fail open: a crashed guard must never block work. The template's
        # ask rules on common force spellings are the static backstop.
        sys.exit(0)


if __name__ == "__main__":
    main()
