---
name: dotfiles-run-and-operate
description: Day-to-day operation of an already-installed dotfiles machine. Load when asked to "update the dotfiles", "reload zsh", clean up leftovers from a retired plugin (its uninstall function is the only surviving entry point for both Superpowers and ECC; their install/update entry points are retired and no longer exist), run dotfiles-repair, prep a repo with setup-claude, explain claude account routing (claude-account, the claude() wrapper, work vs personal), find where machine state lives (~/.claude, ~/.claude-work, cache stamps, plugin dirs), or understand .todos/.planning worktree hydration. NOT for first-time environment setup (dotfiles-build-and-env), debugging a broken symptom (dotfiles-debugging-playbook), or Claude Code platform internals (claude-code-platform-reference).
---

# Dotfiles: Run and Operate

Daily-driver runbook for a machine that already has the dotfiles installed:
the update lifecycle, plugin operations, repair, per-repo Claude prep, account
routing, and the map of where state lands on disk. Everything here is
idempotent by design -- `update` re-runs the full installer, so any command in
this file is safe to re-run.

[WARNING] Front-loaded traps:

- `update` propagates `install.sh` failure (fixed 2026-07-02): it captures the
  install status before the final `cd`, prints `[X] update failed: install.sh
exited N`, and returns that status. `$?` is trustworthy again.
- `claude plugins install` can exit 0 without installing (commits 722c653, f91d7d2); this is now historical, since the retired Superpowers install path (the retired ECC's had the same gap) is deleted and no plugin installs in this repo any more.
- Never run the retired ECC's `sync-ecc-to-codex.sh` directly -- it overwrote `core.hooksPath` and wrote through the `~/.codex/AGENTS.md` symlink into the repo. The old sync wrapper and ECC itself are both retired, and the Superpowers install path it used to route diagnostics to is retired too; see repo CLAUDE.md.
- The `claude` desktop app and IDE extensions bypass the `claude()` zsh
  wrapper and always land on `~/.claude` (personal), even under `~/Git/work`.
  The `account_guard.py` SessionStart hook warns inside the session.

## When NOT to use this skill

| You actually want                                               | Use instead                      |
| --------------------------------------------------------------- | -------------------------------- |
| Fresh machine / cloud container / work identity from scratch    | dotfiles-build-and-env           |
| A symptom is broken and you need triage                         | dotfiles-debugging-playbook      |
| How plugins/marketplaces/config dirs work at the platform level | claude-code-platform-reference   |
| Prove a symlink chain / plugin install / hook actually works    | dotfiles-verification-toolkit    |
| Doctor scripts and the test runner                              | dotfiles-diagnostics-and-tooling |
| How to land a change to the dotfiles repo itself                | dotfiles-change-control          |
| Env var and flag catalog                                        | dotfiles-config-and-flags        |

## Command quick reference

All shell functions live in zsh/functions.zsh; aliases in zsh/aliases.zsh;
bin scripts are symlinked into `~/bin` by install/common/link.sh.

| Command                                                             | What it is   | What it does                                                                                                                                                               |
| ------------------------------------------------------------------- | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `update`                                                            | zsh function | `cd $DOTFILEDIR` -> `git pull` -> `tldr --update` -> `bash install/install.sh` -> cd back                                                                                  |
| `reload`                                                            | alias        | `source ~/.zshrc` (aliases.zsh:20)                                                                                                                                         |
| `ecc-uninstall`                                                     | zsh function | Sweep ECC leftovers (plugin, repo clone, metadata, cache stamp); the only surviving ECC-named function -- `ecc-install`/`ecc-update` are retired (2026-09)                 |
| the Superpowers uninstaller (see "Post-merge operator steps" below) | zsh function | Uninstall Superpowers from both config dirs and Codex, scope-aware; the only surviving Superpowers-named function -- its install/update entry points are retired (2026-09) |
| `dotfiles-repair`                                                   | bin script   | Pull, re-link, verify settings.json, flag compromised GSD, verify final state                                                                                              |
| `setup-claude`                                                      | bin script   | Add `CLAUDE.md`, `AGENTS.md`, `.claude/` to the CURRENT repo's `.git/info/exclude`                                                                                         |
| `claude-account`                                                    | zsh function | Print which account a launch from `$PWD` would use                                                                                                                         |
| `claude [--personal]`                                               | zsh wrapper  | Launch Claude Code with directory-based account routing                                                                                                                    |
| `identity-doctor`                                                   | bin script   | Read-only git/ssh identity chain verifier (also `git identity`)                                                                                                            |
| `dotfiles-tests`                                                    | bin script   | Aggregate runner for all nine test suites                                                                                                                                  |

## Update lifecycle

`update` (zsh/functions.zsh:28) is the whole story: it pulls the repo and
re-runs `bash $DOTFILEDIR/install/install.sh`, which re-links everything
(install/common/link.sh), keeps retired plugin copies disabled
(install/common/claude-plugins.sh; Superpowers and ECC are both retired and
no plugin installs here any more), and re-checks the shell. Every step is
idempotent; symlinks are `ln -sf`/`ln -sfn` re-created each run.

```bash
update          # full refresh: repo + links + plugins + CLIs
reload          # re-source ~/.zshrc after config edits (no install)
```

Notes:

- `install.sh` runs `sudo -v` up front -- `update` prompts for a password on a
  normal machine. Expected, not a bug.
- No plugin install can fail inside `update` any more: the retired
  Superpowers install path and the retired ECC install path are both gone, and
  `install/common/claude-plugins.sh` only re-runs the Codex workflow dedupe
  now, keeping retired plugin copies disabled.
- [WARNING] Open item: `update` returns the `cd`'s exit status, so a failed
  `install.sh` does not fail `update`. Read the scrollback.
- `settings.json` is seed-once per config dir (claude-links.sh
  `seed_machine_local_file`). `update` never merges template changes into an
  existing machine's settings.json -- that merge is manual. Cloud containers
  are the exception (bootstrap-cloud.sh reconciles automatically).

## Plugin operations

No plugin is installed by this repo any more. Superpowers (retired 2026-09,
formerly `superpowers@claude-plugins-official`, retired 2026-09) and ECC
(formerly `ecc@ecc`, upstream github.com/affaan-m/ECC, retired 2026-09) are
both fully retired: their install/update entry points are removed, and each
one's uninstall function is the only surviving retired-plugin-named
function, for sweeping leftovers (plugin registration, staged Codex copy or
repo clone, cache stamp; see "Post-merge operator steps" below for the exact
command). ECC's
language-rules vendoring was retired earlier still (2026-07-02) -- any
leftover `claude/rules/` language dirs from an older machine are inert and
should be deleted by hand; only `claude/rules/personal/` is tracked (our
always-on model-tuning layer).

### Post-merge operator steps (retiring a leftover plugin)

After the settings/installer retirement lands, in order, on a machine that
still has a retired plugin installed:

```bash
update --ai            # 1. reconcile settings so the plugin is forced off
reload                  # 2. new shell: `update` runs in a subprocess and
                         #    never redefines the calling shell's functions
superpowers-uninstall   # 3. remove Superpowers from Claude, Codex and disk
```

Then start a fresh session and confirm the retired `superpowers:` skill
prefix lists nothing -- the plugin should be gone entirely.

### Staleness nag and cache stamps (retired)

The per-plugin staleness nag (`_claude_plugin_check_update`, ECC-only) is retired along with ECC itself (2026-09); it is no longer defined in `zsh/functions.zsh` and no interactive shell prints `[INFO] Stale: ecc (Nd). Run 'ecc-update' to refresh.` anymore. Superpowers never had a staleness nag of its own; both its install/update entry points and its plugin state are retired (2026-09) the same way.

| Stamp file (in `${ZSH_CACHE_DIR:-$HOME/.cache/zsh}`) | Written by                   | Removed by      | Content                                                 |
| ---------------------------------------------------- | ---------------------------- | --------------- | ------------------------------------------------------- |
| `.ecc-update`                                        | (retired; no writer remains) | `ecc-uninstall` | leftover `LAST_ECC_EPOCH=<days>` stamp, if present      |
| `.gsd-update`                                        | (legacy)                     | `gsd-uninstall` | retired; the nag loop that used to skip it is also gone |

A separate 24h-cached check (`_claude_code_update_check`, functions.zsh:787)
compares the Claude Code CLI version against npm and prints:
`[INFO] Claude Code update available: X -> Y. Run 'claude update' to upgrade.`
Cache: `${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/claude-code-update-check`.

## Repair: `dotfiles-repair`

Run when a long-lived machine drifts: dangling symlinks after a moved/deleted
dotfiles clone, a truncated `~/.claude/settings.json` (something wrote through
a stale symlink), or suspicion that the compromised GSD package reappeared.
Safe to re-run; skips destructive ops when state is already correct.

```bash
dotfiles-repair
```

Five steps (bin/dotfiles-repair): 1) `git pull --ff-only` on main if clean, 2) re-run the platform `link.sh`, 3) size-check `~/.claude/settings.json`
against the template (warns, never auto-overwrites an existing file), 4) flag `get-shit-done-cc` if present (`[WARNING] Compromised GSD detected --
run 'gsd-uninstall' to fully remove it` -- the original package was
rug-pulled; treat as hostile, never reinstall), 5) verify `~/.gitconfig` and a
codex hook symlink resolve. Healthy run ends:

```
dotfiles-repair complete.
Restart Claude Code / Codex sessions to pick up reloaded plugins and hooks.
```

Repair does NOT touch `~/.claude-work/settings.json` (step 3 checks only
`~/.claude`) and does not run any plugin install -- no plugin install path
remains in this repo (the retired Superpowers and ECC entry points are both
gone); follow with `update` if the reconciled settings are the problem.

## Per-repo prep: `setup-claude`

In any OTHER git repo where you want local Claude files kept out of version
control:

```bash
cd ~/Git/personal/some-repo && setup-claude
```

Appends `CLAUDE.md`, `AGENTS.md`, `.claude/` to that repo's
`.git/info/exclude` (idempotent), then prints `Added to .git/info/exclude` and
suggests `/init` (no CLAUDE.md yet) or `/refresh` (exists). It requires a
`.git` DIRECTORY at cwd -- in a linked worktree (`.git` is a file) it exits
`Not a git repository`; run it from the main checkout instead.

## Account routing in practice

Two Claude accounts, two config dirs, one asset source (see
claude-code-platform-reference for mechanics):

| Launch context                                                                                             | Config dir used                                                           |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `claude` (wrapper) anywhere outside `~/Git/work`                                                           | `~/.claude` (personal)                                                    |
| `claude` (wrapper) under `~/Git/work` (symlinks resolved)                                                  | `~/.claude-work` (work)                                                   |
| `claude` (wrapper) in a linked worktree of a repo under `~/Git/work` (herdr, EnterWorktree, `.worktrees/`) | `~/.claude-work` (work)                                                   |
| `claude --personal` from a work dir                                                                        | `~/.claude`                                                               |
| Pre-set `CLAUDE_CONFIG_DIR`                                                                                | applies except in known personal repositories or under personal overrides |
| Desktop app / IDE extension / `command claude` / scripts / cron                                            | `~/.claude` regardless of directory                                       |

