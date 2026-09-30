#!/usr/bin/env python3
"""Gate agent-posted GitHub PR/issue writes by audience.

The gate applies to work repositories. A post whose target is a personal
repository (the -R/--repo, GH_REPO or api-path repository, else the cwd's
checkout under ~/Git/personal per workflow_context.account_scope) needs no
go: the owner is the only contributor there (2026-09-28).

Incident 2026-09-23: on rw-bess #2444 a co-review/herdr flow replied to a
human reviewer; on this repo's PR #170 the director posted after a
multiple-choice answer given without the text in view. Design 2026-09-29
(spec 2026-09-29-audience-posting-policy-design.md): maintenance and green
evidence on a PR this account authored post freely; text aimed at a person
needs the owner's go for that exact draft. Design 2026-09-29 (spec
2026-09-29-prompt-every-decision-design.md): that go is the owner's
AskUserQuestion answer, bound to one draft whose text the prompt showed.

Gate: decides only when HERDR_ENV=1; every other session exits 0 untouched
(no file I/O). Three events, one script, dispatched on hook_event_name, plus
a `draft` CLI:

- `draft -- gh <args>` records a gated call as shown (pending), keyed by a
  hash of its argv, the bytes it reads and where it lands, with the text
  it prints.
- PostToolUse AskUserQuestion approves a pending draft when the chosen
  option is `Post draft <hash>` and the draft's text is in that question or
  the option's preview; `Skip draft <hash>` dismisses it or withdraws its
  unspent approval. Typed prompts never approve.
- UserPromptSubmit records which session this Claude process is on for the
  shim, removes legacy files and prunes old state.
- PreToolUse Bash is the early second layer. The primary gate is the gh
  shim (bin/herdr-shims/gh -> gh_post_shim.py), which sees the final argv,
  reads the PR author, decides the audience and spends one approved draft
  per gated call. This hook denies a Bash call holding more reply calls
  than approved drafts, a path-qualified `gh`, and a login flag on a shell
  the PATH anchor does not re-run in. Anything it cannot parse passes; the
  shim decides it.

Override: none. Fixing a false positive means narrowing the classifier,
not bypassing it.

Boundary: a momentum guardrail against a well-meaning agent posting
through `gh` as found on PATH, not a security boundary (spec
2026-09-25-pr-post-gate-blockers-design.md, accepted by the owner
2026-09-26). Shell tricks that change how `gh` resolves, forged gate
state, raw HTTP with the token, and Codex sessions are accepted residuals.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rm_guard
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "co-review" / "scripts"))
from pr_ready_gate import MARKER_PREFIX, MARKER_RE

CONTEXT_PATH = Path(__file__).resolve().parents[1] / "skills" / "lib" / "workflow_context.py"

# The owner's answer to a post prompt (spec R2): `Post draft <hash>` approves
# that draft, `Skip draft <hash>` dismisses it; the tool may add the suffix.
DECISION_RE = re.compile(r"(Post|Skip) draft ([0-9a-f]{8})( \(Recommended\))?")

# GitHub sends no notification for a mention inside code.
FENCED_CODE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,}).*?(?:^ {0,3}\1[ \t]*$|\Z)", re.MULTILINE | re.DOTALL)
CODE_SPAN_RE = re.compile(r"(`+).+?\1", re.DOTALL)
MENTION_RE = re.compile(r"(?<![\w./@`])@[A-Za-z0-9]")
LINE_BREAK_RE = re.compile(r"\r\n|\r|\n")
BODY_FILE_SUBCOMMANDS = {("pr", "comment"), ("issue", "comment"), ("pr", "edit"), ("pr", "review")}
CLOSE_SUBCOMMANDS = {("pr", "close"), ("issue", "close")}
PRUNE_AGE = 86400
SID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
SHIM_MARK = b"gh_post_shim.py"
ORIGIN_RE = re.compile(r"[:/]([^/:]+)/[^/]+?(?:\.git)?/?$")
# `pr close -c`, `-cbye`, `-dc`, `--comment`, `--comment=bye`.
CLOSE_COMMENT_RE = re.compile(r"^(--comment(=|$)|-[a-z]*c)")
GH_VALUE_OPTIONS = ("-R", "--repo", "--hostname")
# Commands that run their argument as a program, and the runner options
# that take a value (`timeout -s KILL`, `sudo -u me`, `xargs -n 1`).
COMMAND_RUNNERS = {"timeout", "stdbuf", "nice", "nohup", "time", "xargs", "env", "sudo", "command", "exec", "watch"}
RUNNER_VALUE_FLAGS = {"-u", "-s", "-k", "-n", "-I", "-S", "-C", "-g", "-a"}
RUNNER_ARG_RE = re.compile(r"^\d+(\.\d+)?[smhd]?$")
UNANCHORED_SHELLS = {"sh", "dash", "ksh", "mksh", "csh", "tcsh", "fish"}
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{"}
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
GH_WORD_RE = re.compile(r"\bgh\b")
# `gh` as a command word in pane text; `fix-gh-shim` or `.gh` is not one.
PANE_GH_RE = re.compile(r"(?<![\w.-])gh(?![\w.-])")
SHELL_QUOTING_RE = re.compile(r"[\\'\"`]")
DELETE_PATH = re.compile(r"(issues|pulls)/comments/[^/\s]+$")
BODY_PATH = re.compile(r"(issues|pulls)/\d+$")
# Text aimed at a person whatever the PR: review comments, replies,
# reactions, and edits of an existing comment.
REPLY_PATH = re.compile(r"/replies$|pulls/\d+/comments$|pulls/\d+/reviews|/reactions$")
COMMENT_PATH = re.compile(r"(issues|pulls)/comments/\d+$")
ISSUE_COMMENT_PATH = re.compile(r"issues/\d+/comments$")
# Value flags of the gh subcommands whose target PR the shim reads (gh 2.94.0).
PR_VALUE_FLAGS = {
    ("pr", "comment"): {"-b", "--body", "-F", "--body-file"},
    ("issue", "comment"): {"-b", "--body", "-F", "--body-file"},
    ("pr", "review"): {"-b", "--body", "-F", "--body-file"},
    ("pr", "close"): {"-c", "--comment"},
    ("issue", "close"): {"-c", "--comment", "-r", "--reason", "--duplicate-of"},
    ("pr", "edit"): {
        "-b", "--body", "-F", "--body-file", "-t", "--title", "-B", "--base", "-m", "--milestone",
        "--add-assignee", "--add-label", "--add-project", "--add-reviewer",
        "--remove-assignee", "--remove-label", "--remove-project", "--remove-reviewer",
    },
}
FIELD_FLAGS = ("-f", "-F", "--raw-field", "--field", "--input")
# gh api flags whose value is the next argument (gh 2.94.0 --help).
VALUE_FLAGS = FIELD_FLAGS + (
    "-H", "--header", "-q", "--jq", "-t", "--template",
    "--hostname", "--cache", "-p", "--preview",
)

# `gh` subcommands that only ever read. `search` and `api` are handled by
# their own rules below (any `search` subcommand; `api` by method/path).
READ_SUBCOMMANDS = {
    ("pr", "view"), ("pr", "list"), ("pr", "checks"), ("pr", "diff"), ("pr", "status"),
    ("run", "view"), ("run", "list"), ("run", "watch"),
    ("issue", "view"), ("issue", "list"),
    ("repo", "view"),
    ("workflow", "list"), ("workflow", "view"),
    ("auth", "status"),
    # The token is already exported by zsh/.zprofile; git-credential keeps a
    # `gh auth setup-git` credential helper working in armed sessions.
    ("auth", "token"), ("auth", "git-credential"),
}

# One-word `gh` commands that only read.
READ_COMMANDS = {"status", "version", "help", "--version"}

# Non-comment `gh` writes this repo's own skills invoke. Like any other
# non-post call they classify "write" and pass; listed for reference.
KNOWN_WRITES = {
    ("pr", "create"),  # claude/commands/pr.md, claude/skills/voice
    ("pr", "merge"),   # claude/skills/ship/SKILL.md
    ("pr", "ready"), ("pr", "checkout"), ("repo", "clone"), ("run", "rerun"),
}


def _context():
    spec = importlib.util.spec_from_file_location("dotfiles_workflow_context", CONTEXT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def personal_repository(cwd: str) -> bool:
    """True when `cwd` is in a personal repository; any lookup error is False
    so the gate stays on."""
    try:
        return bool(_context().account_scope(cwd, "claude")["personal_repository"])
    except Exception:  # noqa: BLE001
        return False


def personal_owner(owner: str, cwd: str) -> bool:
    """True when `owner` is the personal GitHub login. workflow_context keeps
    no login, so it is the origin owner of the personal checkout at `cwd`."""
    try:
        if not personal_repository(cwd):
            return False
        url = _context().git(cwd, "remote", "get-url", "origin")
    except Exception:  # noqa: BLE001
        return False
    hit = ORIGIN_RE.search(url)
    return bool(hit) and hit.group(1).lower() == owner.lower()


def target_slug(args: list[str]) -> str | None:
    """Repository a gh call writes to, as given (`[HOST/]owner/name`): the
    api path's repos/<owner>/<name>, else -R/--repo, else GH_REPO. None
    means the cwd's repository."""
    slug = None
    i, _verb = subcommand_index(args)
    if i < len(args) and args[i] == "api":
        _method, path, host, _field = parse_api(normalize_api_args(args[i + 1:]) or args[i + 1:])
        hit = re.match(r"repos/([^/{]+)/([^/{]+)", path or "")
        prefix = f"{host}/" if host else ""
        slug = f"{prefix}{hit.group(1)}/{hit.group(2)}" if hit else None
    for j, tok in enumerate(args):
        if slug:
            break
        if tok in ("-R", "--repo") and j + 1 < len(args):
            slug = args[j + 1]
        elif tok.startswith("--repo="):
            slug = tok.split("=", 1)[1]
        elif tok.startswith("-R") and len(tok) > 2 and not tok.startswith("--"):
            slug = tok[2:]
    return slug or os.environ.get("GH_REPO") or None


