# State layout

Account-scoped fixed state root:

```
STATE_ROOT = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/herdr-orch"
```

Workers under `~/Git/work` run in the work account, so their state lands
under `~/.claude-work`; orchestrator and workers for a repo share one
account, hence one `STATE_ROOT`. Nothing under `STATE_ROOT` is ever
git-tracked (it lives under the config dir, not the repo), and no marker is
ever written into any worktree.

## Layout

```
STATE_ROOT/
  <repo_slug>/
    owner.json                        # single-writer ownership claim
    config.json                       # machine-local config
    probe-samples.jsonl                # diagnostic probe captures ({ts, cls, probe|raw}); best-effort append from the section-1 probe step; safe to delete
    tasks/
      <task_id>.json                  # durable task record
      <task_id>.done.json             # impl worker completion record
      <task_id>.review.json           # review worker verdict (separate file)
    workspaces/
      <HERDR_WORKSPACE_ID>.json               # reverse index (task/repo/role)
      <HERDR_WORKSPACE_ID>.events.jsonl       # per-workspace hint log
```

## Identity

### Task identity

- `task_id`: the canonical Jira key (`PROJ-123`) for a ticket; for a bare
  todo, the todos skill's **stable identifier** (its durable id/filename
  slug), never a truncated title -- so title edits and similar titles cannot
  alias one id. If the todo store exposes no stable id, mint `td-<8hex>`
  once and persist it in the todo record.
- All per-task artifacts key on `task_id`.

### Repo identity

- `repo_slug`: canonical, collision-resistant, derived from
  `git remote get-url origin` normalized to `<host>-<org>-<repo>`
  (lowercased, non-`[a-z0-9]` -> `-`) with a short hash of the canonical
  remote URL appended (`<normalized>-<8hex>`) so lossy normalization cannot
  alias two distinct remotes. No remote -> `local-<8hex>` of the git
  common-dir realpath. All worktrees of a repo share the common dir/remote,
  so they resolve identically. Example: `github-com-org-repo-a1b2c3d4`.

### Branch and worktree names

- Branch: `<user>/<task_id>/<slug>` (slash form, matching the repo
  convention; e.g. `<user>/PROJ-123/teardown-lifecycle`). `<user>` comes
  from machine-local `config.json`; `<slug>` is the kebab-case summary
  (<=32 chars).
- Worktree directory name: the branch with `/` -> `+` (filesystem-safe flat
  name under `.claude/worktrees/`; e.g.
  `<user>+PROJ-123+teardown-lifecycle`). The `+` is a directory encoding
  only, never the branch.

### Agent names vs display labels

- Agent name (herdr-compliant): `plan-<t>` / `impl-<t>` / `rev-<t>` where `<t>`
  = `task_id` lowercased, `[^a-z0-9-]` -> `-`, whole name truncated to 32.
  Verify uniqueness via `agent list`; on collision append `-2`, `-3`.
- Display label (unconstrained): plan worker `plan:<task_id>`, implement worker
  `<task_id>`, reviewer `review:<task_id>`, orchestrator `orch:<repo>`.
- **One workspace/worktree per task.** git allows only one worktree per branch,
  so a task's plan -> implement -> review phases all run in the SAME
  worktree-backed workspace (a fresh agent per phase, sequentially). The
  workspace label and its index `role` are updated to the current phase as it
  advances (`<task_id>` for impl, `review:<task_id>` + `role: review` for
  review); there is never a second workspace on the same branch.

## Schemas

### `owner.json`

```json
{
  "session_id": "<id>",
  "host": "<host>",
  "pid": 12345,
  "heartbeat_ts": 1756300000.5,
  "fence": 3,
  "messaging_socket": "/tmp/cc-socks/12345.sock"
}
```

- **Atomic claim:** ownership is acquired by an atomic filesystem operation
  -- create-exclusive (`O_CREAT|O_EXCL`) of a lock file, or
  write-temp-then-atomic-`rename` -- never a read-then-overwrite (which two
  racing takeovers could both win). Each successful claim increments a
  monotonic **fence** token.
- **Fencing:** every state mutation re-reads `owner.json` and proceeds only
  if the live `fence`/`session_id` still matches the one this session
  claimed; a mutation under a stale fence aborts.
