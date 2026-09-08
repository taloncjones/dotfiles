---
name: herdr-orchestration
description: Run a Codex controller in Herd to plan, dispatch, verify, and review designated repository tasks with explicit model and effort routing.
---

# Codex Herd orchestration

Use only inside a real Herd-managed pane (`HERDR_ENV=1`). Do not set that
variable to imitate membership. Outside Herd, prepare plans and inspect local
state; run the controller after starting a managed pane.

Resolve this skill's directory through its installed symlink. The shared
lifecycle is `../../../claude/skills/herdr-orchestration/SKILL.md` relative to
that directory. Read it for kickoff, private plan confirmation, verification
contracts, review, stale-result recovery, and merge gates. Helpers live in the
same checkout's `claude/hooks/`; never resolve them from the user's project cwd.
This adapter replaces only Claude-specific runtime mechanics.

```bash
SKILL_FILE="${CODEX_HOME:-$HOME/.codex}/skills/herdr-orchestration/SKILL.md"
SKILL_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True).parent)' "$SKILL_FILE")" || exit 2
ORCH_SOURCE_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
CORE="$ORCH_SOURCE_ROOT/claude/hooks/herdr_orch_core.py"
RUNTIME="$ORCH_SOURCE_ROOT/claude/hooks/agent_runtime.py"
DISPATCH="$ORCH_SOURCE_ROOT/claude/hooks/herdr_dispatch.py"
```

Pass the selected `--repo-path` and `--runtime codex` on every core invocation;
include `--personal` for an intentional personal override in a work repository.
These flags select account payload state without changing Codex authentication.

## Controller identity and ownership

1. Resolve the original repository and selected account with
   `workflow_context.py`. Preserve canonical repo identity and the legacy repo
   slug across linked worktrees. Personal scope never inherits work auth.
2. Claim through `herdr_orch_core.py claim-owner` with `--repo-path`,
   `--runtime codex`, the actual current thread UUID, and the real process,
   workspace, and session identity. Use the CLI's current `--help` for identity
   flags. Never substitute a pane name or task label for a thread UUID.
3. A busy owner permits read-only status. Never take over automatically or
   create a second coordination namespace to avoid its fence.
4. Refresh the claim before each mutation. On stale ownership, stop this
   controller's watch and yield. No task writes occur outside core transactions.

## Model and effort

`agent_runtime.py route` is the executable policy. Resolve both values once per
dispatch; supply the resulting JSON to `herdr_dispatch.py launch`.

| Role | Default model | Effort |
| --- | --- | --- |
| Controller, planner, substantive reviewer | `gpt-6-astra` | `high` |
| Implementation | `gpt-5.6-terra` | `high` |
| Bounded read or mechanical task | `gpt-5.6-luna` | `medium` |
| Critical reviewer or escalation | `gpt-6-astra` | `xhigh` |

Sol/high remains a configurable routine reviewer or skeptic. Do not treat
Luna as a substitute for architectural judgment or final security review.
Capabilities and fallback policy are explicit; account unavailability never
causes an account switch. A current Astra/xhigh session remains xhigh until
restarted; a policy table cannot relabel it high.

For a new interactive controller, the intended model/effort flags are:

```bash
codex -m gpt-6-astra -c model_reasoning_effort='"high"'
```

Retain the user's normal permission profile. Each dispatched worker gets a
separate explicit sandbox and task scope. Read-only reviewers use normal
approval for exact lifecycle/output writes; never broaden their sandbox just
to make `emit-review` succeed. An approval rejection is a blocked result.

## Dispatch and review

- Create or adopt the correct task worktree before launch. Use an explicit
  `--cwd` for Herd worktree creation and verify returned Git identity.
- Reserve the task under the owner fence, then use `herdr_dispatch.py launch`
  with its exact task, workspace, pane, route, and prompt file. The adapter
  binds account environment to the actual worker process and records a unique
  attempt before dispatch. Its generated attempt context supplies emission
  identifiers to the worker; never fabricate them in a hand-written brief.
- For TODO work, persist the exact `todo_id` and require the read-only
  `todos.sh ready <id> --offline` gate to return 0. Unknown or unresolved
  dependencies block kickoff; do not omit the binding to bypass that check.
- Use native Codex child agents for bounded in-turn work, with explicit
  ownership and model/effort when supported. They are not independent Herd
  tasks and never write controller state. Do not use Claude Workflow or
  SendMessage tool names in Codex instructions.
- Preserve the shared TDD, independent plan review, frozen co-review inputs,
  and verification gates. A Codex review session performs its own Codex half;
  it does not spawn another generic Codex review recursively.
- Both model arguments and observed evidence belong in the report. Unknown
  observations remain unknown. Idle banners, successful prompt delivery, and
  `agent prompt --wait` never prove completion.
- Confirm private plans with `confirm-plan`; confirm implementation and its
  contract separately. Match the current attempt and live HEAD before review
  or phase advancement. Reviewers report findings and emit; implementers fix.

## Wake, restart, and presentation

`codex queue --thread <UUID> --message <text>` is a possible notification
transport, not a completion signal. Enable queued wake only after a disposable
native probe proves that the installed CLI wakes its idle target. A CLI help
entry or successful enqueue alone is insufficient. Queue only closed event
metadata to the exact claimed controller thread, never task text, secrets,
instructions, or personal plans.

Otherwise use the core's bounded watch through the host's background/wait
tools. Keep one watch per controller, check records before waiting, and recheck
after each wake so an event between checks is not lost. If the host cannot
resume on a background result, report manual-check mode; do not promise
unattended orchestration or install a surprise daemon.

Use shared `handoff` and `kickoff` for a controller restart. Select the saved
task, recheck live Git state and ownership, then claim the new thread. A saved
owner token is historical evidence, not authority to resume writing.

Display a short task title plus current role/model/status. Refresh both pane
and workspace metadata when a plan pane becomes implementation or review.
Keep the durable task and launch IDs behind the display name. A stale label is
a presentation problem; it never changes lifecycle state.