def target_repo(args: list[str]) -> str | None:
    """`owner` of the repository a gh call writes to; None means the cwd's."""
    slug = target_slug(args)
    if not slug:
        return None
    parts = slug.split("/")
    return parts[-2] if len(parts) >= 2 else slug


def git_output(cwd: str, *args: str) -> str:
    """Stdout of a local git command in `cwd`, or "" on any failure."""
    try:
        done = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout if done.returncode == 0 else ""


def target_context(args: list[str], cwd: str) -> dict:
    """What decides where a gh call lands (spec R3): the remotes entry pins
    the repository and host gh resolves from git, with no network."""
    return {
        "cwd": os.path.realpath(cwd),
        "gh_repo": os.environ.get("GH_REPO", ""),
        "gh_host": os.environ.get("GH_HOST", ""),
        "slug": target_slug(args) or "",
        "remotes": git_output(cwd, "config", "--get-regexp", r"^remote\."),
    }


def _digest(record: dict) -> str:
    return hashlib.sha256(json.dumps(record, sort_keys=True).encode("utf-8")).hexdigest()


def repo_key(args: list[str], cwd: str) -> str:
    return _digest(target_context(args, cwd))[:16]


def draft_files(args: list[str]) -> list[str]:
    """Files a gh call reads its text from: body files, then typed `@path`
    fields and --input for gh api."""
    i, j = subcommand_index(args)
    if i < len(args) and args[i] == "api":
        api = normalize_api_args(args[i + 1:]) or args[i + 1:]
        paths = [value[1:] for typed, _key, value in api_fields(api) if typed and value.startswith("@")]
        path = input_path(api)
        return paths + ([path] if path is not None else [])
    sub = tuple(args[k] for k in (i, j) if k < len(args))
    if sub in BODY_FILE_SUBCOMMANDS:
        path = flag_value(args[j + 1:], ("-F", "--body-file"))
        return [path] if path is not None else []
    return []


