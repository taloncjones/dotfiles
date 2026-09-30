---
name: pr-status
description: 'Use for a PR status table - every open PR in this repo with its head, CI, co-review verdict at head, bench evidence, body currency, draft state and what it waits on. Trigger on "pr status", "PR table", "status of the PRs", "what are the PRs waiting on", or /pr-status [pr ...] [--repo owner/name].'
---

# PR Status

One Markdown table, one row per PR. A script computes every cell from fixed
rules; nothing in the table is model judgement.

## Run

Resolve the directory containing this loaded SKILL.md (including its symlink
target), then run from the repo the user is asking about:

    python3 "<loaded-skill-directory>/scripts/pr_status.py" --markdown <args>

Pass the user's arguments through: PR numbers, `--repo owner/name` (only with
PR numbers), `--bench-workflow FILE`, `--config PATH`.

Print the script's stdout verbatim, with no prose above it. Only when the
user asked for an "order" or a "plan", add at most one line per PR below the
table with its next step, in the order to take them.

This table is terminal output for the owner and is never posted to a PR,
issue or ticket. It is the one exception to the no-tables rule for PR text.

Exit 1 means at least one row is an `error:` row; show the table anyway.
Exit 2 means no table (gh missing or not logged in, or a usage error); show
the stderr line.

## Which PRs

- With PR numbers: those, in `--repo` or the current repo.
- Without: in a herdr-managed repo, every task record under the state root's
  `tasks/` with a `pr_number` (or `pr`) whose status is not `merged`,
  `abandoned` or `failed`, plus the current branch's PR. A task's
  `submodule_pr` (`{"repo": "owner/name", "number": n}`) adds that PR as its
  own row. Rows found this way that are no longer open are left out.

## Columns

- PR: `[#n](url) title`, prefixed with the short repo name for another repo.
- Head: the head commit, linked.
- CI: `green`, `<k> failing: <names>`, `<k> pending`, or `no checks`;
  SKIPPED and NEUTRAL checks are ignored.
- Co-review at head: the newest co-review marker by the logged-in gh user
  whose sha is the head: `r<round> <VERDICT>` for a round marker or
  `audit APPROVE` for the ship audit comment, linked. `stale (... at <sha>)`
  when the newest marker is for an older head; `none` without one.
- Bench / UAT: the newest bench workflow run at the head, plus runs still
  queued or in progress; `none at head`; `n/a` with no bench workflow. A
  checked test-plan box that names a run, stand, UAT or evidence and links
  it is appended.
- Body current: `yes`, or the reasons: unchecked test-plan boxes, a literal
  `<run link>` or `<n>` placeholder, a cited sha of an older branch commit.
- Draft: `yes` or `no`.
- Waiting on, first match: `merged`/`closed` (listed PRs only), `CI: <names>`,
  `CI`, `co-review at head`, `co-review findings`, `bench run`, `body edit`,
  `undraft`, `approvers (<requested>)`, then `merge (director)` where
  herdr merge authority allows it, else `merge (human)`. A row whose task
  pairs an unmerged submodule PR starts with
  `submodule PR #n merge + re-pin;`. After the submodule PR merges, the
  re-pin step is not detected.

## Configuration

A bench workflow per repo comes from the machine-local reconcile config
(`<CLAUDE_CONFIG_DIR>/reconcile/projects.json`, else
`~/.claude/reconcile/projects.json`, else
`~/.claude-work/reconcile/projects.json`): any block may carry
`"bench_workflows": {"owner/name": "<workflow file>"}`. `--bench-workflow`
overrides it for the primary repo. Keep work repo names in that file, not in
this skill.

The script is read-only: it runs gh reads (`api user`, `repo view`,
`pr view`, the issue comments API, `run list`) and posts nothing.
