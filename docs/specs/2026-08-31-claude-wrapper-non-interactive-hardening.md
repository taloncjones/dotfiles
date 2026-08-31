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
   whole dispatch.
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
  (`claude/hooks/herdr_orch_core.py:156`). Routing must therefore be
  deterministic across shell modes on the same machine.
- Interactive behavior is frozen: `~/Git/work` cwd routes to
  `~/.claude-work`; a pre-set non-empty `CLAUDE_CONFIG_DIR` always
  wins; `claude --personal` forces `~/.claude`; `claude-account`
  reports the routing. Symlinked paths into the work tree still route
  to work (`:A` resolution on both sides).
- `.zshenv` runs for every zsh on the system, including scripts: any
  code added there must be tiny, dependency-free, and silent.

## Target behavior (failure matrix)

Cells are the config dir the launched `claude` process must see.
"work cwd" means `$PWD` (symlinks resolved) is under `~/Git/work`.

| Shell mode | env CLAUDE_CONFIG_DIR | cwd | Result |
|---|---|---|---|
| interactive | unset | personal | `~/.claude` (unset in child; binary defaults) |
| interactive | unset | work | `~/.claude-work` |
| interactive | set non-empty | any | the set value, unchanged |
| interactive | exported empty | any | treated as unset: route by cwd, never empty |
| interactive, `--personal` | any | work | `~/.claude` |
| `zsh -lc` (login, non-interactive) | unset | personal | `~/.claude` |
| `zsh -lc` | unset | work | `~/.claude-work` |
| `zsh -lc` | set non-empty | any | the set value |
| `zsh -c` (non-login) | all of the above | all | same as `zsh -lc` |
| wrapper defined, helper stripped (snapshot) | unset | personal | `~/.claude` |
| wrapper defined, helper stripped | unset | work | `~/.claude-work` |
| wrapper defined, helper AND vars stripped | unset | work | `~/.claude-work` (literal-default fallbacks) |

Invariant across every cell: the wrapper never execs `claude` with
`CLAUDE_CONFIG_DIR` set to an empty value.

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
  (`cfg="${cfg:-$HOME/.claude}"`). Empty exported
  `CLAUDE_CONFIG_DIR` is treated as unset (existing `-n` check already
  does this; keep it).
- Unchanged: `--personal` filtering and forwarding, the
  "personal = run unwrapped" branch (`command claude` with no env
  injection when cfg is `$HOME/.claude`), `claude-account` output
  format.

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

Before creating the `~/.zshenv` symlink: if `~/.zshenv` exists and is a
regular file (not a symlink), move it to `~/.zshenv.local` (do not
overwrite an existing `~/.zshenv.local`; in that case move the old file
to `~/.zshenv.dotfiles-bak` and print a notice -- loud, not silent).
Existing symlinks are simply replaced by `ln -sf`, matching the other
zsh links.

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
run under both `zsh -lc` and `zsh -c` via `ZDOTDIR` pointed at a
sandbox containing the repo's `.zshenv`:

1. Personal cwd, env unset: stub sees unset/`~/.claude` default
   (wrapper runs the unwrapped branch).
2. Work cwd (sandbox `$HOME/Git/work/x`), env unset: stub sees
   `$HOME/.claude-work`.
3. Env set non-empty: stub sees exactly that value, from both cwds.
4. Env exported empty: treated as unset; stub never sees empty.
5. `--personal` from work cwd: stub sees no injected work dir; flag is
   not forwarded to the stub's argv.
6. Snapshot simulation: source `claude-account.zsh`, `unfunction
   _claude_config_dir` and unset the two `CLAUDE_WORK_*` variables,
   run `claude` from a work cwd: stub still sees
   `$HOME/.claude-work` (proves the inline routing and literal
   defaults, not the helper, carry the wrapper).
7. `claude-account` labels: personal/work/custom for the three cfg
   shapes (interactive-path sanity).

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
- Interactive routing, `--personal`, pre-set env override, and
  `claude-account` output are byte-identical in behavior to today.