def draft_hash(args: list[str], cwd: str) -> str | None:
    """8-hex id binding a gh call's argv, the bytes it reads and where it
    lands (spec R7); None when its text comes from stdin or cannot be read."""
    if post_body(args, cwd)[0] == "unreadable":
        return None
    digests = []
    for path in draft_files(args):
        if path in ("-", ""):
            return None
        try:
            with open(os.path.join(cwd, path), "rb") as handle:
                digests.append(hashlib.sha256(handle.read()).hexdigest())
        except OSError:
            return None
    return _digest({
        "argv": list(args),
        "context": target_context(args, cwd),
        "branch": git_output(cwd, "rev-parse", "--abbrev-ref", "HEAD").strip(),
        "files": digests,
    })[:8]


def exempt_from_go(args: list[str], cwd: str) -> bool:
    """A post to a personal repository needs no go: the explicit target's
    owner when there is one, else the cwd's repository."""
    owner = target_repo(args)
    return personal_repository(cwd) if owner is None else personal_owner(owner, cwd)


def flag_value(args: list[str], names: tuple[str, ...]) -> str | None:
    """Last value given to one of `names`: `--x v`, `--x=v`, `-x v` or `-xv`."""
    value, k = None, 0
    while k < len(args):
        tok = args[k]
        for name in names:
            if tok == name and k + 1 < len(args):
                value = args[k + 1]
                k += 1
                break
            if name.startswith("--") and tok.startswith(name + "="):
                value = tok[len(name) + 1:]
                break
            if not name.startswith("--") and tok.startswith(name) and len(tok) > 2 and not tok.startswith("--"):
                value = tok[2:].removeprefix("=")
                break
        k += 1
    return value


def read_text(path: str, cwd: str) -> tuple[str, str | None]:
    """("text", contents) of a UTF-8 file; stdin or a failed read is unreadable."""
    if path in ("-", ""):
        return "unreadable", None
    try:
        with open(os.path.join(cwd, path), "rb") as handle:
            return "text", handle.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return "unreadable", None


def api_fields(args: list[str]) -> list[tuple[bool, str, str]]:
    """(typed, key, value) of each field in a normalized `gh api` argv;
    typed fields (-F/--field) read `@path` values from a file."""
    fields, i = [], 0
    while i < len(args):
        tok = args[i]
        if tok in ("-f", "-F", "--raw-field", "--field") and i + 1 < len(args):
            typed, raw, i = tok in ("-F", "--field"), args[i + 1], i + 2
        elif tok.startswith(("--raw-field=", "--field=")):
            typed, raw, i = tok.startswith("--field="), tok.split("=", 1)[1], i + 1
        else:
            i += 1
            continue
        key, _, value = raw.partition("=")
        fields.append((typed, key, value))
    return fields


def input_path(args: list[str]) -> str | None:
    for i, tok in enumerate(args):
        if tok == "--input" and i + 1 < len(args):
            return args[i + 1]
        if tok.startswith("--input="):
            return tok.split("=", 1)[1]
    return None


def pr_target(args: list[str]) -> tuple[str | None, str | None]:
    """(selector, slug) of the PR a post or body call writes to; a None
    selector is the current branch, a None slug the cwd's repository."""
    i, j = subcommand_index(args)
    slug = target_slug(args)
    if i < len(args) and args[i] == "api":
        path = parse_api(normalize_api_args(args[i + 1:]) or args[i + 1:])[1] or ""
        hit = re.search(r"(?:issues|pulls)/(\d+)", path)
        return (hit.group(1) if hit else None), slug
    sub = tuple(args[k] for k in (i, j) if k < len(args))
    values = PR_VALUE_FLAGS.get(sub, set()) | {"-R", "--repo"}
    k = j + 1
    while k < len(args):
        tok = args[k]
        if tok == "--":
            return (args[k + 1] if k + 1 < len(args) else None), slug
        if tok in values:
            k += 2
            continue
        if not tok.startswith("-"):
            return tok, slug
        k += 1
    return None, slug


def gated_reason(kind: str, own: bool, body: tuple[str, str | None]) -> str:
    state, text = body
    if kind == "reply":
        return "a reply to a person (review, thread reply, reaction or comment edit)"
    if state == "unreadable":
        return "a body the shim cannot read (stdin, an editor or a missing file)"
    if not own:
        return "a write to a PR this account did not author"
    if state == "none":
        return "a comment with no body"
    if mentions_person(text):
        return "a body that @mentions someone"
    return "a non-APPROVE co-review marker"


ASK_OWNER = (
    "then ask with AskUserQuestion, one single-select question per draft: options "
    "`Post draft <hash>` and `Skip draft <hash>`, the draft text in the question or "
    "the post option's preview. Post only after the answer approves it.\n"
    "An answer that printed no `post gate:` line means the answer hook is not active "
    "in this session: ask the owner to run `update --ai` and restart Claude, and "
    "leave the draft in the report instead of asking again."
)


def gated_denial(reason: str, args: list[str]) -> str:
    return (
        f"Blocked: {reason} needs the owner's go.\n"
        f"Register it with `{DRAFT_COMMAND} {shlex.join(args)}`, {ASK_OWNER}"
    )


