# State layout

Account-private payload root (resolved by `workflow_context.py`):

```
STATE_ROOT = "<selected_account_root>/herdr-orch"
```

Work repositories default to work scope but may explicitly use personal quota.
Claude and Codex share the selected logical account's payload root; Codex's
actual `CODEX_HOME` remains its authentication/configuration root. Do not set
`CLAUDE_CONFIG_DIR` merely to point the core at payloads. Resolve the account
from the original repository before dispatch and validate native context at
each worker emission. Personal content never migrates into work payloads.

Ownership metadata lives separately at
`${XDG_STATE_HOME:-~/.local/state}/dotfiles/herdr-orch/coordination` (explicit
override: `HERDR_COORDINATION_ROOT`). It contains identity bindings, fences,
liveness, and account hashes, not plans, findings, or task text. Persistent
locks serialize controllers across runtime/account payload roots. A different
payload root does not grant a second owner for the same repository.

Lead ownership is a per-(repository, workspace) lease stored beside the slug's
`owner.json` as `lead-<key>.json`, where `<key>` is the first 16 hex chars of
sha256(workspace_root). Lead leases coexist with the launcher lease and with
each other; the launcher lease alone remains one-per-repository. A lead lease
is claimable only through a launcher-issued dispatch binding whose expected
session, account, runtime, repository, and workspace all match; a binding
whose parent is not a launcher is unclaimable (two tiers only). Lead dispatch
remains inactive until the procedure slice lands; nothing in the current skill
issues bindings.

The orch-edit guard reads these records read-only (no lock) to classify a
session's role: a launcher-tier `owner.json` blanket-fences the session from
every repo edit; a lead lease (validated against its dispatch binding: parent
launcher, tier lead, status issued/claimed, matching runtime, repository,
workspace, account, and expected session) fences the session to edits whose
canonical destination is under its `workspace_root` and denies all others; a
session with neither record is a plain worker. Lead leases are discovered from
the authoritative coordination namespace, so a lead stays fenced even if its
payload-root binding is missing; a lead whose binding is missing, corrupt,
revoked, or completed is denied every repo edit (fail closed). The allow-edit
marker never widens a lead's workspace scope. Every edit target is canonicalized
from its raw token with symlinks and `..` resolved together, so a symlink- or
`..`-through-`.todos` path cannot escape the fence.

All state remains machine-local and untracked. Private spec/plan copies live
in the selected payload tree's `artifacts/<task>/<launch>/` and are referenced
by immutable path/hash pairs.

## Layout

