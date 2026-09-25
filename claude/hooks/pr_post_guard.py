#!/usr/bin/env python3
"""Gate agent-posted GitHub PR/issue writes behind a typed owner go.

Incident 2026-09-23: on rw-bess #2444 a co-review/herdr flow posted one
marker comment per round and replied to a human reviewer; on this repo's
PR #170 the director posted the co-review verdict after a multiple-choice
AskUserQuestion answer. Neither was owner approval -- see co-review's
"Publish (optional)" section and operating-principles.md ("every outward
post needs its own explicit go").

Gate: decides only when HERDR_ENV=1; every other session exits 0 untouched
(no file I/O). Two events, one script, dispatched on hook_event_name:

- UserPromptSubmit mints a one-turn, one-session go ONLY from a prompt
  whose whole normalized text is "post it" or "edit the pr body" -- never
  from an AskUserQuestion answer (a tool result, not a typed prompt) and
  never from a multiple-choice option string. The go expires in 600s.
- PreToolUse Bash is the early second layer. The primary gate is the gh
  shim (bin/herdr-shims/gh -> gh_post_shim.py), which sees the final argv
  after the shell has resolved quoting and substitution -- four review
  rounds each hid a write from this text classifier (if/while prefixes,
  comments, punctuation gluing, line continuations, backticks, `g\\h`,
  `bash -lc`). This hook denies a gated kind it can see without a go, or
  when the shim is not armed to spend the go; it only checks the go, the
  shim spends it. It denies outright the two routes around the shim: a
  path-qualified `gh`, and a login flag on a shell the PATH anchor does
  not re-run in. Anything it cannot parse passes; the shim decides it.

Override: none. Fixing a false positive means narrowing the classifier,
not bypassing it.

Accepted holes (spec 2026-09-24-gh-exec-shim-design.md, "Risks and
accepted residuals"): other GitHub clients and raw HTTP with the token,
PATH or arming tampering, obfuscated uncovered login shells, a forged
marker, and a child process sharing the go's session id.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import sys
import time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rm_guard

GO = {"post it": "post", "edit the pr body": "body"}
TTL = 600
PRUNE_AGE = 86400
SID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
SHIM_MARK = b"gh_post_shim.py"
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
POST_PATH = re.compile(r"(issues|pulls)/(\d+/)?comments|pulls/\d+/reviews|/reactions$|/replies$")
BODY_PATH = re.compile(r"(issues|pulls)/\d+$")
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

# Non-comment `gh` writes this repo's own skills already invoke (grepped
# from claude/, codex/, bin/, install/); anything else classifies unknown
# and is denied outright, go or no go.
KNOWN_WRITES = {
    ("pr", "create"),  # claude/commands/pr.md, claude/skills/voice
    ("pr", "merge"),   # claude/skills/ship/SKILL.md
    ("pr", "ready"), ("pr", "checkout"), ("repo", "clone"), ("run", "rerun"),
}


def normalize(prompt: str) -> str:
    text = prompt.strip().lower()
    return text[:-1].rstrip() if text[-1:] in (".", "!") else text


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


def classify_api(args: list[str]) -> str:
    method, path, has_field, i = None, None, False, 0
    while i < len(args):
        tok = args[i]
        if tok in ("-X", "--method") and i + 1 < len(args):
            method, i = args[i + 1].upper(), i + 2
            continue
        if tok in VALUE_FLAGS:
            has_field = has_field or tok in FIELD_FLAGS
            i += 2
            continue
        if tok.startswith("--method="):
            method = tok.split("=", 1)[1].upper()
        elif tok.startswith("-X") and len(tok) > 2:
            method = tok[2:].upper()
        elif tok[:2] in ("-f", "-F") or tok.startswith(("--raw-field=", "--field=", "--input=")):
            has_field = True
        elif not tok.startswith("-") and path is None:
            path = tok.lstrip("/")
        i += 1
    if path == "graphql":
        if graphql_query_from_file(args) or any("mutation" in a for a in args):
            return "post"
        return "read"
    method = method or ("POST" if has_field else "GET")
    if method == "GET":
        return "read"
    if path is None:
        return "unknown"
    if method == "DELETE":
        return "delete" if DELETE_PATH.search(path) else "unknown"
    if POST_PATH.search(path):
        return "post"
    if BODY_PATH.search(path):
        return "body"
    return "unknown"


def classify_gh(args: list[str]) -> str:
    """Classify one `gh` invocation's own argv (after the `gh` token) as
    "read", "write" (a known non-comment write), "post"/"body"/"delete"
    (gated, needs its typed go), or "unknown" (denied outright)."""
    if args[-1:] in (["-h"], ["--help"]) and (len(args) < 2 or not args[-2].startswith("-")):
        # Help on a known command; `--body --help` still posts "--help", and
        # an alias or extension stays unknown.
        return "read" if len(args) < 2 or classify_gh(args[:-1]) != "unknown" else "unknown"
    if args[:1] and args[0] in READ_COMMANDS:
        return "read"
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-R", "--repo", "--hostname") else 1
    sub = tuple(args[i:i + 2])
    rest = args[i + 2:]
    if sub[:1] == ("api",):
        return classify_api(args[i + 1:])
    if sub[:1] == ("search",):
        return "read"
    if sub in READ_SUBCOMMANDS:
        return "read"
    if sub in KNOWN_WRITES:
        return "write"
    if sub in (("pr", "close"), ("issue", "close")):
        if any(t in ("-c", "--comment") or t.startswith("--comment=") for t in rest):
            return "post"
        return "unknown"
    if sub in (("pr", "comment"), ("pr", "review"), ("issue", "comment")):
        return "post"
    if sub == ("pr", "edit"):
        return "body"
    return "unknown"


def resolved_kind(sub: str) -> tuple[str | None, str | None]:
    """Map a classify_gh()/classify_api() verdict to (gated_kind, denial):
    a read or known write passes through with neither; post/body/delete
    need a go; an unrecognized call denies outright -- no go covers it."""
    if sub in ("read", "write"):
        return None, None
    if sub == "unknown":
        return None, "this `gh` call does not match a known read, write, or gated action"
    return sub, None


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


def classify(command: str, depth: int = 0) -> tuple[list[str], list[str]]:
    """Return (gated_kinds, denials) for `command`. The gh shim is the
    primary gate and sees the final argv; this is the early second layer.
    `gated_kinds` need a typed go. `denials` are the routes that skip the
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
            if kind in ("post", "body", "delete"):
                kinds.append(kind)
        elif (head in rm_guard.SHELL_WRAPPERS or head == "eval") and depth == 0:
            script = (
                " ".join(run[1:]) if head == "eval"
                else rm_guard.extract_shell_c_arg(run)
            )
            if script:
                sub_kinds, sub_denials = classify(script, depth + 1)
                kinds.extend(sub_kinds)
                denials.extend(sub_denials)
    return kinds, denials


