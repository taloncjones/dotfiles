# Verification contracts for orchestrated tasks

Task: td-2026-09-01-add-verification-contracts-to-orchestrated-tasks
Branch: talon/td-2026-09-01-add-verification-contracts-to-orchestrated-tasks/verification-contracts
Status: spec (branch-only, drop before merge)

## Problem

Herdr-orchestrated task completion is gated on review judgment plus worker
testimony. `confirm-completion` correlates SHAs and provenance, and co-review
judges the diff, but nothing falsifiable must pass before a worker emits done
or before the orchestrator surfaces merge-ready. An agent can solve the wrong
task confidently and every existing gate still clears.

## Solution overview

Every orchestrated task carries a **verification contract**: a committed JSON
file listing commands that must exit 0. The contract is produced at plan time,
pinned by hash into the fenced task record at implement dispatch, and enforced
at three points:

1. **Worker gate.** The implement worker may only `emit-done --outcome
   completed` after `verify-contract` exits 0 in its worktree.
2. **Pre-review gate.** The orchestrator re-runs `verify-contract` in the
   task worktree as a co-requirement of the `completed` transition, before
   dispatching review.
3. **Post-rebase merge gate.** Before surfacing merge-ready, the orchestrator
   speculatively rebases the branch tip onto latest `origin/main` in a
   detached temp worktree and re-runs the contract there -- a one-worker
   speculative merge queue. The task branch itself never moves.

The contract check **augments** the existing `confirm-completion` /
`confirm-review` gates; it never replaces them.

## Contract file

### Location

`docs/plans/<task_id>-contract.json`, committed on the task branch with
`git add -f` (docs/ is gitignored) under the existing "(branch-only, drop
before merge)" convention -- same lifecycle as the spec and plan it belongs
to. Branch-committed (not a STATE_ROOT sidecar) because:

- It travels with the branch through rebases, so the post-rebase gate reads
  the same artifact it pinned.
- codex-plan-review sees it in the branch diff, so the contract itself is
  reviewed with the plan.
- Tamper-evidence: the orchestrator pins the file's sha256 into the fenced
  task record at implement dispatch. A STATE_ROOT copy would be writable by
  any worker (emit-done is unfenced) with nothing anchoring it to the
  reviewed plan.

### Schema (v1)

```json
{
  "v": 1,
  "task_id": "td-2026-09-01-add-verification-contracts-to-orchestrated-tasks",
  "commands": [
    {
      "name": "core-tests",
      "run": "sh claude/hooks/herdr-orch.test.sh",
      "timeout_secs": 600
    }
  ]
}
```

Validation (fail closed on any violation):

- `v` must be the integer 1 (not `true`).
- `task_id` must equal the task being verified.
- `commands` must be a non-empty list of objects; each must carry a non-empty
  string `name` (unique within the file) and non-empty string `run`;
  `timeout_secs` optional, positive int, default 600.
- Unknown top-level or per-command keys are rejected (schema drift surfaces
  instead of silently passing).

### Authoring rules (plan phase)

The plan worker authors the contract alongside the plan. Commands must be:

- **Falsifiable**: each verifies an acceptance criterion of the plan; a
  freshly-broken implementation must make at least one command fail.
- **Repo-local and worktree-safe**: run from the worktree root, read/write
  only inside the worktree (build dirs, tmp under the worktree are fine).
  Never write `STATE_ROOT`, never mutate machine state (no installs, no
  `settings.json`, no git push), never require network. The contract runner
  does not sandbox; safety is enforced by authoring rule plus the
  codex-plan-review pass that reviews the contract with the plan.
- **Deterministic**: no reliance on prior runs, ambient services, or wall
  clock.

A task whose work is docs-only still gets a contract (e.g. a shellcheck or
test-suite invariant run); the plan phase decides the commands, the schema
just requires at least one.

## Core: `verify-contract` verb

New subcommand in `claude/hooks/herdr_orch_core.py`:

```
python3 "$CORE" verify-contract --repo-slug <slug> --task-id <task_id> \
    --worktree <abs path> [--contract <relpath>] [--allow-unpinned] \
    [--validate-only]
```

Behavior (pinned mode, the default):

1. Validate `repo_slug`/`task_id` (existing validators); require `--worktree`
   to be an existing directory.
2. Read the task record `tasks/<task_id>.json`; require `contract_path`
   (worktree-relative) and `contract_sha256` fields. Missing record or
   missing pin fields -> exit 5 ("no contract pinned"). `--contract`, when
   given alongside a pin, must equal `contract_path` or the verb exits 2.