def check_replies(kinds: list[str], sid: str, directory: Path) -> str | None:
    """Early layer: a Bash call may hold at most as many reply calls as the
    session has approved drafts. The shim binds each one at exec."""
    wanted = kinds.count("reply")
    if not wanted:
        return None
    if SID_RE.match(sid) and approved_count(directory, sid) >= wanted:
        return None
    return (
        "Blocked: a PR review, thread reply, reaction or comment edit needs an "
        "approved draft for each call.\n"
        f"Register each with `{DRAFT_COMMAND} <args>`, {ASK_OWNER}"
    )


def api_body(args: list[str], cwd: str) -> tuple[str, str | None]:
    for typed, key, value in api_fields(args):
        if key == "body":
            return read_text(value[1:], cwd) if typed and value.startswith("@") else ("text", value)
    path = input_path(args)
    if path is None:
        return "none", None
    state, raw = read_text(path, cwd)
    if state != "text":
        return state, None
    try:
        data = json.loads(raw)
    except ValueError:
        return "unreadable", None
    body = data.get("body") if isinstance(data, dict) else None
    return ("text", body) if isinstance(body, str) else ("none", None)


def post_body(args: list[str], cwd: str) -> tuple[str, str | None]:
    """(state, text) a post or body call sends. State is "none" (no body
    argument), "text", or "unreadable" (stdin, an editor, a bad file)."""
    i, j = subcommand_index(args)
    if i < len(args) and args[i] == "api":
        return api_body(normalize_api_args(args[i + 1:]) or args[i + 1:], cwd)
    sub = tuple(args[k] for k in (i, j) if k < len(args))
    rest = args[j + 1:]
    if sub in CLOSE_SUBCOMMANDS:
        text = flag_value(rest, ("-c", "--comment"))
        return ("none", None) if text is None else ("text", text)
    if sub not in BODY_FILE_SUBCOMMANDS:
        return "none", None
    if any(t in ("-e", "--editor", "-w", "--web") for t in rest):
        return "unreadable", None
    path = flag_value(rest, ("-F", "--body-file"))
    if path is not None:
        return read_text(path, cwd)
    text = flag_value(rest, ("-b", "--body"))
    return ("none", None) if text is None else ("text", text)


def mentions_person(text: str) -> bool:
    """An `@login` outside fenced code and inline code spans."""
    text = CODE_SPAN_RE.sub("", FENCED_CODE_RE.sub("", text))
    return MENTION_RE.search(text) is not None


def audience(kind: str, own: bool, body: tuple[str, str | None]) -> str:
    """"maintenance", "green", "own-comment" or "gated" for a post, body or
    reply call (spec R2): only gated needs the owner's go in a work repo."""
    state, text = body
    if kind == "reply" or not own or state == "unreadable":
        return "gated"
    if state == "none":
        return "maintenance" if kind == "body" else "gated"
    if mentions_person(text):
        return "gated"
    if kind == "body":
        return "maintenance"
    first = LINE_BREAK_RE.split(text, maxsplit=1)[0].rstrip(" \t")
    if first.startswith(MARKER_PREFIX):
        hit = MARKER_RE.match(first)
        return "green" if hit and hit.group("verdict") == "APPROVE" else "gated"
    return "own-comment"


def drop_heredoc_bodies(command: str) -> str:
    out, term = [], None
    for line in command.split("\n"):
        if term is not None:
            if line.strip() == term:
                term = None
            continue
        out.append(line)
        hit = HEREDOC_RE.search(line)
        if hit:
            term = hit.group(2)
    return "\n".join(out)


def join_continuations(command: str) -> str:
    """Drop an unquoted backslash-newline pair the way bash does before any
    tokenizing, so a `gh` call split across lines (round-3 blocker V-1:
    `gh api -X POST \\` then the rest on the next line) cannot dodge
    classification. Quote-aware like rm_guard.strip_line_comments, so a
    literal backslash-newline inside a quoted string is left alone."""
    out = []
    quote = None
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                i += 1
                out.append(command[i])
            elif ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "\\" and i + 1 < n and command[i + 1] == "\n":
            i += 1  # drop both the backslash and the newline
        elif ch == "\\" and i + 1 < n:
            out.append(ch)
            i += 1
            out.append(command[i])
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def strict_tokenize(command: str) -> list[str] | None:
    """A local copy of rm_guard.tokenize's shlex setup that returns None on
    a ValueError instead of rm_guard's naive whitespace-split fallback: a
    corrupted split is exactly the class of bug this gate exists to catch
    (round-3 minor: the ValueError path is reachable and fail-open via
    ANSI-C `$'...'` quoting). Duplicated rather than changing rm_guard.py,
    whose fallback is still correct for its own, more forgiving callers."""
    try:
        lexer = shlex.shlex(
            rm_guard.strip_line_comments(command),
            posix=True,
            punctuation_chars=rm_guard.SEGMENT_OPERATORS,
        )
        lexer.whitespace_split = True
        lexer.whitespace = lexer.whitespace.replace("\n", "")
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        return None


def mentions_gh(text: str) -> bool:
    return GH_WORD_RE.search(text) is not None


def unquoted(text: str) -> str:
    """Drop the quotes, backslashes and backticks a shell removes, so `g""h`
    and `g\\h` read as `gh`."""
    return SHELL_QUOTING_RE.sub("", text)


def find_gh_index(tokens: list[str]) -> int | None:
    for i, tok in enumerate(tokens):
        if rm_guard.basename(tok) == "gh":
            return i
    return None


def graphql_query_from_file(args: list[str]) -> bool:
    """A query read from a file or stdin can hold a mutation this cannot see:
    `--input`, or a typed field (`-F`/`--field`) whose value is `@file`."""
    for j, arg in enumerate(args):
        if arg == "--input" or arg.startswith("--input="):
            return True
        typed = arg.startswith(("-F", "--field=")) or (j and args[j - 1] in ("-F", "--field"))
        if typed and "=@" in arg:
            return True
    return False


