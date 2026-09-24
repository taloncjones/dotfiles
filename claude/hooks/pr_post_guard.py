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
  never from a multiple-choice option string. The go expires in 600s and
  is spent by one PreToolUse Bash call (post/body) or freely by any number
  of delete calls while unexpired.
- PreToolUse Bash deny-by-default, not enumerate-the-bad-shapes: three
  rounds of co-review each found a new way to hide a `gh` write from the
  classifier (an `if`/`while` prefix, a trailing comment, a punctuation-
  glued token, a backslash line continuation), each a gap in a shell
  tokenizer that can only ever be as complete as its list of known-bad
  shapes. This hook flips the default instead. Any command whose raw text
  mentions `gh` as a word is classified: it is allowed only if it parses
  cleanly and every `gh` invocation in it is a known read, a known
  non-comment write, or a gated kind (post/body/delete) covered by its
  typed go; anything else -- an unparseable command, an unclassifiable
  `gh` call, a wrapper this cannot see through -- is denied outright, and
  no go can cover it. A command that never mentions `gh` is untouched.

Override: none. Fixing a false positive means narrowing the classifier,
not bypassing it.

Accepted holes (see spec "Risks and accepted residuals"): aliases,
functions, script files, and a subagent sharing the parent's session_id
during the go turn. `push_guard.py` accepts the same class of hole for
git push.

Reuses rm_guard's tokenizer, comment-stripping, and wrapper-unwrapping the
way git_remote_guard.py does; a command that never mentions `gh` fails
open on any exception, same as before. A command that does mention `gh`
now fails CLOSED on any exception, in herdr sessions only.
"""

from __future__ import annotations

import json
import os
import re
import shlex
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
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{"}
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
GH_WORD_RE = re.compile(r"\bgh\b")
ANSI_C_QUOTE_RE = re.compile(r"\$'")
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
    ("auth", "status"),
}

# Non-comment `gh` writes this repo's own skills already invoke (grepped
# from claude/, codex/, bin/, install/); anything else classifies unknown
# and is denied outright, go or no go.
KNOWN_WRITES = {
    ("pr", "create"),  # claude/commands/pr.md, claude/skills/voice
    ("pr", "merge"),   # claude/skills/ship/SKILL.md
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


def find_gh_index(tokens: list[str]) -> int | None:
    for i, tok in enumerate(tokens):
        if rm_guard.basename(tok) == "gh":
            return i
    return None


def last_wrapper_name(tokens: list[str]) -> str | None:
    """Walk `tokens` from the start the way rm_guard.strip_prefixes does,
    but return the last PREFIX_WRAPPERS name it passed through instead of
    the remaining tokens -- so an env assignment ahead of the wrapper
    (`FOO=1 sudo -u me gh ...`, round-3 minor) still names the wrapper that
    stopped the unwrap, instead of hiding it behind the assignment."""
    name = None
    for tok in tokens:
        if rm_guard.is_env_assignment(tok):
            continue
        base = rm_guard.basename(tok)
        if base in rm_guard.PREFIX_WRAPPERS:
            name = base
            continue
        break
    return name


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
        return "post" if any("mutation" in a for a in args) else "read"
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


def classify(command: str, depth: int = 0) -> tuple[list[str], list[str]]:
    """Return (gated_kinds, denials) for `command`. `gated_kinds` need a
    typed go (existing post/body/delete behavior); a non-empty `denials`
    means outright deny, which no go can cover. A command that never
    mentions `gh` (after joining continuations and dropping heredoc
    bodies) returns ([], []) untouched."""
    working = drop_heredoc_bodies(join_continuations(command))
    if not mentions_gh(working):
        return [], []
    if ANSI_C_QUOTE_RE.search(working):
        return [], ["this command uses $'...' ANSI-C quoting, which this gate's tokenizer does not support"]
    tokens = strict_tokenize(working)
    if tokens is None:
        return [], ["this command could not be parsed cleanly by the shell tokenizer"]
    kinds: list[str] = []
    denials: list[str] = []
    for seg in rm_guard.split_segments(tokens):
        while seg and seg[0] in KEYWORDS:
            seg = seg[1:]
        if not seg:
            continue
        stripped = rm_guard.strip_prefixes(seg)
        head = rm_guard.basename(stripped[0]) if stripped else None
        kind = denial = None
        if head == "gh":
            kind, denial = resolved_kind(classify_gh(stripped[1:]))
        elif stripped and stripped[0].startswith("-"):
            idx = find_gh_index(stripped)
            if idx is not None:
                wrapper = last_wrapper_name(seg) or rm_guard.basename(seg[0])
                kind, denial = resolved_kind(classify_gh(stripped[idx + 1:]))
                if denial:
                    denial = f"`{wrapper}` wraps a `gh` call this cannot classify safely"
        elif (head in rm_guard.SHELL_WRAPPERS or head == "eval") and depth == 0:
            script = (
                rm_guard.extract_shell_c_arg(stripped) if head in rm_guard.SHELL_WRAPPERS
                else " ".join(stripped[1:])
            )
            if script:
                sub_kinds, sub_denials = classify(script, depth + 1)
                kinds.extend(sub_kinds)
                denials.extend(sub_denials)
                continue
            if find_gh_index(seg) is not None:
                denial = f"cannot statically extract the script `{head}` runs"
        elif head in rm_guard.SHELL_WRAPPERS or head == "eval":
            if find_gh_index(seg) is not None:
                denial = "a shell wrapper nested more than one level deep reaches a `gh` call"
        elif find_gh_index(seg) is not None:
            denial = "`gh` is reached through an unrecognized command or wrapper"
        if kind:
            kinds.append(kind)
        if denial:
            denials.append(denial)
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


def decide(kinds: list[str], sid: str, directory: Path, now: float) -> str | None:
    """Denial text for the first ungranted kind in `kinds`, or None."""
    if not kinds:
        return None
    counts = Counter(kinds)
    # One go covers exactly one post and one body write; a command chaining
    # two of the same kind (`&&`, `;`, multi-line) can't be covered by one go
    # even if it were otherwise present, so reject it outright.
    for kind in ("post", "body"):
        if counts[kind] > 1:
            return _denial(kind)
    if not SID_RE.match(sid):
        return _denial(kinds[0])
    marker = marker_kind(directory, sid, now)
    for kind in counts:
        if kind == "delete":
            if marker != "post":
                return _denial(kind)
        elif marker != kind:
            return _denial(kind)
    for kind in counts:
        if kind == "post" and not claim(directory / f"{sid}.post-used"):
            return _denial(kind)
        if kind == "body" and not claim(directory / f"{sid}.body-used"):
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
        "Run a single plain `gh` command on one line, with no wrapper, "
        "or type the go."
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


def handle_prompt(payload: dict, directory: Path, now: float) -> None:
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not SID_RE.match(sid):
        return
    _unlink(directory / f"{sid}.json")
    _unlink(directory / f"{sid}.post-used")
    _unlink(directory / f"{sid}.body-used")
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
    try:
        kinds, denials = classify(command)
        if denials:
            return _unclassified_denial(denials[0])
        return decide(kinds, sid, directory, now)
    except Exception:
        # A command that never mentions `gh` keeps failing open (a crashed
        # guard must never block ordinary work); one that does mention `gh`
        # fails closed here instead, per the redesign's default-deny.
        if mentions_gh(command):
            return _unclassified_denial("an internal error occurred while classifying this command")
        return None


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
