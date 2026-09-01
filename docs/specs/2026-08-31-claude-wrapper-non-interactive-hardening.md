# Spec: Harden the claude() zsh wrapper for non-interactive shells

Date: 2026-08-31
Branch: talon/td-2026-08-31-harden-the-claude-zsh-wrapper-for-non-interactive/claude-wrapper-harden
Source todo: `.todos/pending/2026-08-31-harden-the-claude-zsh-wrapper-for-non-interactive.md`

## Problem

The `claude()` wrapper and its `_claude_config_dir` helper live in
`zsh/functions.zsh`, which is sourced only from `.zshrc` -- an
interactive-only file. Non-interactive and login shells (`zsh -lc`,
`zsh -c`, headless probes, hook subprocesses) read `.zshenv` and
`.zprofile` but never `.zshrc`, so the account-routing logic is absent
or partially absent exactly where orchestrators, hooks, and headless
probes run.

Two confirmed live failures:

1. **Unauthenticated worker launch** (work machine, 2026-08-29): under
   `zsh -lc` the helper was missing and `CLAUDE_CONFIG_DIR` ended up
   empty; dispatched workers landed on the login screen and stalled a
   whole dispatch. The exact command resolution on that machine is not
   reconstructable from this repo (the dispatch scripts live in the
   private herdr WIP repo); the failure is consistent with either hole
   named below, and this spec closes both.
2. **Config tree dumped into the repo cwd** (this machine, 2026-08-30):
   a headless probe (`claude --model fable -p ... </dev/null`) failed
   with `claude:14: command not found: _claude_config_dir`; the wrapper
   then ran `CLAUDE_CONFIG_DIR="" command claude`, and claude treated
   the cwd as its config root, dumping `backups/`, `plugins/`,
   `projects/`, `mcp-needs-auth-cache.json` into the dotfiles repo.

## Root mechanism

Two distinct holes, one shared symptom:

- **Partial definition** (failure 2): contexts exist where `claude()`
  is defined but `_claude_config_dir` is not. Confirmed instance: the
  Claude Code Bash tool initializes its shell from a snapshot of the
  user's interactive shell; the `claude` function survived while the
  underscore-prefixed helper did not (asserted mechanism: the snapshot
  filters `_`-prefixed functions as completion functions; verified only
  by the observed error, not by reading the snapshot code). When the
  helper call fails, `cfg` is empty and the wrapper **exports an empty
  `CLAUDE_CONFIG_DIR`**, which claude resolves relative to the cwd.
- **No definition** (failure 1): under plain `zsh -lc` / `zsh -c`
  neither function exists. `claude` resolves to the bare binary with no
  routing; on a work machine in `~/Git/work` that is the wrong
  (unauthenticated) account unless the parent environment happened to
  carry `CLAUDE_CONFIG_DIR`.

The wrapper as written violates its own contract twice: it depends on a
function the calling shell may not have, and it can export an empty
config dir -- the one value worse than no value.

## Constraints

- Orchestrator and workers must share one config dir: herdr's
  STATE_ROOT derives from `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`
  (`claude/hooks/herdr_orch_core.py:156`). The sharing mechanism is
  environment inheritance: the orchestrator session exports a non-empty
  `CLAUDE_CONFIG_DIR`, and every child (probe, hook, worker launch)
  must see that value win over cwd routing. This spec's obligation is
  therefore narrow and testable: a non-empty inherited value always
  wins, in every shell mode, from every cwd. Full process-chain
  orchestration tests stay in herdr's own suites.
- Routing precedence, highest first: `--personal` > non-empty
  `CLAUDE_CONFIG_DIR` in the environment > cwd under the work tree >
  default `~/.claude`. An empty-but-exported `CLAUDE_CONFIG_DIR` is
  treated as unset at every step. `--personal` overrides an inherited
  custom value too -- it means "the personal account", not "skip work
  routing".
- Interactive UX is preserved: `~/Git/work` cwd routes to
  `~/.claude-work`; `claude-account` reports the routing. Symlinked
  paths into the work tree still route to work (`:A` resolution on
  both sides).
