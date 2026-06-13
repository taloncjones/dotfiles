#!/usr/bin/env python3
"""SessionStart hook: inject the tiered model orchestration standing rule.

Reads PLANNER_MODEL from claude/orchestrator.conf (located relative to this
file's resolved path, since ~/.claude/hooks symlinks into the dotfiles repo)
and emits the routing rule via hookSpecificOutput.additionalContext.

Semantics:
- valid conf value: inject the rule with that planner model
- missing/unreadable conf: fall back to opus, prepend a visible warning
- invalid conf value: no fallback; report the error and disable orchestration

ORCHESTRATOR_CONF env var overrides the conf path (used by tests).
"""

import json
import os
import sys
from pathlib import Path

ALLOWED_MODELS = {"fable", "opus", "sonnet", "haiku"}
FALLBACK_MODEL = "opus"


def conf_path() -> Path:
    override = os.environ.get("ORCHESTRATOR_CONF")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "orchestrator.conf"


def read_planner_model(path: Path) -> tuple[str, str]:
    """Return (model, status); status is one of ok|missing|invalid."""
    try:
        text = path.read_text()
    except OSError:
        return FALLBACK_MODEL, "missing"
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("PLANNER_MODEL="):
            value = line.split("=", 1)[1].strip()
            if value in ALLOWED_MODELS:
                return value, "ok"
            return value, "invalid"
    return FALLBACK_MODEL, "missing"


def build_rule(model: str, status: str) -> str:
    if status == "invalid":
        return (
            f"[WARNING] claude/orchestrator.conf sets PLANNER_MODEL={model}, "
            "which is not one of fable|opus|sonnet|haiku. Tiered orchestration "
            "is DISABLED until the conf is fixed. Tell the user at the first "
            "opportunity."
        )
    warning = ""
    if status == "missing":
        warning = (
            "[WARNING] claude/orchestrator.conf is missing or unreadable; "
            "planner model fell back to opus. Tell the user at the first "
            "opportunity.\n"
        )
    return warning + (
        "For substantial multi-step implementation tasks (3+ distinct "
        "subtasks touching multiple files), orchestrate via the "
        "tiered-orchestrate skill using a Workflow. "
        f"Planner/reviewer model: {model}. Workers: sonnet for code writes, "
        "haiku for read-only exploration and docs. Skip for trivial edits, "
        "single-file changes, questions, and conversational turns. Defaults: "
        "max 8 concurrent workers; stop and report if an orchestration "
        "exceeds its planned task list. Worker agents never invoke Workflow "
        "or spawn their own orchestration; nesting is forbidden. This rule "
        "applies to the top-level interactive session only."
    )


def main() -> None:
    try:
        json.load(sys.stdin)
    except json.JSONDecodeError:
        pass  # input is informational; the rule does not depend on it

    model, status = read_planner_model(conf_path())
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": build_rule(model, status),
                }
            }
        )
    )


if __name__ == "__main__":
    main()