# gh api's short flags (gh 2.96 `gh api --help`): -i/-h take no value.
API_BOOL_SHORTS = set("ih")
API_VALUE_SHORTS = set("XfFHqtp")


def normalize_api_args(args: list[str]) -> list[str] | None:
    """Split gh api's argv the way pflag does: a short cluster such as `-iX`
    becomes `-i -X`, a value flag takes the rest of its word or the next
    argument (even one starting with `-`), and `-X=GET` drops the `=`.
    None for a short flag gh api does not have."""
    out, i = [], 0
    while i < len(args):
        tok = args[i]
        i += 1
        if tok == "--":
            return out + [tok] + args[i:]
        if not tok.startswith("-") or tok == "-" or tok.startswith("--"):
            out.append(tok)
            if tok in VALUE_FLAGS + ("--method",) and i < len(args):
                out.append(args[i])
                i += 1
            continue
        rest = tok[1:]
        while rest:
            flag, rest = rest[0], rest[1:]
            if flag in API_BOOL_SHORTS:
                out.append("-" + flag)
                continue
            if flag not in API_VALUE_SHORTS:
                return None
            if rest:
                value = rest[1:] if rest[0] == "=" else rest
            elif i < len(args):
                value = args[i]
                i += 1
            else:
                return None
            out += ["-" + flag, value]
            rest = ""
    return out


def parse_api(args: list[str]) -> tuple[str | None, str | None, str | None, bool]:
    """(method, path, hostname, has_field) of one `gh api` argv."""
    method, path, host, has_field, i = None, None, None, False, 0
    args = normalize_api_args(args) or list(args)
    while i < len(args):
        tok = args[i]
        if tok in ("-X", "--method") and i + 1 < len(args):
            method, i = args[i + 1].upper(), i + 2
            continue
        if tok == "--hostname" and i + 1 < len(args):
            host = args[i + 1]
        if tok in VALUE_FLAGS:
            has_field = has_field or tok in FIELD_FLAGS
            i += 2
            continue
        if tok.startswith("--method="):
            method = tok.split("=", 1)[1].upper()
        elif tok.startswith("--hostname="):
            host = tok.split("=", 1)[1]
        elif tok.startswith("-X") and len(tok) > 2:
            method = tok[2:].upper()
        elif tok[:2] in ("-f", "-F") or tok.startswith(("--raw-field=", "--field=", "--input=")):
            has_field = True
        elif not tok.startswith("-") and path is None:
            path = tok.lstrip("/")
        i += 1
    return method, path, host, has_field


def classify_api(args: list[str]) -> str:
    normalized = normalize_api_args(args)
    if normalized is None:
        return "write"
    method, path, _host, has_field = parse_api(normalized)
    if path is not None:
        path = re.split(r"[?#]", path, maxsplit=1)[0]
    if path == "graphql":
        if graphql_query_from_file(normalized) or any("mutation" in a for a in normalized):
            return "reply"
        return "read"
    method = method or ("POST" if has_field else "GET")
    if method == "GET":
        return "read"
    if path is None:
        return "write"
    if method == "DELETE":
        return "delete" if DELETE_PATH.search(path) else "write"
    if REPLY_PATH.search(path) or COMMENT_PATH.search(path):
        return "reply"
    if any(key == "in_reply_to" for _typed, key, _value in api_fields(normalized)):
        return "reply"
    if ISSUE_COMMENT_PATH.search(path):
        return "post"
    if BODY_PATH.search(path):
        return "body"
    return "write"


def subcommand_index(args: list[str]) -> tuple[int, int]:
    """Indexes of the first two non-option words (len(args) when absent).
    Options may sit before either word; -R/--repo/--hostname take a value."""
    found, i = [], 0
    while i < len(args) and len(found) < 2:
        if not args[i].startswith("-"):
            found.append(i)
        elif args[i] in GH_VALUE_OPTIONS:
            i += 1
        i += 1
    found += [len(args)] * (2 - len(found))
    return found[0], found[1]


def classify_gh(args: list[str]) -> str:
    """Classify one gh invocation's argv (after the gh token): "read", "write" (never gated), "post" and "body" (gated unless the PR is this account's own, decided by the shim), "reply" (text aimed at a person, always gated in a work repo), or "delete" (own co-review marker only)."""
    if args[-1:] in (["-h"], ["--help"]) and (len(args) < 2 or not args[-2].startswith("-")):
        # Help on any command; `--body --help` still posts "--help".
        return "read"
    if args[:1] and args[0] in READ_COMMANDS:
        return "read"
    i, j = subcommand_index(args)
    sub = tuple(args[k] for k in (i, j) if k < len(args))
    rest = args[j + 1:]
    if sub[:1] == ("api",):
        return classify_api(args[i + 1:])
    if sub[:1] == ("search",):
        return "read"
    if sub in READ_SUBCOMMANDS:
        return "read"
    if sub in KNOWN_WRITES:
        return "write"
    if sub in CLOSE_SUBCOMMANDS:
        return "post" if any(CLOSE_COMMENT_RE.match(t) for t in rest) else "write"
    if sub == ("pr", "review"):
        return "reply"
    if sub in (("pr", "comment"), ("issue", "comment")):
        return "post"
    if sub == ("pr", "edit"):
        return "body"
    return "write"
    if sub in (("pr", "comment"), ("pr", "review"), ("issue", "comment")):
        return "post"
    if sub == ("pr", "edit"):
        return "body"
    return "write"


