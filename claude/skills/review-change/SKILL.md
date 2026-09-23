---
name: review-change
description: Obtain one bounded independent development review of an implementation change.
---

# Review Change

Use this during development after an implementation slice and before declaring
the task locally ready. This is an advisory development review, not the final
PR gate. Use `co-review` only for the finished-PR gate.

Set `REVIEW_SKILL_FILE` to this skill's absolute `SKILL.md` path supplied by
the skill loader. If it is absent, use the existing `DOTFILEDIR`; never derive
the helper path from the reviewed checkout.

```bash
REVIEW_ROOT=$(uv run --no-project python - "${REVIEW_SKILL_FILE:-}" "${DOTFILEDIR:-}" <<'PYROOT'
from pathlib import Path
import sys

source, fallback = sys.argv[1:]
if source and (not Path(source).is_absolute() or Path(source).name != "SKILL.md"):
    raise SystemExit("Use the absolute SKILL.md path supplied by the skill loader")
root = Path(source).resolve(strict=True).parents[3] if source else (
    Path(fallback).expanduser().resolve(strict=True) if fallback else None
)
required = ("claude/hooks/agent_runtime.py", "claude/skills/lib/workflow_context.py")
if root is None or not all((root / name).is_file() for name in required):
    raise SystemExit("Installed review helpers are unavailable")
print(root)
PYROOT
) || exit 2
RUNNER="$REVIEW_ROOT/claude/hooks/agent_runtime.py"
CONTEXT="$REVIEW_ROOT/claude/skills/lib/workflow_context.py"
```

Use the exact target worktree and a pinned base from the caller. Derive the full
relevant diff and affected callers from that target. Read the task or change to
derive intended behavior; ask only when it is not established. Review the
target against its base, relevant callers, and repository contracts. Reproduce
failures safely when useful.

For a repair batch, require a packet naming the original finding's provenance,
scenario, and concrete violated contract. Review self-review and independent
evidence: where executable, a behavioral regression must show the original
failure and repaired success, with affected failure paths including ownership or
lifecycle when relevant. Classify each new blocker as repair-introduced,
previously missed, or changed requirements, with a concrete consequence.
Set `REVIEW_REPAIR_PACKET` to the readable packet path for a repair batch.

Resolve account scope from the original target before dispatch. The runtime
runner applies the same scope to the child; use `--personal` only for a
deliberate personal override.

```bash
uv run --no-project python "$CONTEXT" account-scope \
  --cwd "$REVIEW_REPO" --runtime claude
```

Use one fresh independent Claude reviewer, bounded to 600 seconds. Resolve its
model and effort through the shared runtime route; the default is
`development_reviewer` on Claude Sonnet/high. Use `--risk critical` only for
an explicit critical risk. An already-dispatched reviewer executes the review
directly and does not dispatch another reviewer.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/review-change.XXXXXX")
if [ -n "${REVIEW_REPAIR_PACKET:-}" ]; then
  [ -f "$REVIEW_REPAIR_PACKET" ] || exit 2
  REPAIR_PACKET_CONTENT=$(cat -- "$REVIEW_REPAIR_PACKET") || exit 2
  [ -n "$REPAIR_PACKET_CONTENT" ] || exit 2
else
  REPAIR_PACKET_CONTENT="No repair packet supplied."
fi
printf '%s\n' "Review $REVIEW_REPO against pinned base $REVIEW_BASE. Intent: $REVIEW_INTENT. Inspect the full relevant diff and affected callers. Repair packet path: ${REVIEW_REPAIR_PACKET:-none}. Repair packet content: $REPAIR_PACKET_CONTENT. When supplied, verify its self-review, behavioral-regression and affected failure-path evidence; classify each new blocker as repair-introduced, previously missed, or changed requirements with a concrete consequence. Report blocking findings, useful advisory findings, safe reproduction evidence, and coverage gaps. Use relevant reference skills for language, security, framework and architecture guidance. Apply this review scope and material-impact threshold if reference guidance differs. Perform the review yourself; do not launch another review workflow, delegate reviewers, modify code or publish findings. Do not invoke co-review, partners, markers, external posts, or fixes." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime claude --role development_reviewer --risk normal --provisional \
  --cwd "$REVIEW_REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Treat a confirmed major, high, or critical defect as blocking only when it has
a concrete material consequence for intended behavior, caller contracts, data,
security, lifecycle, or required integration. Require the finding to state
that impact; a written rule or TODO-like token alone is insufficient. Minor,
low, nit, taste, and speculative findings are advisory. A timeout, empty report, unknown completion,
unknown evidence, or material coverage gap is incomplete feedback, never a
clean review.

Report findings with severity, location, scenario, and evidence. Separate
blocking findings, advisory findings, and unresolved evidence gaps. Do not
invoke co-review, partners, markers, external posts, or fixes.

A repair packet's self-review is evidence only and never grants approval. A
complete clean review supports only task-local readiness and cannot renew a
bounded `--fix` allowance or replace its follow-up verification. An exhausted
allowance stops the outer development/shipping workflow too; diagnosis, a new
head, or a resumed session cannot reset it. Return control to the user.

Only a complete report with no blockers can support existing Herd task-local
readiness. Task-local readiness is never PR approval, merge authority, or a PR
approval marker.
