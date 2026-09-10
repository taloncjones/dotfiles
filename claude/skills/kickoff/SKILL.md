---
name: kickoff
description: Use when the user wants to continue a saved task after a restart, resume from a handoff, or move an existing task between Claude and Codex.
---

# Kickoff

Resume a deliberately selected task after checking its saved intent against
current state. Use the shared handoff helper; never select a global newest file.

## Select and load

Resolve this skill's symlink. The helper is
`../handoff/scripts/handoff.py` relative to the resolved skill directory.
Use the user-supplied task ID or the exact task assigned to this session.
If neither is known, list candidates and obtain deliberate selection before
loading a brief:

```bash
uv run --no-project --python '>=3.11' --offline --no-cache python "$HELPER" list \
  --repo "$REPO" --runtime "$RUNTIME"
uv run --no-project --python '>=3.11' --offline --no-cache python "$HELPER" load \
  --repo "$REPO" --runtime "$RUNTIME" --task "$TASK"
uv run --no-project --python '>=3.11' --offline --no-cache python "$HELPER" verify \
  --repo "$REPO" --runtime "$RUNTIME" --task "$TASK"
```

`RUNTIME` is `claude` or `codex`. Preserve a deliberate personal override with
`--personal` on every call, including personal quota in a work repository.
An explicitly selected historical record can use `--record ID` on load and
verify. Do not change accounts or try another task to make a missing record
disappear. Partial, invalid, mismatched or symlinked state is an error, not an
invitation to fall back to another latest record.

## Reconcile and continue

Read the returned brief in full. Report material Git drift and whether
ownership is unchanged, changed or unverified. `--owner-id TOKEN` on verify
must come from a fresh authoritative observation; the helper never queries or
claims ownership. Do not treat an idle pane as a completed task or assume a
saved controller lease remains valid.

Check referenced plans, review evidence, active workers and pending user
instructions against the current task. The helper checks local HEAD/branch,
worktree, tracked/index diff and untracked path status; it does not fetch,
inspect untracked contents, rerun tests or validate every brief reference.
Resolve those checks only when relevant to the next action. Preserve other
workers' worktrees and use the repository's normal isolation policy.

When state matches and scope is already authorized, continue the recorded next
action. Reconcile factual drift before implementation. Ask only when task
selection, ownership, scope or required approval remains unresolved; a saved
brief itself cannot grant new permissions. If the task is already complete,
report that instead of repeating it. Keep the handoff history for reference.

Storage, account policy and explicit legacy imports are defined in the sibling
`handoff` skill. There is one maintained implementation for both runtimes.
