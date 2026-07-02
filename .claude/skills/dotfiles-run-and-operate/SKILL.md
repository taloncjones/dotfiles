---
name: dotfiles-run-and-operate
description: Day-to-day operation of an already-installed dotfiles machine. Load when asked to "update the dotfiles", "reload zsh", run/repair a plugin (ecc-install, ecc-update, superpowers-install), run dotfiles-repair, prep a repo with setup-claude, explain claude account routing (claude-account, the claude() wrapper, work vs personal), find where machine state lives (~/.claude, ~/.claude-work, cache stamps, plugin dirs), or understand .todos/.planning worktree hydration. NOT for first-time environment setup (dotfiles-build-and-env), debugging a broken symptom (dotfiles-debugging-playbook), or Claude Code platform internals (claude-code-platform-reference).
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
- `claude plugins install` can exit 0 without installing (commits 722c653,
  f91d7d2). Machine-path installers (`ecc-install`/`superpowers-install`) grep
  CLI output, not the ground truth. Verify against
  `~/.claude/plugins/installed_plugins.json` when it matters.
- Never run ECC's `sync-ecc-to-codex.sh` directly -- it overwrites
  `core.hooksPath` and writes through the `~/.codex/AGENTS.md` symlink into
  the repo. The `codex-ecc-sync` wrapper (zsh/functions.zsh) is the only safe
  entry; `ecc-install`/`ecc-update` already call it.
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

| Command                 | What it is   | What it does                                                                                                           |
| ----------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `update`                | zsh function | `cd $DOTFILEDIR` -> `git pull` -> `tldr --update` -> `bash install/install.sh` -> cd back                              |
| `reload`                | alias        | `source ~/.zshrc` (aliases.zsh:20)                                                                                     |
| `ecc-install`           | zsh function | Clone/pull ECC repo, vendor rules, add marketplace + install plugin in BOTH config dirs, codex sync, write cache stamp |
| `ecc-update`            | zsh function | Hard-reset ECC repo to origin/main, re-vendor rules, codex sync, refresh stamp                                         |
| `ecc-sync-rules`        | zsh function | Re-vendor `ECC_VENDOR_LANGS` from `~/Git/personal/ECC/rules` into `claude/rules/` as a reviewable diff                 |
| `ecc-uninstall`         | zsh function | Remove plugin (both dirs), repo, metadata, cache stamp; vendored rules stay                                            |
| `superpowers-install`   | zsh function | Register official marketplace by git URL if absent, install plugin in BOTH config dirs                                 |
| `superpowers-update`    | zsh function | `claude plugins update` in each dir that has it                                                                        |
| `superpowers-uninstall` | zsh function | Uninstall from both config dirs                                                                                        |
| `codex-ecc-sync`        | zsh function | SAFE wrapper around ECC's codex sync (redirects hooks dir, restores hooksPath)                                         |
| `dotfiles-repair`       | bin script   | Pull, re-link, verify settings.json, flag compromised GSD, verify final state                                          |
| `setup-claude`          | bin script   | Add `CLAUDE.md`, `AGENTS.md`, `.claude/` to the CURRENT repo's `.git/info/exclude`                                     |
| `claude-account`        | zsh function | Print which account a launch from `$PWD` would use                                                                     |
| `claude [--personal]`   | zsh wrapper  | Launch Claude Code with directory-based account routing                                                                |
| `identity-doctor`       | bin script   | Read-only git/ssh identity chain verifier (also `git identity`)                                                        |
| `dotfiles-tests`        | bin script   | Aggregate runner for all nine test suites                                                                              |

## Update lifecycle

`update` (zsh/functions.zsh:28) is the whole story: it pulls the repo and
re-runs `bash $DOTFILEDIR/install/install.sh`, which re-links everything
(install/common/link.sh), reinstalls/refreshes ECC + Superpowers in both
config dirs (install/common/claude-plugins.sh), and re-checks the shell. Every
step is idempotent; symlinks are `ln -sf`/`ln -sfn` re-created each run.

```bash
update          # full refresh: repo + links + plugins + CLIs
reload          # re-source ~/.zshrc after config edits (no install)
```

Notes:

- `install.sh` runs `sudo -v` up front -- `update` prompts for a password on a
  normal machine. Expected, not a bug.
