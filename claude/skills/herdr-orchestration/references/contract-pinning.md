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
status update. A later hash mismatch is an integrity halt; never silently
re-pin. A deliberate contract change requires the user's task authorization
and a fresh reviewed pin.
