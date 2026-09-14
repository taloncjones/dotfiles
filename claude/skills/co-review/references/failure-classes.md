# Co-Review Failure Classes

Matching a class below establishes that a defect exists, not that it
blocks. Reachability is ruled separately by the orchestrator: a defect in
code no supported configuration reaches is recorded at its true severity
and does not block.

Round-1 finders probe EVERY class below against the frozen diff, not just
the classes the diff superficially suggests. The pre-freeze self-audit
walks the same list. One line per entry; keep entries concrete enough to
probe mechanically and general enough to outlive one incident.

Growth rule: when a complete round after round 1 yields a new-surface
finding and the reviewed change lives in the repository that owns this
rubric (dotfiles), the fixer adds or generalizes a class entry in the
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
- Replayable-file authority: authority decisions that trust replayable or
  reconstructible files over durable registries; high-water counters or
  generation fences that can move backward.
- Resume/retry revalidation: resume or retry paths that skip live
  revalidation the first-run path performs (SHA, approval, occupancy,
  lease ownership).
- Writer/reader parity: writers publishing payloads their own bounded
  readers refuse (size caps, shape, encoding limits).
