---
name: co-review
description: Freeze one code change, obtain independent Claude and Codex findings, then verify them before fixing.
---

# Co-Review

Set `REVIEW_SKILL_FILE` to this skill's absolute `SKILL.md` path supplied by
the skill loader. Resolve installed symlinks before using a helper. If the
loader supplies no path, the existing `DOTFILEDIR` is the fallback; never guess
from the target checkout or another account's skill directory.

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
required = ("claude/skills/co-review/scripts/review.py", "claude/hooks/agent_runtime.py")
if root is None or not all((root / name).is_file() for name in required):
    raise SystemExit("Installed review helpers are unavailable")
print(root)
PYROOT
) || exit 2
REVIEW_HELPER="$REVIEW_ROOT/claude/skills/co-review/scripts/review.py"
RUNNER="$REVIEW_ROOT/claude/hooks/agent_runtime.py"
```

Use this skill after implementation and before a merge. Both finders read one
frozen snapshot. Do not publish, comment, fetch, or modify the source checkout
during review preparation.

Before changing to the target repository, resolve the helper to an absolute
path. Never invoke a helper through a path relative to the target repository.

```bash
test -f "$REVIEW_HELPER" || { echo "co-review helper is unavailable" >&2; exit 2; }
uv run --no-project python "$REVIEW_HELPER" prepare --repo "$REPO" --base "$BASE" \
  --output-dir "$REVIEW_OUTPUT" --include-untracked path/inspected-first
```

Require explicit repository, base, output directory, and untracked paths. The
helper captures the committed head plus staged and unstaged changes through a
temporary index, accepts only explicitly named regular untracked paths, and
rejects symlinks, private paths, inherited Git routing, source drift, and tree
mismatch. Its manifest pins base/head/tree, source identity, two worktrees,
scope/exclusions, and an ownership nonce.

```bash
uv run --no-project python "$REVIEW_HELPER" verify --manifest "$MANIFEST"
```

An empty diff, helper failure, empty finder output, or malformed bounded output
is incomplete, never a clean review.

## Claude-led dispatch

Claude reviews `snapshot.claude_root` through its native `/code-review` flow.
That worktree is based at the pinned base and has the reviewed tree applied to
its index. It is the Claude half, not a substitute for Codex.

The independent Codex finder runs from `snapshot.codex_root` through the shared
runtime runner. It selects the policy model and effort and returns structured
runtime metadata; this skill never restates a route table.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-codex.XXXXXX")
cat >"$PROMPT_FILE" <<EOF
Review only the frozen change against base $BASE. Report each actionable issue
as severity, file:line, failure scenario, and concrete fix. End with one
verdict. Do not invoke skills, partners, or external actions.
EOF
uv run --no-project python "$RUNNER" run --runtime codex --role reviewer --risk normal \
  --provisional --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Use the runner only; do not launch a generic or nested Codex CLI review. Pass
`--risk critical` only for explicitly critical review risk, never diff size.
Record requested route separately from runtime-reported model or effort; unknown
observation remains unknown. A failed, malformed, or unsupported result makes
the independent pass incomplete.

## Bounded attacker and skeptic

Run at most one attacker when frozen changed paths affect auth, authorization,
validation, permission, credentials, tokens, signatures, secrets, or a review
or guard hook. It states a concrete bypass scenario. Run at most one skeptic to
reproduce high-severity findings and mark each confirmed, disproved, or
uncertain. Resolve each fresh Codex role through `agent_runtime.resolve_route`
with role `reviewer` or `skeptic`; never select a model or effort ad hoc.

Merge only findings checked against the frozen files. Retain uncertain or
unsupported high-severity findings as unresolved and do not return a clean
verdict while a required finder or skeptic is incomplete. Apply confirmed fixes
within existing user authorization; otherwise ask before editing source files.
After all readers finish, remove only this run's snapshots:

```bash
uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST"
```

Cleanup refuses foreign roots, marker mismatches, modified trees, ignored or
untracked snapshot files, and unexpected owned-output entries. Preserve the
snapshot if it refuses cleanup.

## Document reviews

Plan/spec review skills require an explicit document, task id, runtime, and the
same absolute helper. Artifact output is always private under the selected
account/repository/task payload root; an explicit output directory must be a
single direct launch subdirectory there. The helper records caller-selected task id, account
id, and repository id. The coordinator validates the digest and containment under the selected
account/repository/task payload root before accepting a planning milestone;
retain the helper metadata as provenance, not as an independent ownership proof. Plans live under
`docs/superpowers/plans/`; specs live under `docs/superpowers/specs/`.