- **Inbox socket:** `messaging_socket` is the owner's Claude Code inbox
  socket (`CLAUDE_CODE_MESSAGING_SOCKET`), or `null`. Written by
  `claim-owner`/`refresh-owner --messaging-socket`; `pid` is taken from the
  socket basename when one is stored (the Claude process). Read by the
  worker hook (`post_wake`) to push a wake line; absent in older records
  and treated as `null`.
- Preflight claims if the file is absent or `heartbeat_ts` is stale (e.g.
  > 15 min); the owner refreshes `heartbeat_ts` each turn. A second
  > orchestrator whose claim fails **yields** to read-only reporting and
  > offers an explicit takeover.

### `config.json`

```json
{
  "v": 1,
  "user": "<user>",
  "default_base": "origin/main",
  "epics": ["PROJ-100"],
  "soft_cap": 3,
  "models": {
    "plan": ["fable", "opus"],
    "impl": ["sonnet", "opus"],
    "review": ["opus", "sonnet"]
  }
}
```

Validation: required `user`, `default_base`; `epics` a (possibly empty)
list; `soft_cap` a positive int (default 3); `models` optional (falls back
to the built-in preferences). `models`, when present, must be an object keyed
by the canonical resolver roles `plan`/`impl`/`review` (no `orchestrator` --
its model is fixed at session launch), each value a list of the aliases
`fable`/`opus`/`sonnet`. A malformed `models` block (non-object, a non-list
override, or a token outside the alias set) makes `resolve-model` exit 5.
Missing/invalid config -> mutating actions refuse with a concrete message. This
file holds the only employer/user identifiers; the shipped skill and fixtures
never contain them.

### `capabilities.json` -- session-stamped strong-model availability

Machine-local, per `repo_slug`, written by `write-capabilities` at preflight
(section 1 step 5) and flipped downward by `disable-model` (section 8
verify-after-launch). Never committed.

```json
{
  "v": 1,
  "session_id": "<orchestrator session id>",
  "available": { "fable": false, "opus": true, "sonnet": true }
}
```

`v` must be the integer 1 (not `true`); `available` must carry exactly the three
aliases, each a boolean. `resolve-model` treats the map as stale (exit 3) when
`session_id` != the live orchestrator session, so a restart / `/clear` triggers
a fresh probe. `resolve-model` filters each role's preference list by this map
and prints the first available alias, or exits 3 (stale/absent), 4 (no
survivor), or 5 (invalid role / malformed `models`).

### `tasks/<task_id>.json` -- durable task record

Written only by the owning orchestrator, via `$CORE write-task`.

```json
{
  "v": 1,
  "task_id": "PROJ-123",
  "repo_slug": "github-com-org-repo-a1b2c3d4",
  "kind": "jira",
  "branch": "<user>/PROJ-123/teardown-lifecycle",
  "worktree": "/abs/path/to/worktree",
  "base_ref": "origin/main",
  "base_sha": "<40hex>",
  "workers": [
    {
      "role": "impl",
      "phase": "implement",
      "workspace_id": "w1",
      "agent": "impl-proj-123",
      "peer_name": "impl-proj-123",
      "model": "sonnet",
      "created_by_this_orch": true,
      "started": "..."
    }
  ],
  "review_head_sha": null,
  "review_outcome": null,
  "contract_path": "claude/contracts/PROJ-123-contract.json",
  "contract_sha256": "<64hex>",
  "merge_check": null,
  "status": "kickoff|in-progress|blocked|completed|review-dispatched|changes-requested|reviewed|failed|abandoned|merged",
  "created": "...",
  "updated": "..."
}
```

`workers` is a list, not a single field -- phase advancement (implement ->
review) appends a new entry rather than overwriting.

`peer_name` is the worker's Claude Code session name as `ListAgents` showed
it after launch (the target of `notify_when_idle` subscriptions), or `null`
when discovery found zero or several candidates.

`contract_path` (worktree-relative) and `contract_sha256` are the
verification-contract pin, written by the orchestrator at implement dispatch
(the sha256 of the committed contract blob; see the contract section below).
Records predating the feature lack both fields -- `verify-contract` then
exits 5 and the skill's grandfather rule applies. `merge_check` records the
latest post-rebase speculative merge check:

```json
{
  "base_main_sha": "<40hex>",
  "branch_head_sha": "<40hex>",
  "result": "pass|fail|conflict",
  "ts": "..."
}
```