```
STATE_ROOT/
  <repo_slug>/
    owner.json                        # compatibility mirror of shared owner
    config.json                       # machine-local config
    task-lead-gate.json               # task-lead activation gate record; absence,
                                      # damage, or an identity mismatch reads as disabled
    probe-samples.jsonl                # diagnostic probe captures ({ts, cls, probe|raw}); best-effort append from the section-1 probe step; safe to delete
    tasks/
      <task_id>.json                  # durable task record
      <task_id>.done.json             # impl worker completion record
      <task_id>.review.json           # review worker verdict (separate file)
      <task_id>.spend.jsonl           # mech spend ledger (start/end lines)
      <task_id>.brief.md              # mech kickoff brief file (--brief-file)
      orch-edits.jsonl                # tasks/orch-edits.jsonl bounded edit-marker audit
    bindings/
      <binding_id>.json               # launcher-issued lead dispatch binding
                                      # (ldb-<32hex>; schema_version 1; status
                                      # issued -> claimed -> completed|revoked;
                                      # written only under a launcher fence)
    leads/
      <binding_id>/                   # one lead's private record subtree
        owner.json                    # mirror of the lead's per-workspace lease
        tasks/                        # lead-scoped task/done/review records
        workspaces/                   # lead-scoped workspace index records
        envelope.json                 # versioned terminal return envelope
                                      # (schema_version 1; outcome pr_ready|
                                      # blocked|failed|cancelled; monotonic
                                      # sequence; size-capped, REJECT not strip;
                                      # written only by emit-envelope under the
                                      # owner lock; consumed once by the
                                      # launcher's integrate-envelope, which
                                      # transitions the binding claimed ->
                                      # completed after an expected-base check)
    think/
      <think_id>.question.md          # director-written brief (input contract)
      <think_id>.launch.json          # wrapper-written, create-exclusive, before launch (liveness)
      <think_id>.answer.json          # wrapper-written result (output contract)
    workspaces/
      <HERDR_WORKSPACE_ID>.json               # reverse index (task/repo/role)
      <HERDR_WORKSPACE_ID>.events.jsonl       # per-workspace hint log
      <HERDR_WORKSPACE_ID>.wake.json          # worker-status hook's wake marker: {"v":1,
                                               # "records":{path:[mtime_ns,size]},
                                               # "last_push":{event:epoch}}. Machine-local,
                                               # written only by the hook. `records` advances
                                               # only on a push, so a debounced record change
                                               # is delayed, never dropped.
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
  Verify uniqueness via `agent list`; each launch also gets a collision-resistant
  launch ID. Names are transport handles, not task identity.
- Display label: short task title, current role/runtime/model/status in separate
  metadata fields; director `director:<repo>`. Retain stable task and launch IDs
  behind the label. Refresh pane and workspace metadata on every phase/retry so
  a reused plan pane no longer displays a plan role during review.
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

- **Atomic claim:** shared persistent `flock` locks cover owner validation and
  publication together. Locks are never unlinked. Atomic rename alone is not
  mutual exclusion. Reclaim/takeover advances a monotonic fence; refresh of
  the same runtime/thread/account owner retains it.
- **Fencing:** each mutation validates the shared session/fence/account binding
  under the same transaction as its write. Core code holds stable directory
  descriptors and rejects corrupt, nonregular, replaced, or ambiguous state.
  Lock order is owner then think; subprocesses run outside both, followed by
  revalidation. Legacy account owner records are reconciled conservatively.
- **Native owner identity:** records additionally distinguish runtime and the
  Codex controller's exact thread UUID. A saved session string alone does not
  permit another runtime/thread to reuse its fence.
- **Edit marker:** `orch-edit-allow.json` is account-local payload state, but
  only a `claim-owner` binding checked under the shared owner lock may mint it.
  It carries the session, fence, expiry, and edit budget; `orch-edits.jsonl`
  records marker mints, reservations, allows, and refusals.
- **Inbox socket:** `messaging_socket` is the owner's Claude Code inbox
  socket (`CLAUDE_CODE_MESSAGING_SOCKET`), or `null`. Written by
  `claim-owner`/`refresh-owner --messaging-socket`; `pid` is taken from the
  socket basename when one is stored (the Claude process). Read by the
  worker hook (`post_wake`) to push a wake line; absent in older records
  and treated as `null`.
- Preflight claims if the file is absent or `heartbeat_ts` is stale (e.g.
  > 15 min); the owner refreshes `heartbeat_ts` each turn. A second
  > director whose claim fails **yields** to read-only reporting and
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
    "review": ["opus", "sonnet"],
    "mech": ["haiku", "sonnet"],
    "think": ["fable", "opus"]
  },
  "effort": { "plan": "high", "impl": null, "review": "high", "think": "high" },
  "routes": {
    "implementation": { "effort": "medium" },
    "mechanical": { "effort": "medium" }
  },
  "mech": {
    "max_turns": 40,
    "max_budget_usd": 2.0,
    "timeout_secs": 1800,
    "contract_commands": [
      {
        "name": "core-tests",
        "run": "sh claude/hooks/herdr-orch.test.sh",
        "timeout_secs": 600
      }
    ]
  },
  "think": {
    "max_turns": 15,
    "max_budget_usd": 3.0,
    "timeout_secs": 900,
    "daily_budget_usd": 10.0
  }
}
```

Validation: required `user`, `default_base`; `epics` a (possibly empty)
list; `soft_cap` a positive int (default 3); `models` optional (falls back
to the built-in preferences). `models`, when present, must be an object keyed
by the canonical resolver roles `plan`/`impl`/`review`/`mech`/`think` (no
`director` -- its model is fixed at session launch), each value a list of
the aliases `fable`/`opus`/`sonnet`/`haiku`; `haiku` is legal only in
`models.mech`, and `models.think` may name only `fable`/`opus` (`sonnet` or
`haiku` under `think` is a config error, exit 5 -- deep think is the strong
tier only, by construction). A malformed `models` block (non-object, a
non-list override, a token outside the alias set, `haiku` under a
non-`mech` role, or `sonnet`/`haiku` under `think`) makes `resolve-model`
exit 5.