- `.zshenv` runs for every zsh on the system, including scripts: the
  added code must produce zero stdout/stderr on success, invoke no
  external commands (builtins and parameter expansion only), and
  degrade to a no-op (bare-binary behavior, still zero output) when
  the sourced file is missing or unreadable. Detection of that
  degraded state is the job of `symlink-audit.sh`, not the shell
  startup path.

## Target behavior (failure matrix)

"Child env" is the exact `CLAUDE_CONFIG_DIR` value in the launched
`claude` process's environment; "effective root" is the config dir the
binary uses. The wrapper always injects an explicit non-empty value
(see Design), so child env and effective root agree in every cell.
"work cwd" means `$PWD` (symlinks resolved) is under `~/Git/work`;
symlinked paths into the work tree count as work cwd.

| Shell mode | parent env CLAUDE_CONFIG_DIR | cwd | Child env | Effective root |
|---|---|---|---|---|
| interactive (`zsh -ic`) | unset | personal | `$HOME/.claude` | `~/.claude` |
| interactive | unset | work | `$HOME/.claude-work` | `~/.claude-work` |
| interactive | set non-empty | any | the set value | the set value |
| interactive | exported empty | personal | `$HOME/.claude` | `~/.claude` |
| interactive | exported empty | work | `$HOME/.claude-work` | `~/.claude-work` |
| interactive, `--personal` | any (incl. custom) | any | `$HOME/.claude` | `~/.claude` |
| `zsh -lc` (login, non-interactive) | each of the above | each | same as interactive | same |
| `zsh -c` (non-login) | each of the above | each | same as interactive | same |
| wrapper defined, helper stripped (snapshot) | unset | personal | `$HOME/.claude` | `~/.claude` |
| wrapper defined, helper stripped | unset | work | `$HOME/.claude-work` | `~/.claude-work` |
| wrapper defined, helper AND `CLAUDE_WORK_*` vars stripped | unset | work | `$HOME/.claude-work` | `~/.claude-work` (literal-default fallbacks) |

Invariants across every cell: the child never sees an empty
`CLAUDE_CONFIG_DIR` (empty parent exports are consumed by the wrapper,
never propagated); the child value is always an absolute path.

Support boundary: routing is guaranteed only for shells using the
default `ZDOTDIR` (i.e. reading `~/.zshenv`). A custom `ZDOTDIR` that
bypasses the link is out of scope; callers in such environments set
`CLAUDE_CONFIG_DIR` explicitly, which the precedence order honors.

## Approaches considered

**A. Guard-only (minimal).** Keep everything in `functions.zsh`; wrap
the helper call in a `typeset -f` guard with a `~/.claude` fallback and
a non-empty floor. Fixes the config-dump failure but leaves `zsh -lc`
with no routing at all: a cold login shell in the work tree still
launches the personal account. Rejected: does not cover failure 1, and
the todo explicitly requires the logic to work in login and
non-interactive shells.

**B. Self-contained wrapper in a `.zshenv`-sourced file
(recommended).** Move the Claude accounts block into a new
`zsh/claude-account.zsh`, sourced from a new tracked `zsh/.zshenv`
(symlinked to `~/.zshenv`). `.zshenv` is the one file zsh reads in all
three modes, so the wrapper and helper exist everywhere zsh runs.
Additionally make `claude()` self-contained: inline the routing (no
helper call) with literal-default fallbacks and a non-empty floor, so
even a partially-restored environment (snapshot case) routes correctly.
Cost: a new install surface (symlink + migration of any existing
machine-local `~/.zshenv`).

**C. `bin/claude` shim script.** Replace the function with a script on
PATH ahead of the real binary. Works for non-zsh callers too, but PATH
itself is unreliable in non-interactive shells (Homebrew and `~/bin`
are added by `.zprofile`/`.zshrc`), adds recursion/ordering fragility,
and changes the interactive UX surface. Rejected as heavier and less
reliable than B for the actual failure modes, which are all zsh.

## Design (approach B)

### 1. New `zsh/claude-account.zsh`

Contains everything currently in the "Claude Code Accounts" section of
`zsh/functions.zsh` (lines ~225-281), reworked:

- `CLAUDE_WORK_CONFIG_DIR` / `CLAUDE_WORK_TREE` keep their current
  values but are set with `:-` defaults so a pre-set value survives.
