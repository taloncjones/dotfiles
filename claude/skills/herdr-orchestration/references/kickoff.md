# Kickoff (SKILL.md section 2)

## 2. Kickoff (human designates) -- idempotent, ownership-tracked

Kickoff dispatches a worker whose **phase and model depend on plan-maturity**,
so brainstorm/spec/plan judgment is never delegated to the cheap impl model:

- **Plan-ready item** -- a refined Jira ticket, or a task that already has a
  reviewed, frozen private PRD (or a legacy spec and plan) with recorded
  hashes: dispatch an `implement` worker directly (only after the contract
  pinning steps at the end of this section; a plan-ready item without a
  validated on-disk contract is treated as raw), using
  `python3 "$RUNTIME" route --runtime <claude|codex> --role implementation --risk normal`
  with `--config-json "$ROUTE_CONFIG"` (step 6 snippet) and the native adapter
  (section 8). An unready route blocks this dispatch.
- **Fast-path item** -- a repo todo, never a Jira key, handoff, or mech
  kickoff, that the owner kicks off with `kick off <item> direct`: dispatch
  an `implement` worker directly with no plan worker, using
  `python3 "$RUNTIME" route --runtime <claude|codex> --role implementation --risk normal`
  with `--config-json "$ROUTE_CONFIG"` (step 6 snippet), the native adapter
  (section 8), the Fast-path implement brief variant
  (references/brief-template.md), and the Contract pinning steps at the end
  of this section. The designation is the owner's; the director never
  infers it. `kick off <item> as raw` always takes the raw path.
- **Raw item** -- the fallback: any other todo or handoff with no PRD:
  dispatch a `plan` worker using
  `python3 "$RUNTIME" route --runtime <claude|codex> --role planner --risk normal`
  with `--config-json "$ROUTE_CONFIG"` (step 6 snippet) and the native adapter
  first. It runs the repo's brainstorm -> PRD -> one independent PRD review
  pipeline; Claude uses `codex-spec-review` and Codex uses
  `claude-spec-review`. It may ask the owner on a decision the repo cannot
  settle; a plan pane waiting on that answer shows `blocked` (section 4).
  It freezes one private PRD and the contract and emits completion as phase
  `plan`. On confirmed plan completion the director advances the same
  task/branch to its `implement` phase (native implementation route,
  section 2a).

Maturity check: a Jira ticket in a refined/ready state, or a verified
private PRD (or legacy spec+plan) for the task, is plan-ready; a repo todo
kicked off `direct` is a fast-path item; anything else is raw. When unsure,
treat it as raw -- the PRD phase is one document and one review.

Split before planning: when a raw todo's Solution names two or more
independent mechanisms (each could ship alone), propose a split to the
owner with `AskUserQuestion` before dispatching the plan worker,
recommendation first; dispatch the first slice on a yes, the whole item on
a no.

Fast-path contract source, in order: (1) a contract already on disk at
`claude/contracts/<task_id>-contract.json` -> use it; (2) the todo's
`## Verification` section, one backticked command per bullet -> the director
writes `{"v": 1, "task_id": "<task_id>", "commands": [{"name": "verify-1",
"run": "<command>"}, ...]}` there, then appends every
`config.mech.contract_commands` entry unchanged as regression commands when
that list exists. When no contract is on disk, a todo with no
`## Verification` section is raw: the config suites alone cannot meet the
rules below. Before writing (2), apply
the plan-phase contract rules (references/brief-template.md): every command
repo-local, deterministic, and worktree-safe (no STATE_ROOT
writes, no machine-state mutation, no network, no secret echo), and at most
32 commands. Every `verify-*` command must also be falsifiable (it passes
once the stated fix lands); the appended `config.mech.contract_commands`
regression commands are exempt. Falsifiability is observed, not judged, not
just claimed: at least one `verify-*` command expected to fail until the
todo's fix lands must actually fail -- run every `verify-*` command once in
the fresh worktree at `base_sha` before pinning; at least one must exit
non-zero. A todo whose Verification section is vacuous (every `verify-*`
command already passes at base) refuses the `direct` kickoff; offer it as raw. A command that
misses a rule, or any doubt, refuses the `direct` kickoff; offer it as raw.
`verify-contract --validate-only` is a schema check only (it accepts
`run: "true"`); a schema rejection also refuses the `direct` kickoff; offer it as raw. Never `git add`
or commit the contract. Then run the Contract pinning steps below unchanged,
and note the fast path in the director queue log.