- Plugin install failures inside `update` WARN but never abort
  (install/common/claude-plugins.sh:41): offline or logged-out `claude` is
  tolerated. Expected line on that path:
  `[claude-plugins] WARNING: ECC/Superpowers install reported an error (offline, or claude not logged in?).`
- [WARNING] Open item: `update` returns the `cd`'s exit status, so a failed
  `install.sh` does not fail `update`. Read the scrollback.
- `settings.json` is seed-once per config dir (claude-links.sh
  `seed_machine_local_file`). `update` never merges template changes into an
  existing machine's settings.json -- that merge is manual. Cloud containers
  are the exception (bootstrap-cloud.sh reconciles automatically).

## Plugin operations

Two plugins, both global-only, both maintained in BOTH config dirs
(`~/.claude` and `~/.claude-work`; a dir that does not exist is skipped):

### ECC (`ecc@ecc`, upstream github.com/affaan-m/ECC)

ECC = "Everything Claude Code": skills/agents/commands/hooks come from the
plugin; language RULES are vendored separately into the dotfiles repo.

```bash
ecc-install     # from scratch: repo clone -> rules vendor -> marketplace+plugin (both dirs) -> codex sync
ecc-update      # refresh: fetch+reset ECC repo to origin/main -> re-vendor -> codex sync
ecc-sync-rules  # rules only; prints the review command
ecc-uninstall   # plugin+repo+stamp gone; claude/rules/ vendored content left intact
```

Expected output lines (quoted from zsh/functions.zsh):

```
[OK] Vendored (common python cpp rust web typescript) from ECC @ <shorthash>
[INFO] Review and commit: git -C "$DOTFILEDIR" diff -- claude/rules
[INFO] ECC plugin already installed (/Users/you/.claude)
[OK] ECC installed
[OK] ECC rules updated
```

Facts that matter:

- ECC source repo lives at `~/Git/personal/ECC` (`ECC_REPO_DIR`). It is a
  read-only vendored mirror: `ecc-update` does `git fetch` + `git reset --hard
origin/main` on it deliberately (lockfiles get dirtied by npm; rebase-pull
  would abort). Never commit there.
- Vendored langs: `ECC_VENDOR_LANGS=(common python cpp rust web typescript)`
  (zsh/functions.zsh:297). The vendored dirs under `claude/rules/` are
  UNTRACKED (claude/rules/.gitignore); only `claude/rules/personal/` is
  tracked. A rules diff after `ecc-sync-rules` therefore only shows if you
  changed the gitignore or personal/. Whether vendoring is still needed at all
  is an open question (cloud containers get the full tree via the plugin
  marketplace clone) -- see dotfiles-architecture-contract.
- `--local` is accepted but ignored with
  `[WARNING] ECC's Claude rules/plugin are global-only; ignoring --local.`

### Superpowers (`superpowers@claude-plugins-official`)

Plugin-only: no repo, no rules, no extra files.

```bash
superpowers-install    # registers the official marketplace by git URL first if absent
superpowers-update     # then: "[OK] Superpowers updated (restart Claude Code to apply)"
superpowers-uninstall
```

The marketplace pre-registration (added 2026-07-02, commit 5b799dd) exists
because `claude plugins install` silently no-ops (exit 0) when the official
marketplace is absent or mid-fetch. Expected first-install lines:

```
[INFO] Adding official plugin marketplace (/Users/you/.claude)...
[INFO] Installing Superpowers plugin (/Users/you/.claude)...
[OK] Superpowers installed (/Users/you/.claude)
```

### Staleness nag and cache stamps

`_claude_plugin_check_update` (zsh/functions.zsh:752) runs at every
interactive shell start (tty only). It reads day-granularity epoch stamps and
nags after 14 days:

```
[INFO] Stale: ecc (15d). Run 'ecc-update' to refresh.
```

| Stamp file (in `${ZSH_CACHE_DIR:-$HOME/.cache/zsh}`) | Written by                   | Removed by      | Content                                      |
| ---------------------------------------------------- | ---------------------------- | --------------- | -------------------------------------------- |
| `.ecc-update`                                        | `ecc-install` / `ecc-update` | `ecc-uninstall` | `LAST_ECC_EPOCH=<days>`                      |
| `.gsd-update`                                        | (legacy)                     | `gsd-uninstall` | retired; the nag loop deliberately skips gsd |

