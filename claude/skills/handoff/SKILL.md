---
name: handoff
description: Use when the user wants to pause work, restart the runtime, change sessions, or preserve a task for another Claude or Codex session.
---

# Handoff

Save one explicit task's intent and verified state. The same account can resume
the record from Claude or Codex. Saving never claims an orchestrator lease or
authorizes publishing, account changes, or new work.

## Prepare

1. Resolve this skill's symlink. The canonical helper is `scripts/handoff.py`
   relative to that resolved directory. Use its CLI rather than writing state
   files directly.
2. Use the current task's explicit ID, including its Herd ID when assigned.
   For a new task without an ID, choose a short descriptive ID and report it.
   Do not reuse an unrelated task just because it has the newest record.
3. Set `REPO` to the actual target checkout and `RUNTIME` to `claude` or
   `codex`. Preserve a deliberate personal-account choice with `--personal`,
   including personal quota used in a work repository. Personal repositories
   automatically select personal scope even under inherited work settings.
   Account scope describes routing; it is not proof of a logged-in identity.
4. Write a concise, self-contained brief to a unique private text file. In
   work/custom scope, author it in an existing ignored private directory of
   the selected repository, such as `.superpowers/` or `.claude/`; verify the
   directory is ignored before writing. Personal scope may use a private
   temporary file outside the repository. Use an absolute path with filesystem
   aliases resolved. Include intent, scope, constraints, pending user instructions,
   what changed, verified tests/reviews and their exact commits, private plan
   references, active workers/ownership, unresolved risks, and the next action.
   Distinguish completed evidence from proposed checks. Do not include secrets.

## Save and check

```bash
uv run --no-project --python '>=3.11' --offline --no-cache python "$HELPER" save \
  --repo "$REPO" --runtime "$RUNTIME" --task "$TASK" --brief-file "$BRIEF"
uv run --no-project --python '>=3.11' --offline --no-cache python "$HELPER" verify \
  --repo "$REPO" --runtime "$RUNTIME" --task "$TASK"
```

Add `--personal` consistently when that override applies. Supply `--base SHA`
to save a known task base; otherwise the helper records the saved HEAD as the
base and labels that choice, without inventing a fork point. `--owner-id TOKEN`
on save records an already observed ownership token. On verify, supply the
freshly observed token; without it ownership is explicitly unverified. The
helper never queries or claims Herd ownership.

Require exit 0 and inspect the JSON. Verify compares local HEAD, branch,
worktree, tracked/index diffs, and untracked path status. It does not hash
untracked contents, fetch remote refs, run tests, or execute brief instructions.
Record unexpected drift in the brief and save another immutable record when
needed. Remove only a temporary input file created by this invocation after
verification; preserve user-supplied files and legacy histories.

## Storage and restart

Records live outside Git under
`${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/workflows/handoffs/`, partitioned
by account, repository and task. `DOTFILES_HANDOFF_STATE_DIR` can override the
base, but cannot remove those partitions or place state inside the repository.
The helper publishes unique immutable history and a per-task `current.json`
under a persistent task lock. Files are private; there is no global latest task.

To import an old handoff, pass its explicit path as `--brief-file`; the helper
does not scan or rewrite old `.claude/handoffs` or `.codex/handoffs` directories.
Work/custom scope accepts plain legacy text only from the selected repository's
checkout or a linked checkout of that same repository and account. An unknown
archive location is not proof that its content belongs to the work account;
use deliberate personal scope to process it, never copy it into a work checkout
to evade this boundary. New work briefs must be authored in the private project
location described above.

Structured JSON handoff records are validated wherever they are stored. Work
imports require matching original account and repository IDs, valid record/task
identities, and an intact brief digest; the imported value is the record's brief,
not its serialized JSON. Changed, partial, malformed, or foreign records fail
closed. Explicit personal scope may import work history. This validates recorded
scope and integrity, not cryptographic authorship or logged-in account identity.

Tell the user the task ID, saved record path, and: "After restarting, use
kickoff with this task ID." A native conversation resume is also available;
the saved record remains a separate durable recovery point. Never clear or
restart a running session on the user's behalf merely because handoff succeeded.
