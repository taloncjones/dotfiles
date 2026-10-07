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

- Structure fit: new code lives where a reader would look for it; a file
  or function that takes on a second responsibility, or keeps absorbing
  sibling cases, is split (one file per family of cases, not one file for
  all); no new helper, parser or module duplicates one the repository or
  its submodules already has (search before reporting); a different module
  boundary or file layout would read better; a simpler approach meets the
  stated goal. A finding names a concrete proposed layout: what moves where.

### Lenses

Read the changed paths from the frozen diff's `diff --git` lines and apply
every lens a changed path selects; a mixed diff applies both. Name the
applied lenses in your `Architecture` section.

| Changed path in the dotfiles repository                                                                                                                                                                             | Lens        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| `claude/skills/**`, `claude/hooks/**`, `claude/rules/**`, `claude/settings.json.tmpl`, `codex/skills/**`, `codex/hooks/**`, `git/hooks/**`, `install/**`, `zsh/**`, `bootstrap*.sh`, any `CLAUDE.md` or `AGENTS.md` | Operator    |
| every other path                                                                                                                                                                                                    | Correctness |

In any other repository, apply the Operator lens to the files that
repository ships as agent instructions, skills, hooks, settings templates,
installers or shell startup, and the Correctness lens to everything else.

Correctness lens:

> You are the staff engineer who maintains this code after it merges.
> Trace each changed function to its callers and to the tests that
> exercise it. Is the logic correct for every input and state those
> callers can produce, including errors, retries and interrupted runs?
> Does each test fail when the behavior it names breaks? Does the change
> fit the structure readers expect (the Structure fit class)?

Operator lens:

> You own every machine and session that loads this file, and you answer
> the support ticket when it breaks. What breaks on a machine that has
> not run `update` since the previous version, on a fresh cloud
> container, and under the work config directory (`CLAUDE_CONFIG_DIR`
> set)? What does a session already running the old version do when it
> next reads this text or runs this hook? Which hook, drift check or
> test should have caught a break here, and does it? What is the
> rollback, and does reverting the commit undo the machine state this
> change creates?

### Reporting structure and lenses

Every reviewer report has an `Architecture` section: the lenses applied
and the changed paths that selected them, then each Structure fit finding
with its proposed layout, or one line of evidence that none applies. A
Structure fit finding is `advisory` by default. It is `major` or higher
only when it cites the applicable required contract and a concrete
material consequence under the policy's impact rule, for example a
selection mechanism that lets new tests silently drop out of a
configuration. Taste, naming and speculative extension never block.