3. Resolve the contract file inside the worktree; reject a path that escapes
   the worktree (reuse `contained`). Missing file -> exit 3.
4. sha256 the file bytes; mismatch with the pinned hash -> exit 4 (tamper or
   drift -- never run mismatched commands).
5. Parse and validate the schema; invalid -> exit 2.
6. Run each command in order via `sh -c <run>` with `cwd=<worktree>`,
   inheriting env, enforcing `timeout_secs` per command
   (`subprocess.run(timeout=...)`). Print each command's name and exit
   status; on the first failure or timeout print `FAIL <name> exit=<n|timeout>`
   and exit 1. All pass -> print `PASS <n> commands` and exit 0.

Read-only with respect to STATE_ROOT: the verb reads the task record and
never writes any state. Exit codes: 0 pass, 1 command failed/timeout, 2
usage/validation, 3 contract file missing, 4 hash mismatch, 5 no pin.

### Unpinned and validate-only modes

- `--allow-unpinned` (requires `--contract <relpath>`): skip steps 2 and 4
  (no record pin); otherwise identical. Used ONLY by the plan worker to prove
  its authored contract is well-formed and runnable. The orchestrator never
  uses it.
- `--validate-only`: perform steps up to schema validation, print the file's
  sha256, run nothing. Exit 0 valid, 2 invalid, 3 missing. Combined with
  `--allow-unpinned` this is the pin source at dispatch time.

A contract may legitimately FAIL pre-implementation (it tests the new
behavior); the plan worker's obligation is schema validity
(`--allow-unpinned --validate-only` exit 0) plus judgment on which commands
can already run.

## Pinning (orchestrator, fenced)

At phase advancement to implement (SKILL.md section 2a), after verifying spec
+ plan landed, the orchestrator additionally:

1. Verifies the contract is tracked at the branch HEAD:
   `git cat-file -e HEAD:docs/plans/<task_id>-contract.json`.
2. Runs `verify-contract --allow-unpinned --validate-only --contract
   docs/plans/<task_id>-contract.json --worktree <path>`; captures the
   printed sha256.
3. Writes `contract_path` and `contract_sha256` into the task record via the
   existing fenced `write-task` (no new fenced verb).

A missing or invalid contract blocks phase advancement exactly like a missing
plan: the plan phase is not complete. For a **plan-ready** kickoff (spec+plan
already committed, no plan phase), the same three steps run during kickoff
before the implement worker launches; a plan-ready item without a contract is
treated as raw (dispatch a plan worker to author one).

Task record additions (`references/state-layout.md`):

```json
{
  "contract_path": "docs/plans/<task_id>-contract.json",
  "contract_sha256": "<64hex>",
  "merge_check": null
}
```

`merge_check` (post-rebase gate result, orchestrator-written):

```json
{
  "base_main_sha": "<40hex>",
  "branch_head_sha": "<40hex>",
  "result": "pass|fail|conflict",
  "ts": "..."
}
```

## Gate 1: worker emit-done

`references/brief-template.md` implement-phase close gains a step before
emit-done:

> Run `python3 .../herdr_orch_core.py verify-contract --repo-slug <slug>
> --task-id <task_id> --worktree <worktree_path>`. You may run
> `emit-done --outcome completed` ONLY after it exits 0. If you cannot make
> it pass, emit `failed` or `paused` instead -- never `completed`.

The plan-phase close gains the authoring obligation: contract file written,
schema-valid (`--allow-unpinned --validate-only` exit 0), committed with the
plan.

This gate is procedural (worker-side); the orchestrator never trusts it --
gate 2 is the enforcement.

## Gate 2: orchestrator pre-review

SKILL.md section 4 completion correlation gains a sixth fact:

6. **Contract gate:** `verify-contract` (pinned mode) exits 0 in the task's
   worktree.

Only when all facts hold does the task transition to `completed`. On a
contract failure with an otherwise-correlated `done.json`: the task stays
`in-progress`, the orchestrator surfaces the failing command output, and the
recommended next action is resuming/re-briefing the implement worker with the
failure. No new status. Exit 4 (hash mismatch) or 5 (no pin) is surfaced as a
distinct integrity problem, not a test failure -- the orchestrator halts
advancement for that task and reports it; it never re-pins to make a
mismatch go away.

