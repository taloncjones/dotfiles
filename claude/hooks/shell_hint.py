#!/usr/bin/env python3
"""PreToolUse hook: warn when a shell tool call backgrounds a job with a bare `&`.

Warn-only: always exits 0 and fails open. Runs before Claude and Codex shell
tool calls.
"""

# Required for `str | None` annotations on Python 3.9; see rm_guard.py.
from __future__ import annotations

import json
import sys

import rm_guard

WARNING = (
    "[WARNING] shell_hint: a bare & leaves a background job running after this "
    "tool call returns, so a later call can start a duplicate; use "
    "run_in_background on the Bash tool (in Codex, keep a running exec_command "
    "session) instead."
)


def mask_quoted_ampersands(text: str) -> str:
    """Replace each `&` inside quotes or behind a backslash with `_`."""
    out = []
    quote = None
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "\\" and quote != "'" and i + 1 < n:
            out.append(ch)
            i += 1
            out.append("_" if text[i] == "&" else text[i])
        elif quote:
            out.append("_" if ch == "&" else ch)
            if ch == quote:
                quote = None
        else:
            if ch in ("'", '"'):
                quote = ch
            out.append(ch)
        i += 1
    return "".join(out)


def is_operator(tok: str) -> bool:
    return bool(tok) and all(c in rm_guard.SEGMENT_OPERATORS for c in tok)


def background_index(tokens: list[str]) -> int | None:
    """Index of the last background `&` operator token, or None."""
    found = None
    for i, tok in enumerate(tokens):
        if not is_operator(tok):
            continue
        rest = tok.replace("&&", "").replace("|&", "").replace(";&", "")
        if "&" not in rest:
            continue
        if tok.startswith("&") and i > 0 and tokens[i - 1].endswith((">", "<")):
            continue
        if tok == "&" and i + 1 < len(tokens) and tokens[i + 1].startswith(">"):
            continue
        found = i
    return found


def reaped_by_wait(tokens: list[str], index: int) -> bool:
    """True when a depth-0 `wait` segment follows the job before its subshell closes."""
    job = tokens[index]
    depth = job[job.index("&") + 1 :].count("(") - job[job.index("&") + 1 :].count(")")
    segment: list[str] = []
    seg_depth = depth
    for tok in tokens[index + 1 :] + [None]:
        if tok is not None and not is_operator(tok):
            if not segment:
                seg_depth = depth
            segment.append(tok)
            continue
        if segment and seg_depth == 0 and rm_guard.strip_prefixes(segment)[:1] == ["wait"]:
            return True
        segment = []
        if tok is None:
            return False
        depth += tok.count("(") - tok.count(")")
        if depth < 0:
            return False
    return False


def command_from(data) -> str | None:
    tool = data.get("tool_name") or data.get("toolName") or ""
    if not isinstance(tool, str) or tool.lower() not in rm_guard.SHELL_TOOLS:
        return None
    tool_input = data.get("tool_input") or data.get("toolInput") or {}
    if not isinstance(tool_input, dict):
        return None
    nested = tool_input.get("args")
    inputs = [tool_input] + ([nested] if isinstance(nested, dict) else [])
    return next(
        (v for item in inputs for k in ("command", "cmd") if isinstance(v := item.get(k), str)),
        None,
    )


def main() -> None:
    try:
        command = command_from(json.load(sys.stdin))
        if not command or "&" not in command:
            sys.exit(0)
        text = mask_quoted_ampersands(rm_guard.strip_line_comments(command))
        tokens = rm_guard.tokenize(text)
        index = background_index(tokens)
        if index is not None and not reaped_by_wait(tokens, index):
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": WARNING,
            }}))
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