- **Mech item** -- a human-designated mechanical task (`kick off <item> as
mech [max-turns <int>] [budget <number>]`, or todo frontmatter `tier: mech`
  with optional `mech_max_turns` / `mech_max_budget_usd`; instruction values
  override frontmatter field by field; any other form is not a mech kickoff).
  Never raw: it skips the plan phase and dispatches `phase: implement`,
  `role: mech`. Native Claude/Codex dispatches resolve
  `python3 "$RUNTIME" route --runtime <claude|codex> --role mechanical --risk normal`
  and use the bounded runtime runner with supported limits; an unready route
  or unsupported limit blocks launch. Codex does not accept Claude turn/USD
  caps. Only an explicitly selected legacy Claude `run-mech` launch uses
  the legacy `routing-table` mech entry and caps from
  `python3 "$CORE" mech-caps --repo-slug <slug> [--max-turns N]
[--max-budget-usd X]` (exit 5 refuses the kickoff with its message; never
  clamp by hand). Contract source, in order: (1) present on disk at
  `claude/contracts/<task_id>-contract.json` (untracked and ignored; a copy
  tracked at HEAD from before this rule is accepted with the legacy warning
  below) -> use it; (2) `config.mech.contract_commands` present, worktree
  clean, and the branch either created by this kickoff or adopted with HEAD
  == `base_sha` ->
  `python3 "$CORE" mech-contract --repo-slug <slug> --task-id <task_id>
--worktree <path> --base-sha <base_sha>` writes it; never `git add` or
  commit it -- it stays untracked and ignored, so **`Launch base`** stays the
  launch HEAD (no post-contract commit moves it), and `base_ref` still names
  the ref; (3) else refuse: "mech kickoff needs a contract on disk or
  `mech.contract_commands` in config; kick off as raw instead". A mech
  contract has no frozen copy: if the worktree copy is lost the contract
  gate halts and regeneration needs the user's task authorization and a
  fresh pin. Then run the "Contract pinning" steps below unchanged.

The steps below call the dispatched worker "the worker"; they apply to whichever
phase is launched (`plan` for a raw item, else `implement`), with the
phase-appropriate brief (references/brief-template.md) and model.

1. Resolve the item (Jira MCP for a ticket key, the todos skill for a bare
   todo) -> `task_id`. Abort if unresolved.
2. **Idempotency:** `python3 "$CORE" status --repo-slug <slug>` plus a check of
   `tasks/<task_id>.json`. Existing record + live worker -> refuse, report,
   offer to focus the existing workspace. Existing record + worker gone ->
   offer resume or cleanup. No record -> proceed.
3. Resolve `base_ref` (`config.default_base`, else `origin/<default>`),
   `git fetch`, record the resulting `base_sha`. If offline, warn and require
   explicit confirmation before proceeding on a stale base.
4. **Adopt vs create, with ownership tracking:** if the branch/worktree
   already exists, verify it belongs to this task (branch name matches
   `<user>/<task_id>/<slug>`) before adopting, and mark it
   `created_by_this_orch: false`. Otherwise create it and mark `true`. This
   flag gates cleanup on failure (step 9).