def effective_command(stripped: list[str]) -> list[str]:
    """The command a segment runs once leading runners, their options and
    durations are skipped: `timeout 60 bash -c ...` runs `bash -c ...`, and
    `env -u X git add bin/herdr-shims/gh` runs `git`."""
    i = 0
    while i < len(stripped):
        tok = stripped[i]
        if tok in RUNNER_VALUE_FLAGS:
            i += 2
        elif tok.startswith("-") or RUNNER_ARG_RE.match(tok) or rm_guard.basename(tok) in COMMAND_RUNNERS:
            i += 1
        else:
            break
    return stripped[i:]


def path_qualified_gh(command: list[str]) -> bool:
    """A `gh` run by path skips the shim's PATH lookup."""
    return bool(command) and rm_guard.basename(command[0]) == "gh" and "/" in command[0]


def split_backticks(command: str) -> str:
    """Turn each unquoted backtick into a segment break, so the command a
    `` `...` `` substitution runs, or the path it builds, is checked like
    any other segment. Single- and double-quoted text is left alone."""
    out, quote = [], None
    for ch in command:
        if quote:
            quote = None if ch == quote else quote
            out.append(ch)
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        else:
            out.append(" ; " if ch == "`" else ch)
    return "".join(out)


def shell_flags(seg: list[str]) -> list[str]:
    """Leading option words of a shell invocation (`--emulate` takes a value)."""
    flags, i = [], 1
    while i < len(seg) and seg[i].startswith("-"):
        flags.append(seg[i])
        i += 2 if seg[i] == "--emulate" else 1
    return flags


def uncovered_login_shell(seg: list[str]) -> bool:
    """A login shell the PATH anchor does not re-run in: its profile
    re-derives PATH and can put the real gh ahead of the shim."""
    if not seg:
        return False
    shell = rm_guard.basename(seg[0])
    flags = shell_flags(seg)
    short = [f for f in flags if not f.startswith("--")]
    if not ("--login" in flags or any("l" in f[1:] for f in short)):
        return False
    if shell == "bash":
        # BASH_ENV is skipped in POSIX mode and in interactive shells.
        return "--posix" in flags or any(c in f[1:] for f in short for c in "pi")
    if shell == "zsh":
        return "--emulate" in flags
    return shell in UNANCHORED_SHELLS


def herdr_pane_text_mentions_gh(seg: list[str]) -> bool:
    """`herdr pane run|send-text|send-keys` runs text in another pane's shell,
    which is not armed; quotes and backslashes are dropped before the check
    because that shell will drop them too."""
    if len(seg) < 3 or rm_guard.basename(seg[0]) != "herdr" or seg[1] != "pane":
        return False
    if seg[2] not in ("run", "send-text", "send-keys"):
        return False
    return PANE_GH_RE.search(unquoted(" ".join(seg[3:]))) is not None


def classify(command: str, depth: int = 0, cwd: str = "") -> tuple[list[str], list[str]]:
    """Return (gated_kinds, denials) for `command`. The gh shim is the
    primary gate and sees the final argv; this is the early second layer.
    `gated_kinds` are the post, body, reply and delete calls outside personal repositories (a post to a personal repository, judged
    against `cwd`, is left out). `denials` are the routes that skip the
    shim (a path-qualified gh, a login shell the anchor misses, gh sent to
    another pane) and no go covers them. Anything this cannot parse or classify passes: the shim
    decides it at exec."""
    working = split_backticks(drop_heredoc_bodies(join_continuations(command)))
    tokens = strict_tokenize(working)
    if tokens is None:
        return [], []
    kinds: list[str] = []
    denials: list[str] = []
    for seg in rm_guard.split_segments(tokens):
        while seg and seg[0] in KEYWORDS:
            seg = seg[1:]
        run = effective_command(rm_guard.strip_prefixes(seg))
        if uncovered_login_shell(run):
            denials.append(f"a login `{rm_guard.basename(run[0])}` can put the real `gh` ahead of the gh shim")
            continue
        if herdr_pane_text_mentions_gh(run):
            denials.append("`gh` sent to another herdr pane runs in a shell without the gh shim")
            continue
        if not mentions_gh(" ".join(seg)):
            continue
        if path_qualified_gh(run):
            denials.append("a path-qualified `gh` skips the gh shim")
            continue
        head = rm_guard.basename(run[0]) if run else None
        if head == "gh":
            kind = classify_gh(run[1:])
            if kind in ("post", "body", "reply", "delete") and not exempt_from_go(run[1:], cwd):
                kinds.append(kind)
        elif (head in rm_guard.SHELL_WRAPPERS or head == "eval") and depth == 0:
            script = (
                " ".join(run[1:]) if head == "eval"
                else rm_guard.extract_shell_c_arg(run)
            )
            if script:
                sub_kinds, sub_denials = classify(script, depth + 1, cwd)
                kinds.extend(sub_kinds)
                denials.extend(sub_denials)
    return kinds, denials


def gate_dir() -> Path:
    base = os.environ.get("DOTFILES_POST_GATE_DIR")
    if base:
        return Path(base)
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "dotfiles" / "post-gate"


