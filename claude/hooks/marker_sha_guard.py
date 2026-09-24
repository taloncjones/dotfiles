#!/usr/bin/env python3
"""PreToolUse hook: deny a gh post whose co-review marker names a SHA that
is not a full commit id in the target repository.

Incidents: PR #121 round 4 (2026-09-12) posted a full SHA expanded from
memory; PR #135 rounds 2-6 (2026-09-15) posted short SHAs that
pr_ready_gate.py's 40-hex MARKER_RE silently ignored.

Inspects the bodies of `gh pr comment|create|edit|review` and `gh issue
comment|create|edit` (--body, --body-file, heredoc stdin). A marker is
recognized as pr_ready_gate.py recognizes one: a line outside every fence,
at column 0, starting with a family prefix. Every SHA key must be 40
lowercase hex and name a commit object in the repository gh runs in. An
unreadable body or a `gh api` call denies only when the command text
carries a marker hint.

No override: fence or indent an example marker. Fails open on any
unexpected exception.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.dont_write_bytecode = True
HOOKS = Path(__file__).resolve().parent
sys.path.insert(0, str(HOOKS))
import rm_guard  # noqa: E402

_GATE = HOOKS.parent / "skills" / "co-review" / "scripts" / "pr_ready_gate.py"
_SPEC = importlib.util.spec_from_file_location("pr_ready_gate", _GATE)
pr_ready_gate = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(pr_ready_gate)

# (family, prefix, required SHA keys, optional SHA keys)
FAMILIES = (
    ("round", "<!-- co-review:", ("sha", "base"), ("target_tip",)),
    ("coworker", "<!-- co-review-coworker:", ("sha", "base", "base_ref_tip"), ()),
    ("audit", "<!-- co-review-audit", ("head",), ()),
)
POSTING_VERBS = {
    ("pr", "comment"),
    ("pr", "create"),
    ("pr", "edit"),
    ("pr", "review"),
    ("issue", "comment"),
    ("issue", "create"),
    ("issue", "edit"),
}
BODY_FLAGS = ("-b", "--body")
FILE_FLAGS = ("-F", "--body-file")
REPO_FLAGS = ("-R", "--repo")
# Commands that cannot rewrite a body file (when they carry no redirection).
HARMLESS = ("cd", "true", ":", "test", "[", "exit", "return")
# Leading shell keywords a gh segment can sit behind (`if COND; then gh ...`,
# `{ gh ...; }`, `! gh ...`, `for ...; do gh ...; done`, `else gh ...`);
# stripped before head detection so the segment underneath is still inspected.
RESERVED_WORDS = ("if", "then", "elif", "else", "do", "while", "until", "!", "{")
MARKER_HINTS = ("<!-- co-review", "co-review-audit", "audit-comment")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
KEY_VALUE = re.compile(r"(?<![\w-])([a-z_]+)=(\S*)")
HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
REDIRECT = re.compile(r"^[0-9&]*>>?\|?(.*)$")
# `$(cat <<'EOF' ... EOF)` with a quoted delimiter only prints literal text.
LITERAL_CAT = re.compile(r"\$\(cat <<-?\s*(['\"])[A-Za-z_][A-Za-z0-9_]*\1\s*\)")
GITHUB_URL = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/(?:pull|issues)/\d+")
OPERATORS = ";&|()\n"
# A quoted or escaped `$` or backtick is literal; the lexer swaps in these
# stand-ins so expansion skips them, and literal() restores them.
QUOTED = str.maketrans({"$": "\x00", "`": "\x01"})
UNQUOTED = str.maketrans({"\x00": "$", "\x01": "`"})
MAX_BODY = 1 << 20
GIT_TIMEOUT = 5
UNKNOWN_DIRECTORY = (
    "cannot tell which directory gh runs in (a cd in a subshell, pipeline, "
    "background job, skipped branch, or to a missing directory); run gh after a plain cd"
)
UNKNOWN_REPO = "cannot tell which repository gh targets (GH_REPO is set conditionally)"
UNPARSEABLE = "cannot parse a command that mentions a co-review marker"
UNREADABLE = (
    "cannot read the body of a command that mentions a co-review marker; "
    "write the body to a file first and pass its literal path"
)
ANSI_C_QUOTED = (
    "cannot read a command that mentions a co-review marker inside $'...' "
    "(ANSI-C) quoting; write the body to a file first and pass its literal path"
)
OWN_COMMAND = (
    "post a co-review marker in its own command: only cd, assignments, "
    "export, unset, true, :, test, [, exit, or return may run before gh, since "
    "anything else may change the body or the repository before gh reads them"
)
RULE = (
    "Marker SHAs must be the full 40-hex id of a commit in the target "
    "repository: copy it from `git rev-parse`, never from memory. Fence or "
    "indent an example marker."
)


@dataclass
class Walk:
    """Shell state at the current segment. cwd None means unknown; an
    assigned value of None means the variable may or may not be set."""

    cwd: str | None
    home: str
    heredocs: list[str]
    hinted: bool
    assigned: dict = field(default_factory=dict)
    rewrites: bool = False
    conditional: bool = False


def split_heredocs(command: str) -> tuple[str, list[str], bool]:
    """(command without heredoc bodies, the bodies in order, and whether an
    unquoted heredoc body runs a command substitution).

    Tracks quotes and `$( )` nesting, so `'<<EOF'` stays text while the
    heredoc inside `"$(cat <<'EOF' ... EOF)"` is found. Comments are dropped."""
    out: list[str] = []
    bodies: list[str] = []
    pending: list[tuple[str, str, str]] = []
    expands = False
    stack = ["code"]
    i, n = 0, len(command)
    while i < n:
        c = command[i]
        top = stack[-1]
        if top == "'":
            if c == "'":
                stack.pop()
            out.append(c)
            i += 1
            continue
        if c == "\\":
            out.append(command[i : i + 2])
            i += 2
            continue
        if command.startswith("$(", i):
            stack.append("code")
            out.append("$(")
            i += 2
            continue
        if top == '"':
            if c == '"':
                stack.pop()
            out.append(c)
            i += 1
            continue
        if c == "#" and command[i - 1 : i] in ("", " ", "\t", "\n", ";", "&", "|", "(", ")"):
            stop = command.find("\n", i)
            i = n if stop < 0 else stop  # drop the comment, keep its newline
            continue
        match = HEREDOC.match(command, i)
        if c in "'\"":
            stack.append(c)
        elif c == "(":
            stack.append("code")
        elif c == ")" and len(stack) > 1:
            stack.pop()
        elif match and command[i - 1 : i] != "<" and not command.startswith("<<<", i):
            pending.append(match.groups())
            out.append(match.group(0))
            i = match.end()
            continue
        elif c == "\n" and pending:
            out.append(c)
            i += 1
            for dash, quote, delimiter in pending:
                body = []
                while i < n:
                    stop = command.find("\n", i)
                    line = command[i:] if stop < 0 else command[i:stop]
                    i = n if stop < 0 else stop + 1
                    if dash:
                        line = line.lstrip("\t")  # <<- strips leading tabs
                    if line == delimiter:
                        break
                    body.append(line)
                bodies.append("\n".join(body))
                expands = expands or (not quote and any("$(" in b or "`" in b for b in body))
            pending = []
            continue
        out.append(c)
        i += 1
    return "".join(out), bodies, expands


def scan_subst(command: str, start: int) -> int:
    """Index just past the '(' at `start`'s matching close, tracking nested
    parens and quotes the way split_heredocs tracks `$(` -- so an unquoted
    `$(...)` / `$((...))` is consumed whole instead of stopping at its first
    ')'."""
    depth, i, n = 0, start, len(command)
    while i < n:
        c = command[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            i = command.index("'", i + 1) + 1
            continue
        if c == '"':
            i += 1
            while command[i] != '"':
                i += 2 if command[i] == "\\" else 1
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def lex(command: str) -> list[tuple[str, bool]]:
    """(text, is_operator) tokens, quotes removed from words.

    The shared rm_guard tokenizer cannot tell a quoted ';' from a separator.
    An `&` touching `>` or `<` (`2>&1`, `&>`) stays part of the word."""
    tokens: list[tuple[str, bool]] = []
    word: list[str] = []
    started = False
    i = 0

    def flush():
        nonlocal word, started
        if started:
            tokens.append(("".join(word), False))
        word, started = [], False

    while i < len(command):
        c = command[i]
        if c == "\\":
            if command[i + 1 : i + 2] != "\n":
                word.append(command[i + 1 : i + 2].translate(QUOTED))
                started = True
            i += 2
        elif c == "'":
            end = command.index("'", i + 1)
            word.append(command[i + 1 : end].translate(QUOTED))
            started = True
            i = end + 1
        elif c == '"':
            i += 1
            while command[i] != '"':
                if command[i] == "\\" and command[i + 1] in '$`"\\\n':
                    i += 1
                    word.append(command[i].translate(QUOTED))
                else:
                    word.append(command[i])
                i += 1
            started = True
            i += 1
        elif c in " \t":
            flush()
            i += 1
        elif c in "<>" and started and not re.fullmatch(r"[0-9&<>]*", "".join(word)):
            flush()  # a redirection starts its own word: `body.md>/dev/null`
        elif c == "&" and (command[i - 1 : i] in "<>" and i > 0 or command[i + 1 : i + 2] == ">"):
            word.append(c)
            started = True
            i += 1
        elif c == "(" and word and word[-1] == "$":
            end = scan_subst(command, i)
            word.append(command[i:end])
            started = True
            i = end
        elif c in OPERATORS:
            flush()
            op = command[i : i + 2] if command[i : i + 2] in ("&&", "||") else c
            tokens.append((op, True))
            i += len(op)
        else:
            word.append(c)
            started = True
            i += 1
    flush()
    return tokens


def literal(text: str) -> str:
    return text.translate(UNQUOTED)


def expand_path(word: str, walk: Walk) -> str | None:
    """Expand $NAME from earlier assignments, then the environment."""

    def value(match):
        name = match.group(1) or match.group(2)
        if name in walk.assigned:
            return walk.assigned[name] if walk.assigned[name] is not None else "$"
        return os.environ.get(name, "$")

    path = VARIABLE.sub(value, word)
    if path == "~" or path.startswith("~/"):
        path = walk.home + path[1:]
    if "$" in path or "`" in path:
        return None
    return literal(path)


def absolute(path: str, walk: Walk) -> str | None:
    if os.path.isabs(path):
        return os.path.normpath(path)
    if walk.cwd is None:
        return None
    return os.path.normpath(os.path.join(walk.cwd, path))


def read_body(full: str) -> str | None:
    if not os.path.isfile(full):
        return None
    try:
        with open(full, "rb") as handle:
            return handle.read(MAX_BODY).decode("utf-8", errors="replace")
    except OSError:
        return None


def marker_lines(body: str):
    """(family row, line) for each marker line pr_ready_gate would see."""
    for raw in pr_ready_gate._top_level_lines(body):
        for row in FAMILIES:
            if raw.startswith(row[1]):
                yield row, raw
                break


def git(repo: str, *args: str):
    # A partial clone would otherwise fetch a missing object from its
    # promisor, and a replace ref could make a tree report itself a commit.
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(
            ["git", "-C", repo, *args],
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def format_problem(row, line: str) -> str | None:
    family, _, required, optional = row
    if not line.rstrip(" \t").endswith("-->"):
        return f"{family} marker is not closed with -->"
    pairs = [(k, v) for k, v in KEY_VALUE.findall(line) if k in required + optional]
    present = {k for k, _ in pairs}
    for key in required:
        if key not in present:
            return f"{family} marker has no {key}="
    for key, value in pairs:
        if not FULL_SHA.match(value):
            return f"{family} marker {key}={value} is not 40 lowercase hex"
    return None


def repo_problem(repo: str, target: str | None) -> str | None:
    probe = git(repo, "rev-parse", "--git-dir")
    if probe is None or probe.returncode != 0:
        return f"cannot verify marker SHAs: {repo} is not in a git repository"
    if not target:
        return None
    want = "/".join(target.lower().rstrip("/").split("/")[-2:])
    remotes = git(repo, "remote", "-v")
    if remotes is None or remotes.returncode != 0:
        return f"cannot list the remotes of {repo}"
    for line in remotes.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        url = fields[1].lower().rstrip("/")
        if url.endswith(".git"):
            url = url[: -len(".git")]
        if url.endswith("/" + want) or url.endswith(":" + want):
            return None
    return f"cannot verify marker SHAs: {target} is not a remote of {repo}"


def object_problem(row, line: str, repo: str) -> str | None:
    family, _, required, optional = row
    for key, value in KEY_VALUE.findall(line):
        if key not in required + optional:
            continue
        found = git(repo, "cat-file", "-t", value)
        if found is None:
            return f"cannot run git to verify {family} marker {key}={value}"
        if found.returncode != 0 or found.stdout.strip() != "commit":
            return f"{family} marker {key}={value} is not a commit in {repo}"
    return None


def target_repo(args: list[str], flag_repo: str | None, seg_env: dict, walk: Walk):
    """The repository gh targets: a string, "" for its cwd, None if unknown."""
    if flag_repo:
        return flag_repo
    for word in args:
        match = GITHUB_URL.match(word)
        if match:
            return f"{match.group(1)}/{match.group(2)}"
    if "GH_REPO" in seg_env:
        return seg_env["GH_REPO"]
    if "GH_REPO" in walk.assigned:
        return walk.assigned["GH_REPO"]
    return os.environ.get("GH_REPO", "")


def gh_sources(words: list[str], walk: Walk):
    """(bodies, unreadable, problem, repo flag, other args) of a gh segment."""
    bodies, unreadable, problem, flag_repo, args = [], False, None, None, []
    i = 3
    while i < len(words):
        word = words[i]
        flag, eq, value = word.partition("=") if word.startswith("--") else (word, "", "")
        i += 1
        if flag not in BODY_FLAGS + FILE_FLAGS + REPO_FLAGS:
            args.append(word)
            continue
        if not eq:
            value = words[i] if i < len(words) else ""
            i += 1
        if flag in REPO_FLAGS:
            flag_repo = value
        elif flag in BODY_FLAGS:
            bodies.append(literal(value))
            if "<<" in value:
                bodies.extend(walk.heredocs)
        elif value == "-":
            bodies.extend(walk.heredocs)
            unreadable = unreadable or not walk.heredocs
        else:
            path = expand_path(value, walk)
            full = absolute(path, walk) if path is not None else None
            if path is not None and full is None:
                problem = problem or UNKNOWN_DIRECTORY
            text = read_body(full) if full else None
            # The hook runs before the command: after an unsafe prefix the
            # file gh reads may differ from the one read here.
            if text is None or walk.rewrites:
                unreadable = True
            if text is not None:
                bodies.append(text)
    return bodies, unreadable, problem, flag_repo, args


def gh_words(words: list[str]) -> list[str]:
    """gh's words with attached short options split (`-Rowner/repo`,
    `-bTEXT`, `-FPATH`) and every -R/--repo option moved after the
    subcommand, since gh also accepts `gh -R owner/repo pr comment ...`."""
    split = []
    for word in words:
        if len(word) > 2 and word[0] == "-" and word[1] in "RbF":
            split += [word[:2], word[2:]]
        else:
            split.append(word)
    words = split
    moved, rest, i = [], [], 1
    while i < len(words):
        if words[i] in REPO_FLAGS:
            moved += words[i : i + 2]
            i += 2
        else:
            (moved if words[i].startswith("--repo=") else rest).append(words[i])
            i += 1
    return ["gh", *rest[:2], *moved, *rest[2:]]


def check_gh(words: list[str], seg_env: dict, walk: Walk) -> str | None:
    words = gh_words(words)
    if len(words) > 1 and words[1] == "api":
        return "cannot verify a co-review marker sent through gh api; use gh pr comment" if walk.hinted else None
    if tuple(words[1:3]) not in POSTING_VERBS:
        return None
    bodies, unreadable, problem, flag_repo, args = gh_sources(words, walk)
    if problem:
        return problem
    markers = [hit for body in bodies for hit in marker_lines(body)]
    for row, line in markers:
        problem = format_problem(row, line)
        if problem:
            return problem
    if markers and walk.rewrites:
        return OWN_COMMAND
    if markers and walk.cwd is None:
        return UNKNOWN_DIRECTORY
    if markers:
        target = target_repo(args, flag_repo, seg_env, walk)
        if target is None:
            return UNKNOWN_REPO
        target = literal(target)
        problem = repo_problem(walk.cwd, target)
        if problem:
            return problem
        for row, line in markers:
            problem = object_problem(row, line, walk.cwd)
            if problem:
                return problem
    if unreadable and walk.hinted:
        return UNREADABLE
    return None


def cd_target(words: list[str], walk: Walk) -> str | None:
    """The existing literal directory a cd moves to, else None (unknown)."""
    if len(words) != 2 or words[1] == "-":
        return None
    target = rm_guard.expand_home(words[1], walk.home)
    if "$" in target or "`" in target:
        return None
    target = literal(target)
    # bash searches CDPATH for a name that does not start with / . or ..
    if "CDPATH" in walk.assigned:
        cdpath = walk.assigned["CDPATH"]
    else:
        cdpath = os.environ.get("CDPATH", "")
    if not target.startswith(("/", ".")) and cdpath != "":
        return None
    full = absolute(target, walk)
    return full if full and os.path.isdir(full) else None


def without_literal_cat(word: str) -> str:
    return LITERAL_CAT.sub("", word)


def writes_file(words: list[str]) -> bool:
    """True when a word redirects output to a file (not `2>&1`, `/dev/null`)."""
    for i, word in enumerate(words):
        match = REDIRECT.match(word)
        if not match:
            continue
        target = match.group(1) or (words[i + 1] if i + 1 < len(words) else "")
        if not re.fullmatch(r"&[0-9-]*", target) and target != "/dev/null":
            return True
    return False


def visit(segment: list[str], before: str, after: str, walk: Walk) -> str | None:
    """Apply one segment to the walk state; return a denial reason or None.

    A cd or assignment is certain only at the start of a list and not piped
    or backgrounded; after `&&` a cd holds while the `&&` chain continues."""
    words = rm_guard.strip_prefixes(segment)
    while words and words[0] in RESERVED_WORDS:
        words = rm_guard.strip_prefixes(words[1:])
    prefix = segment[: len(segment) - len(words)]
    seg_env = dict(t.split("=", 1) for t in prefix if rm_guard.is_env_assignment(t))
    skipped = before in ("||", "|") or after in ("|", "&")
    head = rm_guard.basename(words[0]) if words else ""
    # A command substitution or an output redirection takes effect before
    # its segment runs, gh's own included.
    if writes_file(segment) or any("$(" in w or "`" in w for w in map(without_literal_cat, segment)):
        walk.rewrites = True
    if head == "gh":
        return check_gh(words, seg_env, walk)
    if head in rm_guard.SHELL_WRAPPERS:
        inner = rm_guard.extract_shell_c_arg(words)
        env = {**walk.assigned, **seg_env}
        # The script is re-parsed by the inner shell, so its `$` is live again.
        script = literal(inner) if inner is not None else None
        problem = check_command(script, walk.cwd, walk.home, walk.rewrites, env) if script is not None else None
        walk.rewrites = True  # the script may change files that later segments read
        return problem
    if words and head not in HARMLESS + ("export", "unset"):
        walk.rewrites = True
    if not words or head == "export":
        pairs = seg_env.items() if not words else (
            t.split("=", 1) for t in words[1:] if rm_guard.is_env_assignment(t)
        )
        for name, value in pairs:
            plain = "$" not in value and "`" not in value
            certain = before != "&&" and not skipped
            walk.assigned[name] = value if plain and certain else None
    elif head == "unset":
        for name in words[1:]:
            walk.assigned[name] = None if before == "&&" or skipped else ""
    elif head == "cd":
        walk.cwd = None if skipped else cd_target(words, walk)
        walk.conditional = before == "&&" and not skipped
    return None


def check_command(
    command: str, cwd: str | None, home: str, rewrites: bool = False, assigned: dict | None = None
) -> str | None:
    """Walk the command's segments in order, tracking directory and scope.

    rewrites and assigned carry an outer shell's state into `sh -c` scripts."""
    stripped, heredocs, expands = split_heredocs(command)
    hinted = any(hint in command for hint in MARKER_HINTS)
    if hinted and "$'" in stripped:
        return ANSI_C_QUOTED
    walk = Walk(cwd, home, heredocs, hinted, dict(assigned or {}), rewrites or expands)
    try:
        tokens = lex(stripped)
    except (ValueError, IndexError):  # an unterminated quote
        return UNPARSEABLE if hinted else None
    stack: list = []
    before = ";"
    words: list[str] = []
    for text, is_operator in tokens + [(";", True)]:
        if not is_operator:
            words.append(text)
            continue
        if words:
            problem = visit(words, before, text, walk)
            if problem:
                return problem
            words = []
        if text == "(":
            stack.append((walk.cwd, walk.conditional, dict(walk.assigned)))
            before = ";"
        elif text == ")":
            if stack:
                walk.cwd, walk.conditional, walk.assigned = stack.pop()
            before = ";"
        else:
            if walk.conditional and text != "&&":
                walk.cwd, walk.conditional = None, False
            before = text
    return None


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    invocation = rm_guard.shell_invocation(data)
    if invocation is None:
        return 0
    command, cwd = invocation
    if "gh" not in command:
        return 0
    home = os.environ.get("HOME", os.path.expanduser("~"))
    problem = check_command(command, cwd, home)
    if not problem:
        return 0
    print("Blocked: " + problem + ".", file=sys.stderr)
    print(RULE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