5. **`herdr worktree create --cwd <repo_root>`** (or `worktree open --cwd
<repo_root>` if adopting) -- the explicit `--cwd` is MANDATORY, never a bare
   path. A PreToolUse hook (`claude/hooks/herdr_worktree_guard.py`) denies a
   `worktree create` that lacks `--cwd`; `open` is not hook-guarded, so its
   `--cwd` stays on you. Resolve `<repo_root>` first as the intended repo's
   top level:
   `REPO_ROOT="$(git -C <path-in-repo> rev-parse --show-toplevel)"`.
   **Why (submodule-adjacency mis-anchor):** when the target path sits inside or
   beside a git submodule, a bare `worktree create` can anchor the new worktree
   to the SUBMODULE instead of the intended repo -- incident 2026-08-28, rw-bess:
   a `BESS-2334` create defaulted to the `rw-test-infrastructure` submodule
   (`repo_root: .../rw-test-infrastructure`) because several active workspaces
   lived there, risking a ticket's work built in the wrong repo. Explicit
   `--cwd <repo_root>` pins the anchor.
   Parse the `.result` for the new `HERDR_WORKSPACE_ID` and worktree path --
   never derive them. **Then verify the anchor before doing anything else,
   comparing canonical repo identity, not checkout path:** herdr reports the
   shared repository root in `.result...repo_root`, but in a linked worktree
   (every herdr workspace) `git rev-parse --show-toplevel` on `<path-in-repo>`
   returns that worktree's own checkout path, not the shared root -- a
   `--show-toplevel` comparison false-flags every correctly anchored create.
   Resolve `repository_context` for the selected original checkout and returned
   worktree. Their canonical `repo_id`/`common_dir` must agree. Use a proven
   `primary_root` when comparing Herdr's reported repository root. Git metadata
   may live elsewhere, so never derive primary_root from the common-dir parent.
   If the primary root is unknown, preserve that uncertainty and require the
   selected account/worktree to be explicitly verified before launching.
   On a mismatch the create mis-anchored -- do NOT launch a worker.
   **Unwind, but only for a resource this director created**
   (`created_by_this_orch: true` from step 4 -- mirrors the failure-cleanup
   gate in step 9): remove the empty worktree
   (`herdr worktree remove --workspace <ws_id>`) and delete the stray branch
   (`git -C <mis-anchored repo_root> branch -D <branch>`). For an **adopted**
   resource (`created_by_this_orch: false`) never unwind -- a mismatch there
   means the pre-existing branch/worktree is not what step 4 expected; leave it
   untouched (no `worktree remove`, no `branch -D`) and just surface the
   mismatch. Either way, stop after surfacing the mismatch. Only a
   verified-correct anchor proceeds. Label the workspace `<task_id>`; step 6 replaces it with the state label.
6. **Publish the task before launch under the owner fence.** The record
   carries `title` (the Jira summary or the todo title) and `workspace_id`
   (the new `HERDR_WORKSPACE_ID`); publish it with `write-task --present`,
   which relabels the workspace `plan: <title>`. Preserve the
   pinned contract, branch, base, worktree, and account binding. New records
   start with `workers: []` and `status: in-progress`; a failed launch remains
   visibly retryable. Write the workspace index through `write-index`.
   For a repo TODO, persist its exact filename stem as `todo_id`; do not infer
   this field from a display label. Run the installed `todos.sh ready <id>
--offline` before dispatch. Exit 0 permits launch; blocked, missing, invalid,
   or unknown dependencies keep the task queued. The adapter checks this
   persisted binding again outside the owner lock. An old record without a
   binding needs explicit source reconciliation before a new TODO kickoff.
7. **Resolve and launch through the adapter** (section 8). The adapter reserves
   a unique attempt under the owner transaction before contacting Herdr, then
   rechecks the fence on return. The attempt binds `launch_id`, runtime, phase,
   workspace, pane, source HEAD, requested model/effort, and account. A failed
   launch is recorded as failed; never erase it to make the task look unstarted.
8. **Jira writeback**, only for a Jira task with existing user authorization:
   transition to In Progress (section 10). Personal todos do not use Atlassian.
9. **Partial failure:** leave adopted resources untouched. Stop or clean only
   resources proven to belong to this launch, after checking no worker remains
   active. Never delete a task/worktree because a prompt wait timed out.