Only `pass`/`fail`/`conflict` are ever recorded; infrastructure or integrity
trouble writes nothing (retried next check-in). Any `merge_check` whose SHAs
do not match live HEAD and current `origin/<default>` is stale -- ignored and
re-run; it is nulled whenever `review_head_sha` is cleared.

### `tasks/<task_id>.done.json` -- worker-emitted completion record

The authoritative completion signal, **not** `/handoff`. Written by a
worker via `$CORE emit-done` at end of a phase.

```json
{
  "v": 1,
  "task_id": "PROJ-123",
  "workspace_id": "w1",
  "agent": "impl-proj-123",
  "phase": "implement",
  "outcome": "completed|failed|paused",
  "head_sha": "<40hex>",
  "base_sha": "<40hex>",
  "ts": "..."
}
```

### `tasks/<task_id>.review.json` -- review worker verdict

A **review** worker writes its verdict to a **separate** file via
`$CORE emit-review` (never the impl `.done.json`, so a review verdict can never
clobber the completion record). `blocking_count` is the number of blocking
findings the reviewer classified; the merge gate rejects any non-zero count
even under an `approved` outcome:

```json
{
  "v": 1,
  "task_id": "PROJ-123",
  "workspace_id": "w9",
  "agent": "rev-proj-123",
  "phase": "review",
  "outcome": "approved|changes-requested",
  "reviewed_head_sha": "<40hex>",
  "blocking_count": 0,
  "findings_ref": "<path to full /code-review output>",
  "ts": "..."
}
```

The merge gate (`$CORE confirm-review --workspace <review_ws> --head-sha <sha>`)
is merge-ready only when ALL hold: `outcome == "approved"`; `blocking_count`
is 0; the record's `workspace_id` equals the dispatched review workspace
(provenance -- a foreign or older worker's record is rejected); and the task
record's dispatched `review_head_sha`, this record's `reviewed_head_sha`, and
current HEAD are all equal. `changes-requested`, any blocking finding, a
provenance mismatch, or a dispatched/reviewed/HEAD mismatch is never
merge-ready. `$CORE confirm-completion` takes the same `--workspace` provenance
check for the impl `.done.json`.

### `workspaces/<HERDR_WORKSPACE_ID>.json` -- reverse index

Read by the monitoring hook; written by the orchestrator via
`$CORE write-index`.

```json
{
  "task_id": "PROJ-123",
  "repo_slug": "github-com-org-repo-a1b2c3d4",
  "role": "impl"
}
```

`role` is one of `impl`, `review` (matches the worker's phase/role, not the
agent-name prefix directly). A `plan`-phase worker uses `impl` -- its lifecycle
hints are impl-like (`stopped`/`blocked`), not review; the plan-vs-implement
distinction lives in the task record's `workers[].phase`, not the index role.

### `workspaces/<HERDR_WORKSPACE_ID>.events.jsonl` -- per-workspace hint log

Append-only, **per-workspace**, written only by that workspace's hook
(single writer per file, so no cross-writer interleaving). The
orchestrator merges across files on read (`$CORE status`). See
`event-schema.md` for the event vocabulary and fold rule.

### `claude/contracts/<task_id>-contract.json` -- verification contract (branch-committed)

The only per-task artifact NOT under `STATE_ROOT`: committed normally on the
task branch (no `git add -f` needed -- `claude/` is tracked), authored by the
plan worker, pinned by hash into the task record at implement dispatch, and
executed by the `verify-contract` verb (worker gate, pre-review gate,
post-rebase merge gate -- SKILL.md sections 2, 4, and 6).

```json
{
  "v": 1,
  "task_id": "PROJ-123",
  "commands": [
    {
      "name": "core-tests",
      "run": "sh claude/hooks/herdr-orch.test.sh",
      "timeout_secs": 600
    }
  ]
}
```

Validation is fail-closed: `v` must be integer 1; `task_id` must match; 1-32
commands, each `{name, run[, timeout_secs 1-3600]}` with unique non-blank
names and no unknown keys. Commands run via `sh -c` from the worktree root
and must be repo-local, deterministic, and worktree-safe: no STATE_ROOT
writes, no machine-state mutation, no network, no secret echo. Full
requirements: `docs/specs/2026-09-01-verification-contracts.md` (branch-only)
and the authoring rules echoed in `brief-template.md`.