```bash
claude-account        # prints: work (~/.claude-work) | personal (~/.claude) | custom (<dir>)
claude --personal     # force personal from inside ~/Git/work
```

Herd dispatch binds the selected account and runtime environment to the actual
pane. Its server-spawned shell does not inherit the controller's environment.
Native personal Claude unsets `CLAUDE_CONFIG_DIR`; work/custom namespaces stay
explicit. Personal quota remains allowed in work repositories.

The bypass row is the daily trap. `claude/hooks/account_guard.py`
(SessionStart, registered in claude/settings.json.tmpl) fires in EVERY session
and warns when personal repository context could reach a work account or the
selected scope is unverified. Deliberate personal quota in a work repository
is allowed. If you see that warning: relaunch via the wrapper, and
avoid logins/plugin installs/billing-sensitive work until on the right
account. `~/.claude-work` is created on first work-side launch (fresh OAuth
login). Cloud containers are personal-account only -- there is no
`~/.claude-work` story in cloud (open).

## Where state lands (map)

"Tracked" = a symlink into the repo (edit in the repo, commit). "Machine-local"
= a real file the repo only seeds; never expect `update` to change it.

| Path                                                                                             | Kind                        | Owner / notes                                                                                                  |
| ------------------------------------------------------------------------------------------------ | --------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `~/.zshrc`, `~/.zprofile`, `~/.config/.{aliases,functions}.zsh`                                  | symlink -> `zsh/`           | tracked                                                                                                        |
| `~/.gitconfig`, `~/.gitconfig-personal`                                                          | symlink -> `git/`           | tracked                                                                                                        |
| `~/.gitconfig-work`                                                                              | machine-local               | seeded from `git/work/.gitconfig-work.tmpl`; `identity-setup` fills it                                         |
| `~/.config/git/hooks`                                                                            | dir symlink -> `git/hooks/` | `core.hooksPath` target; commit-msg, pre-commit, pre-push, post-checkout                                       |
| `~/.ssh/config*`, `~/.ssh/id_ed25519_personal.pub`                                               | symlink -> `ssh/`           | tracked; `~/.ssh/config_local` + work key are machine-local                                                    |
| `~/.config/1Password/ssh/agent.toml`                                                             | machine-local               | seeded once from `ssh/configs/agent.toml`                                                                      |
| `~/.claude/{CLAUDE.md,commands,agents,hooks,rules,skills,operating-principles.md,statusline.js}` | symlinks -> `claude/`       | tracked (rules/skills dirs hold untracked installer content too)                                               |
| `~/.claude-work/*`                                                                               | same symlinks               | second account, same asset source                                                                              |
| `~/.claude*/settings.json`                                                                       | machine-local               | seeded once from `claude/settings.json.tmpl`; plugin installers write into it; template changes = manual merge |
| `~/.claude/plugins/installed_plugins.json`                                                       | machine-local               | GROUND TRUTH of installed plugins                                                                              |
| `~/.claude/plugins/marketplaces/`                                                                | machine-local               | marketplace clone (claude-plugins-official; the retired ECC's `ecc` marketplace clone is gone)                 |
| `~/.codex/{AGENTS.md,hooks/*.py,skills/<repo skills>}`                                           | symlinks -> `codex/`        | tracked; `~/.codex/config.toml` is machine-local (link.sh edits it additively)                                 |
| `~/bin/{dotfiles-repair,setup-claude,identity-setup,identity-doctor,dotfiles-tests}`             | symlinks -> `bin/`          | tracked                                                                                                        |
| `${ZSH_CACHE_DIR:-~/.cache/zsh}/.ecc-update`                                                     | machine-local               | leftover plugin staleness stamp from the retired ECC nag; no longer written                                    |
| `~/.cache/dotfiles/claude-code-update-check`                                                     | machine-local               | CLI version-check cache                                                                                        |
| `~/Git/personal/ECC`                                                                             | machine-local clone         | retired ECC vendor source; `ecc-uninstall` sweeps it; never commit here                                        |

## Worktree hydration in daily work

The global `post-checkout` hook (git/hooks/post-checkout, via
`core.hooksPath`) fires in EVERY repo on branch checkout. In practice: when
you `git worktree add`, it hydrates the untracked cross-session state into the
new worktree so the `todos` skill and planning records keep working.

- `.todos/` -> whole-directory symlink to the main worktree's `.todos/`
  (single project-wide backlog, no per-branch state). Expected line:
  `[post-checkout] hydrated .todos -> <main>/.todos`
- `.planning/` (legacy GSD repos only): `codebase/ quick/ todos/ ROADMAP.md
TODO.md` symlinked to main; `STATE.md config.json` copied per-worktree.
  Ends with `[post-checkout] hydrated .planning/ from <main>`.
- Wrong-shape destinations are never clobbered silently: you get
  `[post-checkout] WARN: ... rerun with GSD_HOOK_REPAIR=1 to repair`.
  `GSD_HOOK_REPAIR=1 git checkout <branch>` opts into the destructive replace
  (rsync unique content back to main FIRST). Workspace-mode worktrees
  (`.planning/config.json` `"mode": "workspace"`) are skipped entirely;
  `GSD_HOOK_ISOLATE=1` converts leftover symlinks to copies there.
- Daily consequence: todos you add in a worktree land in main's `.todos/`
  immediately -- `rm -rf <worktree>` loses nothing. Moving the main checkout
  on disk breaks every worktree's symlinks (absolute paths); repair with
  `GSD_HOOK_REPAIR=1` per worktree.

## Open items (do not claim these are fixed)

- `update` swallows `install.sh` failure (returns the `cd` status).
- Machine-path plugin installers trust `claude plugins list` grep, not
  `installed_plugins.json`; `bootstrap-cloud.sh` `ensure_plugin` is the gold
  standard not yet ported.
- `settings.json.tmpl` changes need manual merge on existing machines.
- The old Codex sync and its BSD-only cleanup are retired; native plugin
  staging is the supported lifecycle.
- `dotfiles-repair` checks only `~/.claude/settings.json`, not the work dir's.
- ECC rules vendoring necessity is CLOSED: ECC is fully retired (2026-09), the question is moot.

## Provenance and maintenance

Facts verified against the repo on 2026-07-02 (commits that day: 5b799dd
the retired Superpowers install path's marketplace pre-registration fix,
465ee17 bin/dotfiles-tests + todos root-guard, 52f807d block_secrets segment
matching, 26eae6d README/skills catalog). Line numbers cited from
zsh/functions.zsh and zsh/aliases.zsh drift easily -- prefer the
function-name anchors.

Re-verify before trusting:

```bash
grep -n 'function update()' ~/dotfiles/zsh/functions.zsh              # update steps
grep -n "alias reload" ~/dotfiles/zsh/aliases.zsh                     # reload
grep -n 'ECC_REPO_DIR' ~/dotfiles/zsh/functions.zsh                   # retired ECC repo path (ecc-uninstall sweep target)
! grep -q '_claude_plugin_check_update' ~/dotfiles/zsh/functions.zsh  # confirms the retired 14-day nag is gone
grep -n 'step "' ~/dotfiles/bin/dotfiles-repair                       # repair step list
sed -n '18,22p' ~/dotfiles/bin/setup-claude                           # excluded patterns
grep -n 'CLAUDE_WORK_TREE=' ~/dotfiles/zsh/functions.zsh              # routing boundary dir
grep -n 'ln -sf' ~/dotfiles/install/common/link.sh                    # state map symlinks
git -C ~/dotfiles log --oneline -5                                    # has anything moved since 2026-07-02?
```

(Substitute your dotfiles checkout path for `~/dotfiles` if it differs; inside
a shell, `$DOTFILEDIR` is set by .zprofile.)