def read_json(path: Path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _unlink(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def write_atomic(path: Path, text: str) -> None:
    """Replace `path` with `text` (mode 0600), whole or not at all."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temp, path)
    except OSError:
        _unlink(temp)
        raise


DRAFT_COMMAND = "python3 ~/.claude/hooks/pr_post_guard.py draft -- gh"


def draft_path(directory: Path, sid: str, digest: str, state: str) -> Path:
    """A draft's one file; the suffix is its state (pending, approved,
    dismissed, spent) and every change of state is one rename."""
    return directory / f"{sid}.draft-{digest}.{state}"


def drafts(directory: Path, sid: str, state: str) -> list[Path]:
    try:
        return sorted(directory.glob(f"{sid}.draft-*.{state}"))
    except OSError:
        return []


def _move(src: Path, dst: Path) -> bool:
    try:
        os.rename(src, dst)
    except OSError:
        return False
    return True


def _move_fresh(src: Path, dst: Path) -> bool:
    """Rename, then restart the prune clock: rename keeps the registration mtime."""
    if not _move(src, dst):
        return False
    try:
        os.utime(dst)
    except OSError:
        pass
    return True


def register_draft(directory: Path, sid: str, digest: str, args: list[str], text: str | None, now: float) -> bool:
    """Record a draft as shown (pending) with the text it shows; False when
    it is already approved."""
    if draft_path(directory, sid, digest, "approved").exists():
        return False
    record = {"v": 3, "created": now, "argv": list(args), "text": text}
    write_atomic(draft_path(directory, sid, digest, "pending"), json.dumps(record))
    _unlink(draft_path(directory, sid, digest, "dismissed"))
    return True


def shown(text, question: str, preview: str) -> bool:
    """The draft's text is in the question or the post option's preview,
    whitespace-normalized; a draft with no text shows only its hash."""
    if not isinstance(text, str) or not text.strip():
        return True
    return " ".join(text.split()) in " ".join((question + "\n" + preview).split())


def approve_draft(directory: Path, sid: str, digest: str, question: str, preview: str) -> str:
    """Approve a pending draft the owner chose to post (spec R3 step 5);
    returns the context line."""
    pending = draft_path(directory, sid, digest, "pending")
    if not pending.exists():
        if draft_path(directory, sid, digest, "approved").exists():
            return f"draft {digest} already approved; post it"
        if draft_path(directory, sid, digest, "spent").exists():
            return f"draft {digest} already posted once; read the PR, then register it again to post again"
        return f"draft {digest} not approved: no pending draft in this session; register it and ask again"
    record = read_json(pending)
    if (
        not isinstance(record, dict) or record.get("v") != 3 or "text" not in record
        or not (record["text"] is None or isinstance(record["text"], str))
    ):
        return f"draft {digest} not approved: its record is unreadable or predates prompt approval; register it again"
    if not shown(record["text"], question, preview):
        return f"draft {digest} not approved: its text was not in the question or the option's preview"
    if not _move_fresh(pending, draft_path(directory, sid, digest, "approved")):
        return f"draft {digest} not approved: no pending draft in this session; register it and ask again"
    return f"approved draft {digest}"


def dismiss_draft(directory: Path, sid: str, digest: str) -> str:
    """Skip a pending draft, or withdraw an approval not yet spent (spec R3
    step 4); returns the context line."""
    dismissed = draft_path(directory, sid, digest, "dismissed")
    if _move_fresh(draft_path(directory, sid, digest, "pending"), dismissed):
        return f"draft {digest} skipped"
    if _move_fresh(draft_path(directory, sid, digest, "approved"), dismissed):
        return f"draft {digest} approval withdrawn"
    if draft_path(directory, sid, digest, "spent").exists():
        return f"draft {digest} not skipped: already posted; read the PR"
    return f"draft {digest} skipped (nothing to withdraw)"


def answer_decisions(response: dict) -> list[tuple[str, str, str, str, str | None]]:
    """(verb, digest, question, preview, why_undecided) for each draft a
    question names in its option labels (spec R3); why_undecided is None
    when the chosen option decides it."""
    answers = response.get("answers") if isinstance(response.get("answers"), dict) else {}
    questions = response.get("questions")
    if not isinstance(questions, list):
        return []
    stale = None
    if response.get("afkTimeoutMs"):
        stale = "the prompt timed out"
    elif response.get("followUp"):
        stale = "the owner asked for more questions"
    found = []
    for question in questions:
        if not isinstance(question, dict):
            continue
        text = question.get("question") if isinstance(question.get("question"), str) else ""
        options = question.get("options") if isinstance(question.get("options"), list) else []
        named = []
        for option in options:
            label = option.get("label") if isinstance(option, dict) else None
            hit = DECISION_RE.fullmatch(label) if isinstance(label, str) else None
            if hit:
                named.append((option, hit))
        if not named:
            continue
        why = stale
        if not why and len({hit.group(2) for _option, hit in named}) > 1:
            why = "the question names more than one draft"
        if not why and question.get("multiSelect"):
            why = "a multi-select question cannot approve"
        chosen = next((pair for pair in named if pair[0]["label"] == answers.get(text)), None)
        if chosen and not why:
            option, hit = chosen
            preview = option.get("preview")
            found.append((hit.group(1), hit.group(2), text, preview if isinstance(preview, str) else "", None))
            continue
        why = why or "no Post or Skip option was chosen"
        for digest in dict.fromkeys(hit.group(2) for _option, hit in named):
            found.append(("", digest, text, "", why))
    return found


def spend_draft(directory: Path, sid: str, digest: str) -> bool:
    """Claim an approved draft for one exec; the rename has a single winner."""
    spent = draft_path(directory, sid, digest, "spent")
    return _move_fresh(draft_path(directory, sid, digest, "approved"), spent)


def approved_count(directory: Path, sid: str) -> int:
    return len(drafts(directory, sid, "approved"))


def _unclassified_denial(reason: str) -> str:
    return (
        f"Blocked: {reason}.\n"
        "Run plain `gh` as found on PATH, not from a login `sh`; "
        "no approved draft covers this."
    )


def is_shim(path: str) -> bool:
    """A gh shim names gh_post_shim.py in its first bytes; real gh does not."""
    try:
        with open(path, "rb") as handle:
            return SHIM_MARK in handle.read(512)
    except OSError:
        return False


def shim_armed() -> bool:
    """The hook's PATH is the Claude process's, the base of every Bash
    call's PATH (the shell snapshot), so this is what Bash will run."""
    found = shutil.which("gh")
    return found is not None and is_shim(found)


def shim_session_id() -> str:
    """Session id for the shim: the hook's pid map first (it follows
    /clear), then CLAUDE_CODE_SESSION_ID."""
    pid = os.environ.get("CLAUDE_PID", "")
    if pid.isdigit():
        try:
            with open(gate_dir() / f"pid-{pid}.sid", encoding="utf-8") as handle:
                mapped = handle.read().strip()
        except OSError:
            mapped = ""
        if SID_RE.match(mapped):
            return mapped
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    return sid if SID_RE.match(sid) else ""


def _unarmed_denial() -> str:
    return (
        "Blocked: `gh` on this session's PATH is not the herdr gh shim, so "
        "no `gh` call can be gated.\nRelaunch the agent through claude(), "
        "codex() or the herdr dispatcher, which arm the shim."
    )


def prune(directory: Path, now: float) -> None:
    try:
        entries = list(directory.iterdir())
    except OSError:
        return
    for entry in entries:
        try:
            if now - entry.stat().st_mtime > PRUNE_AGE:
                entry.unlink()
        except OSError:
            continue


def write_pid_map(directory: Path, sid: str) -> None:
    """Record which session this Claude process (the hook's parent) is on,
    so the shim can find its drafts after a /clear changes the session id.
    A failure only costs the /clear fallback."""
    try:
        write_atomic(directory / f"pid-{os.getppid()}.sid", sid)
    except OSError:
        pass


def handle_prompt(payload: dict, directory: Path, now: float) -> None:
    """A typed prompt approves nothing (spec R5): it records the pid map,
    removes legacy files and prunes."""
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not SID_RE.match(sid):
        return
    for legacy in ("json", "post-used", "body-used", "batch"):
        _unlink(directory / f"{sid}.{legacy}")
    write_pid_map(directory, sid)
    prune(directory, now)


def handle_answer(payload: dict, directory: Path) -> str | None:
    """PostToolUse AskUserQuestion: the owner's chosen option approves or
    skips one draft per question (spec R3). Returns the context lines; every
    draft a question names but does not decide is reported."""
    if payload.get("tool_name") != "AskUserQuestion":
        return None
    response = payload.get("tool_response")
    if not isinstance(response, dict):
        return None
    decisions = answer_decisions(response)
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not SID_RE.match(sid):
        decisions = [(verb, digest, question, preview, why or "no valid session id")
                     for verb, digest, question, preview, why in decisions]
        sid = None
    lines = []
    for verb, digest, question, preview, why in decisions:
        if why:
            lines.append(f"draft {digest} not decided ({why})")
        elif verb == "Skip":
            lines.append(dismiss_draft(directory, sid, digest))
        else:
            lines.append(approve_draft(directory, sid, digest, question, preview))
    if sid:
        write_pid_map(directory, sid)
    return "\n".join(f"post gate: {line}" for line in lines) or None


def handle_pretooluse(payload: dict, directory: Path, now: float) -> str | None:
    if payload.get("tool_name") != "Bash":
        return None
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        return None
    sid = payload.get("session_id")
    if not isinstance(sid, str):
        return None
    cwd = payload.get("cwd")
    cwd = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    if not shim_armed():
        # No shim behind this session: any `gh` could reach the real one.
        # Heredoc bodies count here: `bash <<EOF` runs them. A personal
        # checkout is exempt only while every gated call targets a personal repo.
        if not mentions_gh(unquoted(join_continuations(command))):
            return None
        if personal_repository(cwd):
            try:
                if not classify(command, cwd=cwd)[0]:
                    return None
            except Exception:
                return None
        return _unarmed_denial()
    try:
        kinds, denials = classify(command, cwd=cwd)
    except Exception:
        return None  # fail open: the gh shim still gates at exec
    if denials:
        return _unclassified_denial(denials[0])
    return check_replies(kinds, sid, directory)


def main() -> int:
    if os.environ.get("HERDR_ENV") != "1":
        return 0
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    event = payload.get("hook_event_name")
    directory = gate_dir()
    now = time.time()
    if event == "UserPromptSubmit":
        handle_prompt(payload, directory, now)
        return 0
    if event == "PreToolUse":
        reason = handle_pretooluse(payload, directory, now)
        if reason:
            print(reason, file=sys.stderr)
            return 2
        return 0
    if event == "PostToolUse":
        context = handle_answer(payload, directory)
        if context:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": context}}))
        return 0
    return 0


def draft_main(argv: list[str]) -> int:
    """`draft -- gh <args>`: record a gated gh call as shown to the owner and
    print its hash and text for the chat."""
    args = argv[1:] if argv[:1] == ["--"] else list(argv)
    if args[:1] == ["gh"]:
        args = args[1:]
    if not args:
        print(f"usage: {DRAFT_COMMAND} <args>", file=sys.stderr)
        return 2
    sid = shim_session_id()
    if not sid:
        print("draft: no Claude session id (CLAUDE_CODE_SESSION_ID); drafts are per session", file=sys.stderr)
        return 1
    cwd = os.getcwd()
    digest = draft_hash(args, cwd)
    if digest is None:
        print("draft: pass the text with --body, -f body=... or a readable file, not stdin or an editor", file=sys.stderr)
        return 1
    text = post_body(args, cwd)[1]
    if not register_draft(gate_dir(), sid, digest, args, text, time.time()):
        print(f"draft {digest} already approved")
        return 0
    print(f"draft {digest}: gh {shlex.join(args)}")
    if text:
        print(text)
    if draft_path(gate_dir(), sid, digest, "spent").exists():
        print(f"[WARNING] draft {digest} already ran once; read the PR first: a duplicate is possible")
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["draft"]:
        sys.exit(draft_main(sys.argv[2:]))
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
