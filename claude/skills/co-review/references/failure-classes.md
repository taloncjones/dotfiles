# Co-Review Failure Classes

Finders probe EVERY class below against the frozen diff, not just
the classes the diff superficially suggests. The pre-freeze self-audit
walks the same list. One line per entry; keep entries concrete enough to
probe mechanically and general enough to outlive one incident.

Growth rule: when a review yields a defect no class below would have
prompted, grow the rubric. If the reviewed change lives in the repository
that owns this rubric (dotfiles), add or generalize a class entry in the
same commit as the fix. When reviewing any other repository, record the
missed class and update this file in dotfiles as a separate authorized
change.

## Classes

- Quoting and separators: word-splitting of unquoted expansions, NUL vs
  newline separation, filenames with spaces/newlines/globs, `xargs`
  without `-0`.
- Symlinks: reads or writes through user- or attacker-placed symlinks;
  symlinked parent directories of inspected paths.
- Content filters: `clean`/`smudge` filters and `core.autocrlf` altering
  bytes between worktree and object store (`git hash-object` vs on-disk
  bytes).
- Hostile or surprising git config: `branch.<name>.mergeoptions`,
  `merge.autostash`, `url.<base>.insteadOf` rewrites, `core.sshCommand`,
  repo-local hooks.
- Signals and TOCTOU: state checked before use with a window between
  check and use; interrupted operations leaving partial state; trap
  ordering interacting with `set -e`.
- Temp-dir lifecycle: `rm -rf` of a variable that can be empty or
  redirected; traps firing on paths outside the intended root; mktemp
  race or reuse.
- Fail-open exits: error paths that return success; allowlists consulted
  after the action they gate; `|| true` swallowing a guard's verdict.
- Ignored/untracked overwrites: operations that clobber gitignored or
  untracked files the user owns.
- Fetch/ref races: a base ref moving between resolution and use; stale
  local refs standing in for remote state.
- Replayable-file authority: stale or reconstructible evidence that can stand
  in for a fresh independently retained identity, including generation fences
  or high-water counters that can move backward. Judge the control against the
  declared threat model and single-coordinator scope; do not assume a durable
  registry is required.
- Resume/retry revalidation: resume or retry paths that skip live
  revalidation the first-run path performs (SHA, approval, occupancy,
  lease ownership).
- Writer/reader parity: writers publishing payloads their own bounded
  readers refuse (size caps, shape, encoding limits).