Section 5 review dispatch relies on the `completed` status it already guards
on, so review can no longer be dispatched for a contract-failing revision.
Because the contract gate runs at the `completed` transition, a later HEAD
advance re-enters this gate automatically via the existing stale-review reset
(reset to `completed` requires re-correlation, which now includes the
contract).

## Gate 3: post-rebase speculative merge check

SKILL.md section 6, before surfacing merge-ready (after `confirm-review`
passes and the vibe-audit gate clears):

1. `git fetch` the base remote; capture `MAIN_SHA` = `origin/<default>`.
2. If the task record's `merge_check` already records `result: "pass"` for
   this exact pair (`base_main_sha` == `MAIN_SHA` and `branch_head_sha` ==
   live HEAD), skip re-running and surface (idempotent across check-ins).
3. Otherwise run the speculative check in a **detached temp worktree** so the
   task branch never moves and the stale-review rule is never tripped:
   - `git worktree add --detach <tmp> <branch_head_sha>` (a branch already
     checked out elsewhere cannot be added again, but a detached SHA always
     can -- this is why the temp worktree is detached).
   - `git -C <tmp> rebase <MAIN_SHA>` (rebases the detached HEAD; on
     conflict, `git -C <tmp> rebase --abort` and record `result: "conflict"`).
   - On a clean rebase: `verify-contract --worktree <tmp>` (pinned mode; the
     contract file rides the rebased commits and rebase preserves blob
     content, so the hash still matches). Record `pass`/`fail` from its exit.
   - Always: `git worktree remove --force <tmp>` and prune. The temp worktree
     lives under the orchestrator's scratch area, never inside the task
     worktree.
4. Write `merge_check` into the task record (fenced `write-task`).
5. Surface merge-ready ONLY on `result: "pass"`. On `fail` or `conflict` the
   task stays `reviewed` but is NOT surfaced; the orchestrator reports the
   cause (contract broke against new main, or rebase conflict) and the
   recommended action (re-brief the impl worker to rebase and fix; the
   resulting new HEAD flows through the existing stale-review reset into a
   fresh completed -> review cycle).

Staleness rule: any recorded `merge_check` whose `branch_head_sha` != live
HEAD or whose `base_main_sha` != current `origin/<default>` is ignored
(re-run). `merge_check` is reset to `null` whenever `review_head_sha` is
cleared by the stale-review rule.

## Interaction table (augment-only guarantee)

| Existing gate | Unchanged behavior | Contract addition |
| --- | --- | --- |
| `confirm-completion` | SHA/provenance correlation | AND verify-contract exit 0 (gate 2) |
| `should-dispatch-review` | once per HEAD | unchanged (guarded upstream by gate 2) |
| `confirm-review` | three-SHA + provenance + blocking-count | unchanged |
| vibe-audit | grown-resolution audit | unchanged; runs before gate 3 |
| stale-review reset | clears `review_head_sha` on HEAD advance | also nulls `merge_check` |

No existing verb's semantics change. `verify-contract` is a new verb;
`write-task` carries two new optional fields plus `merge_check`.

## Testing

Extend the existing suites (`claude/hooks/herdr-orch.test.sh` unit-level,
`claude/hooks/herdr-orch-contract.test.sh` walkthrough):

- Schema validation: valid contract passes; empty commands, unknown keys,
  bad types, wrong task_id all exit 2.
- Hash pin: matching pin runs; mismatch exits 4 without running any command
  (prove via a command with a side-effect file that must not appear).
- No pin: exit 5. `--allow-unpinned` runs without a record.
- Execution: passing commands -> exit 0; first failure stops the run
  (side-effect proof) -> exit 1; timeout -> exit 1.
- Path safety: a contract path escaping the worktree is rejected; missing
  file exits 3.
- Walkthrough: plan worker authors + validates contract; orchestrator pins
  via write-task; impl-phase verify passes; a tampered contract file flips to
  exit 4; a merge_check record round-trips through write-task.
- The speculative-rebase step is skill-side (git orchestration, not core) --
  covered by the walkthrough only at the record level (merge_check write),
  with the git mechanics documented in SKILL.md, not simulated.

## Out of scope

- Sandboxing contract commands (authoring rule + plan review is the guard).
- Multi-worker merge queues (one task at a time; `merge_check` is per-task).
- Contract evolution mid-implement (a changed contract requires a new plan
  commit and a re-pin, which only the orchestrator performs at an explicit
  re-brief; not automated).
- Budget-capped model tiers (sibling task; this spec keeps SKILL.md and
  brief-template diffs additive so it rebases cleanly under that follow-up).
