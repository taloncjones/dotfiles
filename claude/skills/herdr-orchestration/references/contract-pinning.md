# Contract pinning (SKILL.md section 2, all implement dispatches)

## Contract pinning (implement dispatch, all paths)

**Contract pinning (implement dispatch, all paths).** Before launching any
`implement` worker (plan-ready kickoff here, fast-path or mech kickoff here,
or phase advancement in section 2a), compute the pin: require the task
worktree clean (`git status
--porcelain` empty) and the contract on disk, checked in this order:
(1) `git ls-files --error-unmatch -- claude/contracts/<task_id>-contract.json`
succeeds -> a legacy tracked contract; accept it with `[WARNING] legacy
tracked contract; untrack it with git rm --cached before the branch ships
(the planning-artifact guard refuses new adds; DOTFILES_ALLOW_PLAN_ARTIFACTS=1
is the deliberate override)` and skip (2) -- `check-ignore` reports a
tracked path as not ignored; (2) otherwise the file must exist and
`git check-ignore -q -- claude/contracts/<task_id>-contract.json` must
succeed, so every later clean-tree gate holds; a present but unignored
contract blocks with `contract is not ignored: run update to link
~/.gitignore_global, or add claude/contracts/ to the repository's ignore
rules`. Then run
`python3 "$CORE" verify-contract --repo-slug <slug> --task-id <task_id>
--worktree <path> --contract claude/contracts/<task_id>-contract.json
--allow-unpinned --validate-only` -- it prints the sha256. A missing or
invalid contract blocks the dispatch exactly like a missing plan.

Write the validated pin with the task before dispatch. Preserve it on every
status update. A later hash mismatch (`verify-contract` exit 4) is an
integrity halt, never re-pinned by the director on its own. A deliberate
contract change follows `references/auto-actions.md` (Contract re-pin).

## Scope and path checks

A scope or path check in a contract must keep passing across main merges into
the task branch. Compute the base at run time; never write a commit literal or
the task's `base_sha` into a command.

- Base: `git merge-base <base_ref> HEAD`, where `<base_ref>` is the task's
  `base_ref` (normally `origin/main`). It is the newest main commit already in
  `HEAD`, so the diff lists only the task's own changes after any main merge.
- No `git fetch` in a contract command. A fetch makes the gate depend on the
  network. The kickoff and the director's sync fetch.
- Precondition: `<base_ref>` contains every main commit `HEAD` has merged. It
  holds when the worker merges `<base_ref>` itself under a fast-forward-only
  main. A missing ref fails the command. A ref that lags a merged main commit
  usually causes a false fail, and can hide a task edit that restores a
  forbidden file's pre-main content.
- The diff ends at `HEAD`. Commit before running the check.
- Literal path checks name only paths the PR owns (creates or edits). A path
  main can rename or remove breaks the check on the next main merge.
- A count main can move (such as skipped tests) compares `HEAD` with `$base`
  rather than a fixed number.

Allowlist (the PR changes only owned paths):

```sh
base=$(git merge-base <base_ref> HEAD) || exit 1
changed=$(git diff --no-renames --name-only "$base" HEAD) || exit 1
extra=$(printf '%s\n' "$changed" | grep -v -x -F -e <owned-path>)
[ -z "$extra" ] || { printf 'outside scope: %s\n' "$extra"; exit 1; }
```

Forbidden paths (the PR leaves these alone):

```sh
base=$(git merge-base <base_ref> HEAD) || exit 1
changed=$(git diff --no-renames --name-only "$base" HEAD) || exit 1
hit=$(printf '%s\n' "$changed" | grep -x -F -e <forbidden-path>)
[ -z "$hit" ] || { printf 'forbidden path: %s\n' "$hit"; exit 1; }
```

Repeat `-e <path>` per path. For a directory use `grep -E '^dir/'` instead of
`-x -F`. In a contract JSON `run` string, join the lines with `; ` or `\n` and
escape `"` and `\`. The capture into `changed` stops a failed `git diff` from
feeding grep an empty input, which would pass vacuously. `--no-renames`
overrides `diff.renames` (default on), which would otherwise hide a rename's
source path.
