# Idle task workspaces: close-idle and reopen (SKILL.md sections 4 and 6)

A parked task has no live worker. Its herdr workspace only keeps the
worktree reachable, and the director reads the worktree directly. `close-idle`
closes that workspace; `reopen` brings one back before a step that needs a
pane. The worktree, branch and task record stay throughout.

## When `close-idle` fires

The check-in reports `action=close-idle` (ranked last, after `ship`) when
all of these hold:

- The herdr poll succeeded and the worktree exists.
- `status` is `reviewed` and `ship_parked_head` equals `review_head_sha`.
- The record's `workspace_id` is listed by herdr with the task worktree as
  its checkout, and herdr lists no agent in it.

Run the printed `close-idle` line. It re-checks parking under the fence,
then calls the same two-pass check `archive-task` uses: the workspace must be
on the task worktree, hold no agent, and hold only idle shell panes.

| Result | Exit | Meaning |
| --- | --- | --- |
| `closed` | 0 | Workspace closed; the record gains `workspace_closed`. |
| `already-closed` | 0 | The record already names it closed and herdr lists no such workspace. |
| `kept` | 3 | Nothing closed or written. `kept` is `other-worktree`, `live-agent`, `busy-pane`, `changed` or `close-failed`; the next check-in prints the line again. |
| refused | 2 | The task is not parked at its reviewed head, the workspace is not the record's, or the worktree is gone. |

herdr has no compare-and-close. A process started in the workspace between
the second check and the close is closed with it.

## Which steps need a workspace

| Step | Needs a pane | With a closed workspace |
| --- | --- | --- |
| `merge-ready`, `carry-review`, ship push and PR create, teardown, `archive-task`, `settle`, `sweep`, `accept-review` | no | Unchanged; they read the worktree. |
| Repair or relaunch (`render-brief`, `launch`) | yes | Run `reopen` first; `launch` refuses a closed workspace. |
| `dispatch-gate --phase review` and `--phase ship` | yes | The gate reopens by itself when the implement row's workspace is not open on the worktree. |

## `reopen`

`python3 "$DISPATCH" reopen --repo-slug <slug> --task-id <task> --session <id> --fence <fence> --cwd <worktree> --runtime <runtime> [--personal]`
prints `{status, workspace_id, pane_id}`:

- `open`: the record's workspace is listed on the worktree. `pane_id` is
  `workspace_root_pane`, or `null` for a kickoff workspace never reopened (use
  the implement row's pane as before).
- `reopened`: herdr had no workspace on the worktree, so reopen ran
  `herdr worktree open --cwd <primary_root> --path <worktree> --no-focus`
  and listed again; or it adopted the one workspace already on the worktree.
  The record gets the new `workspace_id` and `workspace_root_pane`, and loses
  `workspace_closed`. The new workspace id comes from the list, never from
  the open reply.

Use the returned `workspace_id` and `pane_id` for `render-brief` and
`launch` (a repair launch needs the new `workspace_id` in the record first;
`reopen` writes it).

Refusals (exit 2). A refusal writes nothing beyond a workspace index created
for this task.

| Code | Cause and recovery |
| --- | --- |
| `worktree-missing` | The worktree directory is gone; the task is abandoned or merged. |
| `primary-unknown` | git cannot prove the main checkout (separate git dir). |
| `ambiguous-workspace` | Herdr lists more than one workspace on the worktree; close the extras by hand. |
| `open-unconfirmed` | After `worktree open`, herdr does not list exactly one workspace on the worktree. Re-run: it lists first. |
| `index-conflict` | `workspaces/<ws>.json` names another task or is unreadable; resolve the index by hand. |
| `pane-ambiguous` | The new workspace holds other than one pane. Close the workspace by hand and run `reopen` again. |
| `root-pane-gone` | `workspace_root_pane` is no longer listed. Close the workspace by hand (or run the printed `close-idle` line) and run `reopen` again. |

## Record fields

`workspace_closed` and `workspace_root_pane` are written only by `close-idle`
and `reopen` (`references/state-layout.md`). Once a record has
`workspace_root_pane`, `write-task` refuses a change to `workspace_id`;
re-read the record after a reopen before writing it back.

## Interruptions

| Window | Result and recovery |
| --- | --- |
| `close-idle`: close done, record write not | Only the marker is missing; the check-in stays quiet. `reopen` keys on herdr's list, and `launch` into the old id fails as a herdr pane error. |
| `close-idle`: close raised or its reply was lost | `close-failed`, exit 3; re-run. |
| `reopen`: open done, record write not | Re-run: one workspace on the worktree is adopted. |
| `reopen`: record written, relabel lost | A re-run returns `open`; the next `write-task --present` relabels. |
| Gate: reopen done, later step interrupted | A retry takes the fast path and splits `workspace_root_pane`, never a leftover gate pane. A leftover idle pane closes with the workspace at the next `close-idle` or `archive-task`. |