- `_claude_config_dir` stays as the single resolver used by
  `claude-account` (interactive diagnostic; degradation there is
  acceptable and visible).
- `claude()` becomes self-contained: it inlines the same routing logic
  instead of calling the helper, using literal-default expansions
  (`${CLAUDE_WORK_TREE:-$HOME/Git/work}`,
  `${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}`) so it routes
  correctly even if the surrounding variables were never set. A
  comment states why the duplication with `_claude_config_dir` is
  deliberate (snapshot contexts strip the underscore helper).
- Hard floor before exec: `cfg` is guaranteed non-empty
  (`cfg="${cfg:-$HOME/.claude}"`) and then normalized to an absolute
  symlink-free path (`cfg="${cfg:A}"` -- a relative inherited value
  would otherwise re-anchor the config tree to whatever cwd claude
  sees). Empty exported `CLAUDE_CONFIG_DIR` is treated as unset
  (existing `-n` check already does this; keep it).
- **Always inject**: every branch launches
  `CLAUDE_CONFIG_DIR="$cfg" command claude ...`. The current
  "personal = run unwrapped" branch is removed -- it let an inherited
  empty export leak into the child, which is exactly failure 2's
  mechanism one level down. Injecting `$HOME/.claude` explicitly is
  behavior-identical to the binary default and also makes
  `--personal` genuinely override an inherited custom value
  (precedence constraint above).
