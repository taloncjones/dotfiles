---
name: codex-task-review
description: Single source of truth for a scoped, second-model Codex review of a committed diff via `codex exec review --base`. Used per-task by tiered-orchestrate and for the Codex half of co-review. Enforces the target invariant (captured base SHA, correct worktree, empty-diff guard) and returns source-taggable findings.
---

# Codex Task Review

The ONE place the `codex exec review` invocation is specified. `co-review` and
`tiered-orchestrate` reference this skill so the command, flags, and safety
guards never drift.

## Inputs

- `BASE_SHA` — the commit the work forked from, captured BEFORE implementation
  began (or at worktree creation). Never assume `main`.
- `WORKTREE` — absolute path to the worktree holding the committed changes.

## Target invariant (correctness-critical)

1. Run inside `$WORKTREE`. Never inherit the directory the session was launched
   from.
2. Use the captured `BASE_SHA`. Fall back to
   `git -C "$WORKTREE" merge-base HEAD <parent>` only if it is unset.
3. Empty-diff guard: if the diff against `BASE_SHA` is empty, STOP and fail
   loud. A clean review on an empty diff is a misconfiguration, not a pass.

## Mechanic

```bash
test -n "$BASE_SHA" || { echo "[codex-task-review] BASE_SHA unset"; exit 2; }
git -C "$WORKTREE" diff --stat "$BASE_SHA"...HEAD | grep -q . \
  || { echo "[codex-task-review] empty diff vs $BASE_SHA -- refusing to report clean"; exit 3; }
LOG=$(mktemp /tmp/codex-task-review.XXXXXX)
( cd "$WORKTREE" && codex exec review --base "$BASE_SHA" \
    -c model_reasoning_effort="high" \
    -c approval_policy="never" -c sandbox_mode="read-only" ) > "$LOG" 2>&1
```

- ALWAYS use the `codex exec review` subcommand (built-in review prompt, loads
  no skills, so it cannot recurse into a Claude -> Codex -> Claude loop).
- NEVER `codex exec "review this diff..."` — the generic form makes Codex load
  its AGENTS.md and recurse back into a Claude review.
- Read findings from `$LOG` with the Read tool (final `codex` message block,
  after the header, before `tokens used`); ignore MCP/network warning lines.
  Delete `$LOG` after extracting.
- Verify each finding against the code before relaying — this repo's failure
  mode is compile-green / runtime-red.

## Output

Return findings as a list; each item: severity, `file:line`, problem, fix. The
caller tags by source (`[codex]`). Verdict: `pass` (no findings) | `fail`
(one or more findings, or the empty-diff guard tripped).

## Notes

- Read-only and side-effect-free.
- For the Claude half of a review, callers use the native `/code-review`; this
  skill is only the Codex half.
