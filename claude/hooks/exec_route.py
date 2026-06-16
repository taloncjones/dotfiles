#!/usr/bin/env python3
"""PostToolUse hook: suggest an execution strategy when a plan file is written.

There is no native "entering execution phase" event in Claude Code, so this
hook uses the finalization of an implementation plan file as the proxy: when a
plan under a ``plans/`` directory is written or edited, parse it for a few cheap
structural signals and emit a one-line routing suggestion as additionalContext.

The suggestion is advisory only (PostToolUse cannot block). It distinguishes:

- tiered-orchestrate (tiered model routing: opus plans, sonnet implements,
  haiku docs; Codex runs once via co-review at the branch gate) -- pays off when
  tasks are many, span several file-areas, or run in parallel.
- subagent-driven + co-review-at-end -- lighter and cheaper when the plan is
  linear, confined to one file-area, and already gated by TDD.

Signals (all best-effort, regex over the plan markdown):
- task count            -- ``### Task N`` headers
- file-area spread      -- distinct top-2 dirs across the ``Files:`` lines
- TDD coverage          -- count of "failing test" / "verify it fails" markers
- parallelism / coupling-- "disjoint" / "in parallel" / "dependsOn" language

Never raises, always exits 0. De-dupes on file content hash so repeated
formatter/edit saves of the same plan do not re-emit an identical suggestion.
"""

import hashlib
import json
import os
import re
import sys
from pathlib import Path

# Only act on a finalized writing-plans document. This sentinel is emitted by
# the superpowers writing-plans skill header, so in-progress notes and unrelated
# markdown under a plans/ dir are ignored.
PLAN_SENTINEL = "REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development"

STATE_DIR = Path(os.path.expanduser("~/.claude"))
SEEN_FILE = STATE_DIR / ".exec_route_seen.json"

# Guardrails: cap how much of a plan we read, and how many de-dupe entries we
# retain, so a pathological file or a long-lived machine cannot blow up.
MAX_PLAN_BYTES = 1_000_000
MAX_SEEN = 200


def _load_input() -> dict:
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def _plan_path(data: dict) -> str | None:
    if data.get("tool_name") not in {"Write", "Edit", "MultiEdit"}:
        return None
    path = (data.get("tool_input") or {}).get("file_path")
    if not path or not path.endswith(".md"):
        return None
    norm = path.replace("\\", "/")
    if "/plans/" not in norm:
        return None
    return path


def _already_emitted(path: str, content: str) -> bool:
    """True if we already emitted for this exact (path, content) hash.

    State is a {path: digest} map kept in insertion order, capped to the
    most-recent MAX_SEEN paths, and written atomically (temp + os.replace) so a
    crashed or concurrent run cannot leave truncated JSON behind.
    """
    digest = hashlib.sha256(content.encode("utf-8", "replace")).hexdigest()
    try:
        seen = json.loads(SEEN_FILE.read_text())
        if not isinstance(seen, dict):
            seen = {}
    except Exception:
        seen = {}
    if seen.get(path) == digest:
        return True
    seen.pop(path, None)
    seen[path] = digest  # re-insert as most-recent
    while len(seen) > MAX_SEEN:
        del seen[next(iter(seen))]  # evict oldest
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = SEEN_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(seen))
        os.replace(tmp, SEEN_FILE)
    except Exception:
        pass
    return False


def _signals(text: str) -> dict:
    tasks = len(re.findall(r"(?m)^#{2,4}\s+Task\b", text))

    # File-area spread: collect path-looking tokens from the
    # `Create:` / `Modify:` / `Test:` bullet lines under each "Files:" heading
    # (the superpowers writing-plans format), keyed by their top-2 dirs.
    dirs: set[str] = set()
    for m in re.finditer(r"(?im)^\s*[-*]?\s*(?:Create|Modify|Test):\s*`?([^\s`]+)", text):
        token = m.group(1)
        if "/" in token:
            parts = token.split("/")
            dirs.add("/".join(parts[:2]))
    areas = len(dirs)

    tdd = len(
        re.findall(
            r"(?i)(failing test|write (?:a |the )?failing|"
            r"verify (?:it|they|the test) fail|test-first|red[\s-]?green)",
            text,
        )
    )
    parallel = bool(
        re.search(r"(?i)(disjoint|in parallel|parallelizable|dependsOn|worktree isolation)", text)
    )
    return {"tasks": tasks, "areas": areas, "tdd": tdd, "parallel": parallel}


def _recommend(s: dict) -> tuple[str, str]:
    """Return (recommendation, rationale)."""
    tasks, areas, tdd, parallel = s["tasks"], s["areas"], s["tdd"], s["parallel"]
    wide = areas >= 3
    many = tasks >= 8
    tdd_covered = tdd >= max(2, tasks // 2)

    lean_tiered = parallel or (many and wide)
    lean_light = tdd_covered and not wide and not parallel

    if lean_tiered and not lean_light:
        rec = "tiered-orchestrate (tiered model routing; co-review at end)"
    elif lean_light and not lean_tiered:
        rec = "subagent-driven + co-review at end (lighter, cheaper)"
    else:
        rec = "borderline -- either fits; pick by orchestration weight"

    rationale = (
        f"{tasks} tasks, {areas} file-area(s), "
        f"TDD-covered={'yes' if tdd_covered else 'no'}, "
        f"parallel={'yes' if parallel else 'no'}"
    )
    return rec, rationale


def main() -> int:
    data = _load_input()
    path = _plan_path(data)
    if not path:
        return 0
    try:
        if Path(path).stat().st_size > MAX_PLAN_BYTES:
            return 0  # not a hand-written plan; avoid reading a huge/odd file
        content = Path(path).read_text(errors="replace")
    except Exception:
        return 0
    if PLAN_SENTINEL not in content:
        return 0
    if _already_emitted(path, content):
        return 0

    s = _signals(content)
    if s["tasks"] == 0:
        return 0
    rec, rationale = _recommend(s)

    msg = (
        f"[exec-route] Plan finalized ({Path(path).name}). "
        f"Suggested execution: {rec}. Signals: {rationale}. "
        "Heuristic only -- confirm with the user before executing."
    )
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": msg,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