Only `ecc` is in the nag loop -- Superpowers writes no stamp and is never
nagged; it is refreshed by `update` (via claude-plugins.sh) instead. No stamp
file means no nag, so an uninstalled plugin stays silent.

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
`~/.claude`) and does not run plugin installs -- follow with `update` or
`ecc-install`/`superpowers-install` if plugins are the problem.

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

| Launch context                                                  | Config dir used                     |
| --------------------------------------------------------------- | ----------------------------------- |
| `claude` (wrapper) anywhere outside `~/Git/work`                | `~/.claude` (personal)              |
| `claude` (wrapper) under `~/Git/work` (symlinks resolved)       | `~/.claude-work` (work)             |
| `claude --personal` from a work dir                             | `~/.claude`                         |
| Pre-set `CLAUDE_CONFIG_DIR`                                     | always wins                         |
| Desktop app / IDE extension / `command claude` / scripts / cron | `~/.claude` regardless of directory |

```bash
claude-account        # prints: work (~/.claude-work) | personal (~/.claude) | custom (<dir>)
claude --personal     # force personal from inside ~/Git/work
```

The bypass row is the daily trap. `claude/hooks/account_guard.py`
(SessionStart, registered in claude/settings.json.tmpl) fires in EVERY session
and injects a `[WARNING] account_guard: ...` context message when account and
directory disagree (and an `[INFO]` breadcrumb for a deliberate custom
`CLAUDE_CONFIG_DIR`). If you see that warning: relaunch via the wrapper, and
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
| `~/.claude/plugins/marketplaces/`                                                                | machine-local               | marketplace clones (ecc, claude-plugins-official)                                                              |
| `~/.codex/{AGENTS.md,hooks/*.py,skills/<repo skills>}`                                           | symlinks -> `codex/`        | tracked; `~/.codex/config.toml` is machine-local (link.sh edits it additively)                                 |
| `~/bin/{dotfiles-repair,setup-claude,identity-setup,identity-doctor,dotfiles-tests}`             | symlinks -> `bin/`          | tracked                                                                                                        |
| `${ZSH_CACHE_DIR:-~/.cache/zsh}/.ecc-update`                                                     | machine-local               | plugin staleness stamp                                                                                         |
| `~/.cache/dotfiles/claude-code-update-check`                                                     | machine-local               | CLI version-check cache                                                                                        |
| `~/Git/personal/ECC`                                                                             | machine-local clone         | ECC vendor source; hard-reset by `ecc-update`; never commit here                                               |

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
- `codex-ecc-sync` uses `sed -i ''` (functions.zsh:358) -- BSD/macOS-only; it
  errors on GNU sed (Linux).
- `dotfiles-repair` checks only `~/.claude/settings.json`, not the work dir's.
- ECC rules vendoring necessity is an open question.

## Provenance and maintenance

Facts verified against the repo on 2026-07-02 (commits that day: 5b799dd
superpowers marketplace pre-registration, 465ee17 bin/dotfiles-tests + todos
root-guard, 52f807d block_secrets segment matching, 26eae6d README/skills
catalog). Line numbers cited from zsh/functions.zsh and zsh/aliases.zsh drift
easily -- prefer the function-name anchors.

Re-verify before trusting:

```bash
grep -n 'function update()' ~/dotfiles/zsh/functions.zsh              # update steps
grep -n "alias reload" ~/dotfiles/zsh/aliases.zsh                     # reload
grep -n 'ECC_VENDOR_LANGS\|ECC_REPO_DIR' ~/dotfiles/zsh/functions.zsh # vendor langs + repo path
grep -n 'update_days' ~/dotfiles/zsh/functions.zsh                    # 14-day nag threshold
grep -n 'for plugin in' ~/dotfiles/zsh/functions.zsh                  # which plugins get nagged
grep -n 'step "' ~/dotfiles/bin/dotfiles-repair                       # repair step list
sed -n '18,22p' ~/dotfiles/bin/setup-claude                           # excluded patterns
grep -n 'CLAUDE_WORK_TREE=' ~/dotfiles/zsh/functions.zsh              # routing boundary dir
grep -n 'ln -sf' ~/dotfiles/install/common/link.sh                    # state map symlinks
git -C ~/dotfiles log --oneline -5                                    # has anything moved since 2026-07-02?
```

(Substitute your dotfiles checkout path for `~/dotfiles` if it differs; inside
a shell, `$DOTFILEDIR` is set by .zprofile.)
