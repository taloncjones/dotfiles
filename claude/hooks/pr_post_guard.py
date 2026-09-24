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
- PreToolUse Bash classifies the command as post/delete/body/none and
  denies (exit 2) a classified command without its go.

Override: none. Fixing a false positive means narrowing the classifier,
not bypassing it.

Accepted holes (see spec "Risks and accepted residuals"): aliases,
functions, script files, `eval` of a script this cannot extract, `gh` via
a variable or command substitution, graphql query files, backtick
substitution, `xargs -I{} gh ...`, wrappers nested two levels deep, other
HTTP clients, and a subagent sharing the parent's session_id during the
go turn. `push_guard.py` accepts the same class of hole for git push.

Reuses rm_guard's tokenizer and wrapper-unwrapping the way
git_remote_guard.py does; fails open on any exception.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rm_guard

GO = {"post it": "post", "edit the pr body": "body"}
TTL = 600
PRUNE_AGE = 86400
SID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
KEYWORDS = {"do", "then", "else", "elif", "!", "{"}
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
DELETE_PATH = re.compile(r"(issues|pulls)/comments/[^/\s]+$")
POST_PATH = re.compile(r"(issues|pulls)/(\d+/)?comments|pulls/\d+/reviews|/reactions$|/replies$")
BODY_PATH = re.compile(r"(issues|pulls)/\d+$")
FIELD_FLAGS = ("-f", "-F", "--raw-field", "--field", "--input")
# gh api flags whose value is the next argument (gh 2.94.0 --help).
VALUE_FLAGS = FIELD_FLAGS + (
    "-H", "--header", "-q", "--jq", "-t", "--template",
    "--hostname", "--cache", "-p", "--preview",
)


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


def api_kind(args: list[str]) -> str | None:
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
    method = method or ("POST" if has_field else "GET")
    if method == "GET" or path is None:
        return None
    if path == "graphql":
        return "post" if any("mutation" in a for a in args) else None
    if method == "DELETE" and DELETE_PATH.search(path):
        return "delete"
    if POST_PATH.search(path):
        return "post"
    if BODY_PATH.search(path):
        return "body"
    return None


def gh_kind(args: list[str]) -> str | None:
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-R", "--repo", "--hostname") else 1
    sub = args[i:i + 2]
    rest = args[i + 2:]
    if sub[:1] == ["api"]:
        return api_kind(args[i + 1:])
    if sub in (["pr", "comment"], ["pr", "review"], ["issue", "comment"]):
        return "post"
    if sub in (["pr", "close"], ["issue", "close"]) and any(
            t in ("-c", "--comment") or t.startswith("--comment=") for t in rest):
        return "post"
    if sub == ["pr", "edit"]:
        return "body"
    return None


def text_kind(text: str) -> str | None:
    if not re.search(r"\bgh\b", text):
        return None
    if re.search(r"\bDELETE\b", text) and re.search(r"(issues|pulls)/comments/", text):
        return "delete"
    if re.search(r"\bcomment\b|\breview\b|pr\s+edit", text):
        return "post"
    return None


def classify(command: str, depth: int = 0) -> set[str]:
    kinds: set[str] = set()
    tokens = rm_guard.tokenize(drop_heredoc_bodies(command))
    for seg in rm_guard.split_segments(tokens):
        while seg and seg[0] in KEYWORDS:
            seg = seg[1:]
        seg = rm_guard.strip_prefixes(seg)
        if not seg:
            continue
        name = rm_guard.basename(seg[0])
        if name == "gh":
            kind = gh_kind(seg[1:])
        elif name in rm_guard.SHELL_WRAPPERS and depth == 0:
            script = rm_guard.extract_shell_c_arg(seg)
            if script is not None:
                kinds |= classify(script, depth + 1)
                continue
            kind = text_kind(" ".join(seg))
        elif name == "eval":
            kind = text_kind(" ".join(seg[1:]))
        else:
            kind = None
        if kind:
            kinds.add(kind)
    return kinds


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


def decide(kinds: set[str], sid: str, directory: Path, now: float) -> str | None:
    """Denial text for the first ungranted kind in `kinds`, or None."""
    if not kinds:
        return None
    if not SID_RE.match(sid):
        return _denial(next(iter(kinds)))
    marker = marker_kind(directory, sid, now)
    for kind in kinds:
        if kind == "delete":
            if marker != "post":
                return _denial(kind)
        elif marker != kind:
            return _denial(kind)
    for kind in kinds:
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
    kinds = classify(command)
    return decide(kinds, sid, directory, now)


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