`effort` is optional and mirrors `models`'s validation: when present it must
be an object whose keys are a subset of `plan`/`impl`/`review`/`mech`/`think`
and whose values are a string in `low`/`medium`/`high`/`xhigh`/`max` or
`null` (`null` means _inherit_: no `--effort` flag, the worker takes the
CLI's own default for its model; an explicit top-level `"effort": null` is
itself a malformed block, unlike an absent key). `think` is constrained
further -- its value must be `high`/`xhigh`/`max`, never `null`/`low`/`medium`
-- so `resolve-effort --role think` never prints `inherit`: "deep think"
means the strong tier at high effort or above, by construction, in config,
resolver, wrapper validation, and tests alike. A non-object, an unknown key,
a boolean or number, or a value outside the set makes every effort-resolving
verb (`resolve-effort`, `routing-table`) exit 5. Absent keys fall back to the
built-in defaults (`plan` high, `impl` inherit, `review` high, `mech`
inherit, `think` high).

`routes` is optional and is validated by the native `agent_runtime.py`
resolver, not the core: `models`/`effort` above govern only the legacy
`routing-table`/`run-mech`/`run-think` wrapper path. When present, `routes`
must be an object keyed by the resolver's own role names (`controller`,
`planner`, `implementation`, `reviewer`, `plan_reviewer`,
`development_reviewer`, `read_only`, `mechanical`, `think`); each value is an
object containing only `model` and/or `effort`. `model` must be a model the
runtime recognizes (a supported alias for Claude, a full model ID for
Codex) -- omit it to keep the role's default model, since a model pin is
runtime-specific and does not travel between `claude` and `codex` configs;
`effort` must be one of `low`/`medium`/`high`/`xhigh`. A route cannot fall
below the role's own floor: the resolver enforces a floor that compares the
configured model/effort's quality tier against the role's default model at
`medium` (`EFFORT_FLOOR` in `agent_runtime.py`), raised to the role's own
default effort when a critical-risk or otherwise hard-floored dispatch calls
for it, and a configured `model`/`effort` below that floor is rejected. A
malformed `routes` block (non-object, an unknown role, an override key other
than `model`/`effort`, an unrecognized model, an unsupported effort, or a
below-floor override) fails the `route` call and blocks that dispatch.

`mech` is optional and fails closed: absent -> `mech_caps` falls back to the
built-in defaults above (`max_turns` 40, `max_budget_usd` 2.0, `timeout_secs`
1800, no `contract_commands` template); present, it must be a JSON object
with only the keys `max_turns` (int, 1-500), `max_budget_usd` (number, 0-50),
`timeout_secs` (int, 60-14400), and `contract_commands` (a `commands` array
in the same shape as the contract schema below); an unknown key, an
out-of-bounds value, or an invalid `contract_commands` entry makes
`mech-caps`/`mech-contract` exit 5 with a concrete message -- never silently
clamped or defaulted.

`think` is optional and fails closed the same way, minus `contract_commands`
(a deep-think run is read-only, so it has no commands to run): absent ->
`think_caps` falls back to the built-in defaults above (`max_turns` 15,
`max_budget_usd` 3.0, `timeout_secs` 900, `daily_budget_usd` 10.0); present,
it must be a JSON object with only the keys `max_turns` (int, 1-500),
`max_budget_usd` (number, 0-50, and never above `daily_budget_usd`),
`timeout_secs` (int, 60-14400), and `daily_budget_usd` (number, 0 < x <= 200);
an unknown key or an out-of-bounds value makes `think-caps` exit 5. Missing/
invalid config -> mutating actions refuse with a concrete message. This file
holds the only employer/user identifiers; the shipped skill and fixtures
never contain them.

### `task-lead-gate.json`

The task-lead activation gate record. The intended writer is
`deactivate-task-leads`, under a launcher fence.

```json
{
  "schema_version": 1,
  "repo_slug": "<slug>",
  "repo_id": "<id or null>",
  "account_id": "<account>",
  "enabled": false
}
```