- Argument handling: every argv element equal to `--personal` is
  removed (including after `--`, matching today's filter); all other
  argv, stdin/stdout/stderr, and the exit status pass through
  unchanged (`command claude` in the function's tail position, as
  today).
- `claude-account` output format is unchanged.

The block is removed from `zsh/functions.zsh`.

### 2. New tracked `zsh/.zshenv`

Symlinked to `~/.zshenv` by `install/common/link.sh` alongside the
existing `.zshrc`/`.zprofile` links. Contents, in full:

- Source `~/.zshenv.local` if present (machine-local escape hatch,
  replacing today's untracked machine-local `~/.zshenv`).
- Resolve the repo directory through the symlink
  (`${(%):-%N}` + `:A` modifiers, no external commands) and source
  `zsh/claude-account.zsh` from it. Guarded so a broken resolution
  fails silent, never breaking every zsh script on the machine.

Interactive shells also read `.zshenv` (before `.zprofile`/`.zshrc`),
so the accounts block is defined exactly once per shell; no
double-sourcing from `.zshrc` is added.

### 3. Install migration (`install/common/link.sh`)

Migration runs before creating the `~/.zshenv` symlink and must be
idempotent (a second install run is a no-op) and non-destructive (no
existing file content is ever overwritten or deleted). State table:

| Existing `~/.zshenv` | `~/.zshenv.local` exists | Action |
|---|---|---|
| absent | any | link only |
| symlink to repo `zsh/.zshenv` | any | link (no-op re-link) |
| symlink elsewhere | any | print notice naming the old target, then `ln -sf` (the target file itself is untouched and recoverable; the notice preserves the pointer) |
| regular file | no | `mv` to `~/.zshenv.local`, then link |
| regular file | yes | `mv` to `~/.zshenv.dotfiles-bak.<epoch>` (timestamped -- never collides, never overwrites a prior backup), print notice that its content no longer executes and must be merged into `~/.zshenv.local` manually, then link |
| directory or other type | any | print error and skip the link (leave the machine as-is; `symlink-audit.sh` flags it) |

`symlink-audit.sh`
(`.claude/skills/dotfiles-diagnostics-and-tooling/scripts/`) gains the
`~/.zshenv` entry.

### 4. Documentation updates

`CLAUDE.md` and `README.md` currently name `zsh/functions.zsh` as the
wrapper's home; both get the new location and the one-line rationale
(defined via `.zshenv` so routing exists in non-interactive shells).

## Testing

New `zsh/claude-account.test.sh`, registered in `bin/dotfiles-tests`,
following the `zsh/functions.test.sh` harness pattern (sandbox `$HOME`,
stub `claude` first on PATH; the stub records the `CLAUDE_CONFIG_DIR`
it received, distinguishing empty from unset). Behavioral cases, each
run under `zsh -lc`, `zsh -c`, and `zsh -ic` via `ZDOTDIR` pointed at
a sandbox containing the repo's `.zshenv` (the `-ic` run proves the
interactive path goes through the same definitions):

1. Personal cwd, env unset: stub sees `CLAUDE_CONFIG_DIR` set to
   `$HOME/.claude` (always-inject).
2. Work cwd (sandbox `$HOME/Git/work/x`), env unset: stub sees
   `$HOME/.claude-work`.
3. Symlinked work cwd (a dir outside the tree symlinked into
   `$HOME/Git/work`, entered via the symlink): stub sees
   `$HOME/.claude-work`.
4. Env set non-empty: stub sees exactly that value, from both cwds.
5. Env exported empty: treated as unset; stub sees the cwd-routed
   value from both personal and work cwds, never empty.
6. `--personal` from work cwd with a custom non-empty env value: stub
   sees `$HOME/.claude`; `--personal` is absent from the stub's argv
   (also when it appears after `--`); other args and exit status pass
   through.
7. Pre-set `CLAUDE_WORK_CONFIG_DIR`/`CLAUDE_WORK_TREE` in the parent:
   routing honors the overridden values.
8. Snapshot simulation: source `claude-account.zsh`, `unfunction
   _claude_config_dir` and unset the two `CLAUDE_WORK_*` variables,
   run `claude` from a work cwd: stub still sees
   `$HOME/.claude-work` (proves the inline routing and literal
   defaults, not the helper, carry the wrapper).
9. `claude-account` labels: personal/work/custom for the three cfg
   shapes (interactive-path sanity).

Migration cases (same file or `install/install.test.sh`, whichever the
plan finds cleaner -- the migration logic must be extracted into a
sourceable function so it is testable against a sandbox `$HOME`): one
case per row of the migration state table, plus a repeat-run case
asserting idempotence.

Static assertions (same file, grep-based like the existing suite):

- `claude()` body does not invoke `_claude_config_dir` (regression
  guard against reintroducing the dependency).
- `zsh/.zshenv` contains no external command invocations.
- `install/common/link.sh` links `~/.zshenv`.

`zsh/functions.test.sh` keeps its existing cases; nothing it asserts
today touches the moved block.

## Out of scope

- Herdr dispatch scripts on the work machine (private repo) and any
  bash-callable shim: zsh coverage plus the never-empty invariant fixes
  the two observed failures; non-zsh callers keep explicit
  `CLAUDE_CONFIG_DIR`.
- Changing herdr STATE_ROOT derivation.
- Cloud containers: `bootstrap-cloud.sh` does not run `link.sh` and
  cloud sessions do not route accounts; no change.

## Success criteria

- Every cell of the failure matrix resolves as specified, demonstrated
  by the new test suite (`bin/dotfiles-tests` green).
- Reproducing failure 2's shape (wrapper present, helper absent) yields
  a correctly-routed launch, not an error and not an empty env export.
- `zsh -lc 'cd ~/Git/work/... && claude'` routes to `~/.claude-work`
  on a linked machine with no env pre-set.

Compatibility contract (preserved behavior, enumerated):

- Work-tree cwd routes to `~/.claude-work`; elsewhere to `~/.claude`.
- A non-empty inherited `CLAUDE_CONFIG_DIR` wins over cwd routing.
- `--personal` launches the personal account and is not forwarded.
- `claude-account` output format and labels.

Intentional behavior changes (the delta from today, all deliberate):

- The child always receives an explicit non-empty `CLAUDE_CONFIG_DIR`
  (previously unset for personal launches).
- An exported-empty `CLAUDE_CONFIG_DIR` is consumed, not propagated.
- `--personal` now overrides an inherited custom `CLAUDE_CONFIG_DIR`
  (previously the unwrapped branch let the inherited value leak).
- Pre-set `CLAUDE_WORK_CONFIG_DIR`/`CLAUDE_WORK_TREE` values survive
  sourcing (previously clobbered by plain assignment).

## Review notes

Codex spec review (2026-08-31, verdict needs-rework) produced 12
findings; 1-11 are folded in above. Finding 12 (make approach B
non-normative, defer design to planning) is declined: this repo's
pipeline settles the design in the spec (brainstorm output), and the
todo's "exact design TBD by the plan phase" predates that standing
order.
