# Phase advancement (SKILL.md section 2a)

## 2a. Phase advancement (plan -> implement) -- raw items only

A `plan` worker's confirmed completion advances the SAME task to its implement
phase; it never marks the task `completed` and never dispatches review.

1. Run `confirm-plan` with the selected account payload root, task, workspace,
   and current HEAD. It validates the current plan attempt and its artifact
   list: exactly one `spec` (the PRD) and at most one `plan` (a legacy pair),
   as regular files with contained paths and SHA-256 hashes.
   Use the `co-review` artifact helper to freeze reviewed documents under
   `<account_payload>/herdr-orch/<slug>/artifacts/<task_id>/<launch>`. Record the same artifact
   references in the task and plan completion. Never commit private PRDs or plans.
   When the task lacks the references, `confirm-plan` accepts the correlated
   plan completion's list; record those confirmed references in the task with
   `write-task` before `settle` and the implement dispatch, because the
   implement worker's `emit-done` replaces `done.json`.
   Before advancing, run the Lesson harvest (section 4) on the plan worker's
   pane.
2. A plan-only milestone may have HEAD equal to base. The contract the plan
   worker authored stays untracked and ignored; validate and pin it before
   implementation (Contract pinning, section 2). Final HEAD may differ from
   the launch's source HEAD; both are recorded for different checks.
3. After `confirm-plan`, run
   `python3 "$DISPATCH" settle --repo-slug <slug> --session <id> --fence <fence> --task-id <task> --workspace-id <ws> --cwd <worktree> --launch-id <plan launch>`
   so the planner exits and the root pane is back at a shell (the implement
   launch requires one); then reuse the task's branch/workspace.
   Resolve `python3 "$RUNTIME" route --runtime <claude|codex> --role implementation --risk normal`
   again with `--config-json "$ROUTE_CONFIG"` (step 6 snippet), require readiness,
   append a new strict attempt through
   the adapter, update the display role, and give the worker the exact frozen
   PRD path and hash (and the legacy plan's, when present). Status remains `in-progress`.
4. Failed/paused planning never launches implementation. `confirm-completion`
   is the separate final implementation gate and rejects a plan milestone.