**Absence means disabled.** So does every damaged, malformed, wrong-version,
or identity-mismatched state: an unreadable file, non-JSON content, a
non-object body, an unsupported `schema_version`, a `repo_slug` or
`account_id` that does not match the caller, or an `enabled` value that is
not a boolean. There is no `updated_ts` field.

`repo_id` is nullable. When it is `null` the record makes no identity claim
to corroborate. When it is set, the caller's own resolved `repo_id` must
equal it; a record that names a repository identity the caller cannot
corroborate (the caller has none to compare) is **refused**, not accepted --
this is the same fail-closed rule `claim-owner` already applies to a
binding's `repo_id`.

Reading the record is not the whole admission decision. A lead is admitted
only when the record additionally reads `enabled: true` and core, guard, and
the installed procedure each advertise a capability at or above the required
level (the procedure's advertised level is carried by the capability marker
in the skill's `SKILL.md`).

There is no verb that turns the gate on. `deactivate-task-leads` is the only
verb this record has; enabling it means writing the record by hand or
restoring an older one.

### `capabilities.json` -- legacy Claude strong-model availability

Machine-local, per `repo_slug`, written by `write-capabilities` at preflight
(section 1 step 5) and flipped downward by `disable-model` (section 8
verify-after-launch). Never committed.

```json
{
  "v": 1,
  "session_id": "<director session id>",
  "available": { "fable": false, "opus": true, "sonnet": true, "haiku": true }
}
```

`v` must be the integer 1 (not `true`); `available` must carry exactly the four
aliases, each a boolean; `haiku` is legal only in `models.mech`. `resolve-model`
treats the map as stale (exit 3) when `session_id` != the live director
session, so a restart / `/clear` triggers a fresh probe. `resolve-model` filters
each role's preference list by this map and prints the first available alias,
or exits 3 (stale/absent), 4 (no survivor), or 5 (invalid role / malformed
`models`).

### `tasks/<task_id>.json` -- durable task record

Written by the owning director via `$CORE write-task`, and -- for binding-scoped
records -- by `$CORE reserve-dispatch` and `$CORE enrich-dispatch`, which own
introducing and mutating worker rows respectively.
`herdr_dispatch.py` still writes launcher-scope records directly. Binding-scoped
rows are introduced only by `reserve-dispatch` and mutated only by
`enrich-dispatch`; `launch --binding` calls those verbs and never writes a
`leads/` record itself.

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
      "effort": "high",
      "created_by_this_orch": true,
      "started": "..."
    },
    {
      "role": "mech",
      "phase": "implement",
      "workspace_id": "w1",
      "agent": "mech-proj-123",
      "peer_name": null,
      "model": "haiku",
      "effort": null,
      "launch_id": "mech-proj-123-20260901T200000Z",
      "caps": { "max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800 },
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

The examples above include legacy rows. Every new native dispatch has
`launch_id`, `phase`, `runtime`, `workspace_id`, `pane_id`, and
`source_head_sha`. Both `emit-done` and `emit-review` must match the latest
current-phase attempt's complete tuple. Partial native tuples are invalid;
legacy fallback applies only to records that predate native attempts.

`write-task` enforces that contract at the writer for every row NEW in a write,
so no write can add a row its readers reject, by shape or by value.
`_native_worker_row` requires a `phase` in `DESCENDANT_PHASES`, a `runtime`
key, a non-empty string for every attempt field, and the identity values
settlement requires: `runtime` in `claude`/`codex`, `source_head_sha`
matching `SHA40_RE`, `workspace_id` passing `valid_workspace_id`, and a
`pane_id` other than the reserved `<unreadable>` sentinel that
`outstanding_descendants` returns for a record it cannot read. A row the
writer accepts can therefore always be settled by `emit-done` or
`emit-review`; before this rule a row with `runtime: "other"` was accepted
and then refused at settlement forever, keeping teardown blocked. A first
write that omits `workers` persists `[]` rather than a record carrying no
`workers` key. A later write that omits `workers` inherits the prior list
rather than clearing it, so only an explicit list can change dispatch
history. New rows must carry a `phase` on the unbound path and the full
native tuple, with valid values, on the binding-scoped path.

On the unbound path an explicit `workers` list may rewrite rows but may not
have fewer rows than the prior record's list when that list is readable
(`_readable_row_count`): an explicit `[]` over a dispatched record would
otherwise read as "nothing was ever dispatched". A prior that is corrupt, not
an object, or whose `workers` is not a list has no measurable history, so the
repair route below still accepts any explicit list there. A legitimate fresh
start is `reset-task`, described after the repair routes.

The pass-through of a row its reader would refuse is binding-scoped only. On
that path the append-only prefix is inherited unchanged and is not re-checked,
which keeps a record holding a pre-contract legacy row writable rather than
stranding it. Such a record is still persisted with that legacy row, and
`outstanding_descendants` still reads it as `<unreadable>`, so teardown stays
blocked until the row itself is repaired. An unbound write that omits `workers`
also inherits its prior rows unchecked, but that branch first requires
`_valid_task_shape(prior)`, so those rows are reader-valid by construction.

Two pre-contract record shapes need a manual repair, and both are recoverable
on the unbound path only. A record whose `workers` holds a row with no `phase`,
and a record persisted with no `workers` key at all, are both refused whichever
route is taken. For the phase-less row, supplying the record in full trips the
new-row rule and omitting `workers` trips the prior-shape check. For the record
with no `workers` key, supplying it verbatim IS the omit route, so both spellings
trip the prior-shape check. Recover by editing the record -- add a
`phase` to every stale row, or insert `"workers": []` -- then write it
explicitly. The unbound path has no append-only prefix, so a corrected explicit
list is accepted. On the binding-scoped path neither route works and
`teardown-binding` refuses before `--descendants-terminated` is consulted, so
the record must be repaired on disk first.

`reset-task --task-id <old> --new-task-id <new> --json <record>` is the
launcher-scope fresh start. It writes `tasks/<new>.json` from the supplied
record with `workers` forced to `[]` and `reset_from: <old>` added, and it
never reads back, rewrites, or deletes the old record, its `.done.json` or
`.review.json`, or any workspace index entry. It refuses when the ids are
equal, the payload names a non-empty `workers` or a `reset_from`, the old
record is absent, the new record already exists, or a settlement file already
exists under the new id (an empty `workers` list would match it vacuously
through the legacy rule in `attempt_matches`). There is no bound form: a lead
that needs a fresh start hands back to the director for a new binding.
`reset_from` is an additive key every reader ignores.

A refused dispatch row cannot hide a live pane. `reserve-dispatch` introduces
bound worker rows and `enrich-dispatch` mutates the current one. A lead reserves
its attempt under the owner transaction after the pane exists and before it
starts an agent, so a later `write-task` that exits 2 cannot erase the evidence:
dispatch history is append-only, the reserved row survives the refusal, and
`outstanding_descendants` still reports its pane.

`reserve-dispatch` refuses an attempt identity that a settlement record already
matches, because `outstanding_descendants` gates on the FINAL row alone: a
settled identity re-appended as that row reports a live successor's pane as
already settled, and teardown would release the lease over it. An UNSETTLED
repeat is allowed -- that is a legitimate re-dispatch back to a prior head.

**Bound `write-task` is not settlement-aware and does not enforce this.** It
still carries rows forward under the append-only prefix and the native row
rule, so re-appending a settled identity through `write-task` directly does
empty the outstanding set and does release the lease over a live pane. Closing
that needs a settlement-aware writer contract; it is tracked separately and is
not fixed by the reservation work.

A reservation whose lead died before it could settle blocks both
`teardown-binding` and `reconcile-leads` until an operator passes
`--descendants-terminated`. That is deliberate: `emit-done --binding` requires a
live, registry-corroborated lead lease, so no other actor can settle on a dead
lead's behalf.

Planning has a separate `plan_artifacts` list in both task and completion:
exactly one `spec` and one `plan`, each with absolute `path` and `sha256`.
`confirm-plan` verifies hashes, selected payload containment, and current
attempt identity. It does not require HEAD ahead of base. Implementation
completion requires its own current HEAD/base/contract gates.

`peer_name` is the worker's Claude Code session name as `ListAgents` showed
it after launch (dispatch-time discovery metadata, retained for
diagnostics), or `null` when discovery found zero or several candidates.
The second `workers[]` entry above shows a `mech` dispatch: `peer_name` is
always `null` (no
`ListAgents` discovery for a headless worker; see SKILL.md section 8, Mech
launch), and `caps` is a legacy mech-specific field -- its `launch_id` names
the live headless run (`<agent>-<YYYYMMDDTHHMMSSZ>`, also correlated in the
spend ledger below) and `caps` is the resolved `mech-caps` output for that
launch (`max_turns`/`max_budget_usd`/`timeout_secs`).

`effort` is `"<level>"|null` (the value passed on the launch line, never the
observed one) -- `null` means `inherit` (no `--effort` flag). **Legacy
records:** an entry written before effort routing landed lacks the
`effort` key entirely; readers treat a missing key as `effort: "unknown"`
(distinct from the explicit `null` that means inherit), and a full-record
rewrite preserves their meaning. Native attempt validation is stricter than
legacy carry-forward. Every new dispatch includes explicit requested effort;
observed model/effort are separate fields or unknown when not exposed.

`contract_path` (worktree-relative) and `contract_sha256` are the
verification-contract pin, written by the director at implement dispatch
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

Optional fields, both `emit-done`-accepted and mech-specific: `launch_id`
(correlates this record to a specific `workers[]` entry/spend-ledger launch;
omitted by a non-mech worker) and `reason` (one of `max_turns`/`max_budget`/
`timeout`/`no_emit`/`error`/`needs_design`/`blocked_on_human`/`other`; an
unrecognized token is rejected). `dirty` (bool) is written only by the
`run-mech` wrapper itself on a cap-hit/timeout/error record it emits on the
worker's behalf (never by `emit-done`'s CLI): `true` when the worktree had
uncommitted changes at the moment the wrapper wrote the record.

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

### `tasks/<task_id>.spend.jsonl` -- mech spend ledger

Append-only, per-task, written only by `$CORE run-mech` (single writer, one
`start` line before the headless launch and one `end` line after it returns
or times out -- never by `emit-done` or the director). Read and folded
only by `$CORE status`.

```json
{"v": 1, "task_id": "PROJ-123", "workspace_id": "w1", "agent": "mech-proj-123", "launch_id": "mech-proj-123-20260901T200000Z", "kind": "start", "role": "mech", "model": "haiku", "ts": "2026-09-01T20:00:00Z", "max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}
{"v": 1, "task_id": "PROJ-123", "workspace_id": "w1", "agent": "mech-proj-123", "launch_id": "mech-proj-123-20260901T200000Z", "kind": "end", "subtype": "success", "is_error": false, "num_turns": 12, "total_cost_usd": 0.83, "duration_ms": 45000, "models_used": ["haiku"], "downgrade": false, "errors": [], "model_attributable": false, "record_written_by": "worker", "git_ok": true, "exit_code": 0, "session_id": "<id>", "ts": "2026-09-01T20:05:00Z"}
```

Accepted-line rules (`valid_spend_line`; anything else is skipped, counted in
`skipped_lines`, never fatal): `v` must be the integer 1; `kind` must be
`start`/`end`; `task_id` must match the file's own task and `launch_id` must
be a non-empty string; an `end` line additionally requires `num_turns` (a
finite non-negative int) and `total_cost_usd` (a finite non-negative
number) to both be present. The `end` line also carries `errors` (list),
`model_attributable` (bool -- the within-role-fallback trigger, SKILL.md
section 4), and `git_ok` (bool -- whether the wrapper could read a trustworthy
HEAD/porcelain in the worktree at completion).

`$CORE status` folds each task's lines (`fold_spend`) into a `spend` object
(`usd`, `turns`, `launches`, `unknown_cost_launches`, `skipped_lines`) and
adds two summary keys alongside the per-task results: `_totals` (the same
keys summed across every task, plus `untracked_launches` -- non-`mech`
`workers[]` entries, which carry no ledger) and `_orphans` (a sorted list of
task ids with a `.spend.jsonl`/`.done.json` sidecar but no primary
`tasks/<task_id>.json` -- surfaced for human cleanup, never auto-adopted or
relaunched).

### `think/<think_id>.launch.json` -- deep-think liveness record

Written by `$CORE run-think`, create-exclusive (`O_CREAT|O_EXCL`; a
collision is exit 2, nothing else written), before the headless launch:

```json
{
  "v": 1,
  "think_id": "think-triage-20260904170000",
  "kind": "triage",
  "task_id": null,
  "repo_slug": "<slug>",
  "model": "fable",
  "effort": "high",
  "caps": { "max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900 },
  "attempt": 1,
  "parent": null,
  "started": "2026-09-04T17:00:00Z",
  "pid": 12345
}
```

It carries the effective launch-time caps, so lost-detection and budget
math never depend on current config. A launch is **live** while its
`.launch.json` has no matching `.answer.json` and `started` is younger than
its own `caps.timeout_secs + 120s`; older is **lost**. `attempt` is `1` or
`2`; `parent` is the attempt-1 `think_id` (or `null`) -- attempt 2 (a
retry after a model-attributable failure) ties the two attempts into one
escalation for budget purposes. `think/.lock` is a repo-wide lock file held
(`fcntl.flock`, exclusive) by `run-think` from the liveness scan through the
daily-budget check to this file's create-exclusive write, released before
`claude` is launched. Validated whole on read (`valid_launch_record`): every
field typed and in range, `attempt`/`parent` consistent with the id suffix;
an invalid record is `corrupt` and `run-think` refuses (exit 4) while one
exists, since liveness cannot be judged.

### `think/<think_id>.answer.json` -- deep-think output contract

Written atomically by `$CORE run-think` (same-directory temp file, fsync,
`os.link`, temp removed on every path) in every outcome:

```json
{
  "v": 1,
  "think_id": "think-triage-20260904170000",
  "kind": "triage",
  "task_id": null,
  "repo_slug": "<slug>",
  "model": "fable",
  "effort": "high",
  "caps": { "max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900 },
  "status": "answered|unanswered",
  "reason": null,
  "answer": {
    "recommendation": "...",
    "rationale": "...",
    "options": [],
    "confidence": "high"
  },
  "subtype": "success",
  "is_error": false,
  "num_turns": 6,
  "total_cost_usd": 1.12,
  "duration_ms": 184000,
  "models_used": ["claude-fable-5-1"],
  "downgrade": false,
  "model_attributable": false,
  "permission_denials": 0,
  "errors": [],
  "session_id": "<uuid>",
  "attempt": 1,
  "parent": null,
  "started": "2026-09-04T17:00:00Z",
  "ts": "2026-09-04T17:03:04Z"
}
```

`status: answered` requires `subtype: success` AND a `structured_output`
that passes `valid_think_answer` (required keys present, no extra keys at
either level, every type/enum/length bound honoured against the schema
restated in SKILL.md section 8, Deep-think escalation). Every other case is
`unanswered` with `reason` in `max_turns`/`max_budget`/`timeout`/
`no_answer`/`error` (`no_answer` = success without a valid structured
object); `answer` is `null` when unanswered. `downgrade`/`model_attributable`/
`errors` reuse the mech ledger's helpers verbatim. `attempt`/`parent` are
copied from the launch record.

### `_think` status object

`$CORE status` gains a top-level `_think` summary folded from
`think/*.launch.json` and `think/*.answer.json`:

```json
"_think": {"launches": 3, "answered": 2, "unanswered": 1, "usd": 1.52, "turns": 9,
           "usd_today": 1.52, "live": ["think-triage-20260904170000"],
           "lost": ["think-incident-20260903120000"], "corrupt": [], "skipped_files": 2}
```

`launches` counts launch records; `answered`/`unanswered` count answer files
by `status`; `usd`/`turns` sum non-null values; `usd_today` sums committed
spend over launches whose `started` falls in the current UTC day (the
daily-ceiling input, reservation semantics: numeric answer cost when one
exists, else the launch's reserved cap -- live, lost, unwritable-answer, and
null-cost runs all count at their cap, never double-counted); `live`/`lost`
list launch records with no answer, split by the launch-liveness rule above
using each record's own `timeout_secs`; unparseable or wrong-`v` files are
skipped and counted in `skipped_files`, never fatal. No per-task field.
`_think` cannot collide with a task id.

### `workspaces/<HERDR_WORKSPACE_ID>.json` -- reverse index

Read by the monitoring hook; written by the director via
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
director merges across files on read (`$CORE status`). See
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
