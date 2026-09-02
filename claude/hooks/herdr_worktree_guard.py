#!/usr/bin/env python3
"""Hook to deny `herdr worktree create` invocations that omit --cwd.

Without an explicit `--cwd <repo_root>`, herdr anchors the new worktree to
the repo its server session considers current (or an adjacent submodule),
not the caller's repo -- incident 2026-08-28, a worker briefed into the
wrong repo. The orchestration skill makes --cwd mandatory for create; the
Bash(herdr worktree:*) allowlist rule is a literal prefix and cannot
express "must contain --cwd", so this hook enforces it. `worktree open`
is deliberately NOT guarded (it re-attaches to an existing workspace).

Supported grammar (guaranteed caught): a create that heads a shell
segment on any physical line -- bare or path-qualified binary, after
leading NAME=VALUE assignments, prefix wrappers (env, exec, command,
nohup, time, xargs) or herdr global options (--session, --remote) -- or
that appears verbatim inside a quoted argument of sh/bash/zsh/dash/eval.

Accepted holes: aliases/functions/scripts, $(...) and heredoc bodies,
quoted newlines inside an argument, `--cwd ""` (herdr rejects it), and a
wrapper argument that assembles the command from pieces.

Runs before Bash tool calls. Fails open on any exception.
"""

import json
import re
import shlex
import sys

PREFIX_WRAPPERS = ("env", "exec", "command", "nohup", "time", "xargs")
STRING_WRAPPERS = ("sh", "bash", "zsh", "dash", "eval")
HERDR_GLOBAL_OPTS_WITH_ARG = ("--session", "--remote")
CREATE_TEXT = "herdr worktree create"
MAX_DEPTH = 3

CONTINUATION = re.compile(r"\\\n")
OPERATOR = re.compile(r"^[;&|]+$")


def basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def is_env_assignment(tok: str) -> bool:
    return "=" in tok and not tok.startswith("-") and "/" not in tok.split("=")[0]


def strip_line_comment(line: str) -> str:
    """Truncate `line` at a word-initial, unquoted `#` (preceded by
    whitespace or at start of line), matching bash's comment rule.

    shlex's own `commenters` handling triggers on ANY unquoted `#`, even
    mid-token (e.g. `FOO=a#b`), which would silently drop the rest of the
    line -- including a real `herdr worktree create` that bash itself still
    executes verbatim, since bash only starts a comment on a word-initial
    `#`. Stripping comments ourselves, then disabling shlex's commenters,
    keeps tokenize() bash-faithful.
    """
    quote = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if quote:
            if quote == '"' and c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
        i += 1
    return line


def tokenize(line: str) -> list[str]:
    """Shell-faithful tokens: quotes honored, operators split out, and a
    word-initial `#` starts a comment that is dropped."""
    line = strip_line_comment(line)
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return line.split()


def segments(tokens: list[str]) -> list[list[str]]:
    out: list[list[str]] = [[]]
    for tok in tokens:
        if OPERATOR.match(tok):
            out.append([])
        else:
            out[-1].append(tok)
    return [seg for seg in out if seg]


def strip_prefixes(tokens: list[str]) -> list[str]:
    """Drop leading env assignments and prefix wrappers until the head token
    is a real command."""
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if is_env_assignment(tok):
            i += 1
        elif basename(tok) in PREFIX_WRAPPERS:
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1  # wrapper's own options (env -i, nohup -p ...)
        else:
            break
    return tokens[i:]


def create_lacks_cwd(tokens: list[str]) -> bool:
    """True iff `tokens` (head already `herdr`) is a `worktree create`
    invocation with no --cwd."""
    i = 1
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] in HERDR_GLOBAL_OPTS_WITH_ARG:
            i += 2
        else:
            i += 1
    if tokens[i:i + 2] != ["worktree", "create"]:
        return False
    for tok in tokens[i + 2:]:
        if tok == "--cwd" or tok.startswith("--cwd="):
            return False
    return True


def command_lacks_cwd(command: str, depth: int = 0) -> bool:
    if depth > MAX_DEPTH:
        return False
    joined = CONTINUATION.sub(" ", command)
    for line in joined.split("\n"):
        for seg in segments(tokenize(line)):
            seg = strip_prefixes(seg)
            if not seg:
                continue
            head = basename(seg[0])
            if head == "herdr":
                if create_lacks_cwd(seg):
                    return True
            elif head in STRING_WRAPPERS:
                for tok in seg[1:]:
                    if CREATE_TEXT in tok and command_lacks_cwd(tok, depth + 1):
                        return True
            # Any other head (git, echo, grep ...) is a mention, not a create.
    return False


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            sys.exit(0)
        command = data.get("tool_input", {}).get("command", "")
        if not isinstance(command, str) or not command_lacks_cwd(command):
            sys.exit(0)
        print(
            "Blocked: herdr worktree create without --cwd anchors the worktree "
            "to the herdr server's current repo, not yours.",
            file=sys.stderr,
        )
        print(
            'Re-run with --cwd "$(git -C <path-in-repo> rev-parse '
            '--show-toplevel)" (herdr-orchestration SKILL.md, section 2 step 5).',
            file=sys.stderr,
        )
        sys.exit(2)
    except Exception:
        # Fail open: a crashed guard must never block work.
        sys.exit(0)


if __name__ == "__main__":
    main()
