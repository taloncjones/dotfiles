#!/usr/bin/env python3
"""Hook to deny catastrophic `rm` targets that a literal permission rule
cannot express.

Bash permission rules are literal, per-subcommand text patterns: they never
expand `~`/`$HOME`, never resolve a path relative to cwd, and cannot express
"any glob directly under root/home/.git". A deny-floor of literal strings
therefore misses `rm -rf /*`, `rm -rf ~/*`, `rm -rf $HOME/*`, `rm -rf .git/*`,
`rm -rf /etc`, compound commands (`cd / && rm -rf *`), and variable targets
(`rm -rf "$X"`) -- see push_guard.py's docstring for the same class of
problem with git push. This hook resolves what a literal rule cannot: it
splits compound commands, shlex-parses each `rm` invocation, expands and
normalizes every target, and denies the shapes that are actually
catastrophic. A permissionDecision "ask" could be auto-approved in auto
permission mode, so the hook denies (exit 2) instead.

Runs before Bash tool calls. Fails open on any exception, and on any segment
that contains no `rm` token.
"""

import json
import os
import re
import shlex
import sys

SEGMENT_SPLIT = re.compile(r"[|;&\n]+")

PREFIX_WRAPPERS = ("env", "exec", "command", "nohup", "time", "xargs", "sudo")

SYSTEM_PATHS = (
    "/etc", "/bin", "/usr", "/sbin", "/lib",
    "/System", "/Applications", "/private", "/var", "/opt",
)

RECURSIVE_OR_FORCE_LONG = ("--recursive", "--force")


def basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def is_env_assignment(tok: str) -> bool:
    return "=" in tok and not tok.startswith("-") and "/" not in tok.split("=")[0]


def strip_prefixes(tokens: list[str]) -> list[str]:
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if is_env_assignment(tok):
            i += 1
        elif basename(tok) in PREFIX_WRAPPERS:
            i += 1
        else:
            break
    return tokens[i:]


def tokenize(segment: str) -> list[str]:
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


def expand_home(tok: str, home: str) -> str:
    m = re.match(r"^\$\{HOME\}(.*)$", tok) or re.match(r"^\$HOME(.*)$", tok)
    if m:
        return home + m.group(1)
    if tok == "~":
        return home
    if tok.startswith("~/"):
        return home + tok[1:]
    return tok


def resolve(tok: str, cwd: str) -> str:
    if tok.startswith("/"):
        return os.path.normpath(tok)
    return os.path.normpath(os.path.join(cwd, tok))


def has_glob_chars(name: str) -> bool:
    return any(c in name for c in "*?[")


def denial_reason(path: str, has_unexpanded_var: bool, recursive_or_force: bool,
                   home: str, real_cwd: str) -> str | None:
    if has_unexpanded_var and recursive_or_force:
        return "target contains an unexpanded variable/command substitution"

    parent, name = os.path.split(path) if path != "/" else ("/", "")

    if path == "/" or (parent == "/" and has_glob_chars(name)):
        return "target is the filesystem root or a glob directly under it"

    if path == home or (parent == home and has_glob_chars(name)):
        return "target is the home directory or a glob directly under it"

    if name == ".git" or (basename(parent) == ".git" and has_glob_chars(name)):
        return "target is a .git directory or a glob directly under it"

    for sys_path in SYSTEM_PATHS:
        if path == sys_path or path.startswith(sys_path + "/"):
            return "target is a system path (%s)" % sys_path

    if real_cwd.startswith(path + "/") and path != real_cwd:
        return "target is a parent of the current working directory"

    return None


def rm_flag_is_recursive_or_force(tok: str) -> bool:
    if tok in RECURSIVE_OR_FORCE_LONG:
        return True
    if tok.startswith("-") and not tok.startswith("--"):
        return any(c in "rRf" for c in tok[1:])
    return False


def check_rm(tokens: list[str], cwd: str, home: str, real_cwd: str) -> str | None:
    """Return a denial reason for the `rm` invocation `tokens`, or None."""
    recursive_or_force = any(rm_flag_is_recursive_or_force(t) for t in tokens[1:])
    targets = []
    only_targets = False
    for tok in tokens[1:]:
        if only_targets:
            targets.append(tok)
        elif tok == "--":
            only_targets = True
        elif tok.startswith("-") and tok != "-":
            continue
        else:
            targets.append(tok)

    for raw in targets:
        expanded = expand_home(raw, home)
        has_unexpanded_var = "$" in expanded or "`" in expanded
        path = resolve(expanded, cwd)
        reason = denial_reason(path, has_unexpanded_var, recursive_or_force, home, real_cwd)
        if reason:
            return reason
    return None


def resolve_cd_target(tokens: list[str], cwd: str, home: str) -> str:
    if len(tokens) < 2 or tokens[1] == "-":
        return cwd
    return resolve(expand_home(tokens[1], home), cwd)


def check_command(command: str, real_cwd: str, home: str) -> str | None:
    cwd = real_cwd
    for segment in SEGMENT_SPLIT.split(command):
        tokens = strip_prefixes(tokenize(segment))
        if not tokens:
            continue
        head = basename(tokens[0])
        if head == "rm":
            reason = check_rm(tokens, cwd, home, real_cwd)
            if reason:
                return reason
        elif head == "cd":
            cwd = resolve_cd_target(tokens, cwd, home)
    return None


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            sys.exit(0)

        command = data.get("tool_input", {}).get("command", "")
        if not isinstance(command, str) or "rm" not in command:
            sys.exit(0)

        real_cwd = data.get("cwd") or os.getcwd()
        home = os.environ.get("HOME", os.path.expanduser("~"))

        reason = check_command(command, real_cwd, home)
        if not reason:
            sys.exit(0)

        print("Blocked: rm target is catastrophic -- " + reason + ".", file=sys.stderr)
        print(
            "Narrow the target to a specific file or subdirectory, or ask the "
            "user for explicit confirmation before removing it.",
            file=sys.stderr,
        )
        sys.exit(2)
    except Exception:
        # Fail open: a crashed guard must never block work.
        sys.exit(0)


if __name__ == "__main__":
    main()