def gate_dir() -> Path:
    base = os.environ.get("DOTFILES_POST_GATE_DIR")
    if base:
        return Path(base)
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "dotfiles" / "post-gate"


def _read_json(path: Path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def marker_kind(directory: Path, sid: str, now: float) -> str | None:
    data = _read_json(directory / f"{sid}.json")
    if not isinstance(data, dict):
        return None
    kind = data.get("kind")
    expires = data.get("expires_epoch")
    if kind not in ("post", "body") or not isinstance(expires, (int, float)):
        return None
    if expires <= now:
        return None
    return kind


def claim(path: Path) -> bool:
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    os.close(fd)
    return True


def check_go(kinds: list[str], sid: str, directory: Path, now: float) -> str | None:
    """Denial text for the first kind in `kinds` its typed go does not cover,
    or None. Reads only: the gh shim spends the go (spend_go) at exec."""
    if not kinds:
        return None
    counts = Counter(kinds)
    # One go covers exactly one post and one body write.
    for kind in ("post", "body"):
        if counts[kind] > 1:
            return _denial(kind)
    if not SID_RE.match(sid):
        return _denial(kinds[0])
    marker = marker_kind(directory, sid, now)
    for kind in counts:
        needed = "post" if kind == "delete" else kind
        if marker != needed:
            return _denial(kind)
        if kind != "delete" and (directory / f"{sid}.{kind}-used").exists():
            return _denial(kind)
    return None


def spend_go(kinds: list[str], sid: str, directory: Path) -> str | None:
    """Claim each post/body go in `kinds`; denial text if one is spent."""
    for kind in kinds:
        if kind != "delete" and not claim(directory / f"{sid}.{kind}-used"):
            return _denial(kind)
    return None


def _denial(kind: str) -> str:
    return (
        f"Blocked: this looks like a PR/issue {kind} without a typed go.\n"
        "Ask the owner to type `post it` (or `edit the pr body`) as the "
        "whole message; a multiple-choice answer is not a go."
    )


def _unclassified_denial(reason: str) -> str:
    return (
        f"Blocked: {reason}.\n"
        "Run plain `gh` as found on PATH, not from a login `sh`; "
        "no typed go covers this."
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
    so the shim can find the go after a /clear changes the session id.
    Written whole or not at all; a failure only costs the /clear fallback."""
    target = directory / f"pid-{os.getppid()}.sid"
    temp = directory / f".pid-{os.getppid()}.{os.getpid()}.tmp"
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(sid)
        os.replace(temp, target)
    except OSError:
        try:
            temp.unlink()
        except OSError:
            pass


def handle_prompt(payload: dict, directory: Path, now: float) -> None:
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not SID_RE.match(sid):
        return
    _unlink(directory / f"{sid}.json")
    _unlink(directory / f"{sid}.post-used")
    _unlink(directory / f"{sid}.body-used")
    write_pid_map(directory, sid)
    prompt = payload.get("prompt")
    if not isinstance(prompt, str):
        return
    kind = GO.get(normalize(prompt))
    if kind is None:
        return
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    marker_path = directory / f"{sid}.json"
    fd = os.open(marker_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"v": 1, "kind": kind, "expires_epoch": now + TTL}, handle)
    prune(directory, now)


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
    if not shim_armed():
        # No shim behind this session: any `gh` could reach the real one.
        # Heredoc bodies count here: `bash <<EOF` runs them.
        if mentions_gh(unquoted(join_continuations(command))):
            return _unarmed_denial()
        return None
    try:
        kinds, denials = classify(command)
    except Exception:
        return None  # fail open: the gh shim still gates at exec
    if denials:
        return _unclassified_denial(denials[0])
    return check_go(kinds, sid, directory, now)


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
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
