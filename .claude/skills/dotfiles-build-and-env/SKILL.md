---
name: dotfiles-build-and-env
description: Recreate any dotfiles environment from nothing -- fresh macOS, fresh Linux, claude.ai/code cloud container, or the work-identity add-on -- as numbered copy-paste runbooks with expected output at each checkpoint, plus the twelve known install traps. Load when the user says "set up a new machine", "fresh install", "bootstrap", "new laptop", "cloud container setup", "install from scratch", "add work identity", or when bootstrap.sh / bootstrap-cloud.sh / identity-setup fails mid-run. NOT for day-to-day update/plugin operations on an already-installed machine (dotfiles-run-and-operate), diagnosing a broken existing install (dotfiles-debugging-playbook), or proving a link/plugin/identity claim (dotfiles-verification-toolkit).
---

# Build and Environment Runbooks

Four from-zero runbooks for the dotfiles repo (github.com/taloncjones/dotfiles):
fresh macOS, fresh Linux, cloud container, and the work-identity add-on. Each is
numbered copy-paste steps with expected output at checkpoints. A "trap" here is
a known way the install fails or silently degrades; all twelve are cataloged at
the end with source citations. Everything below was verified against the repo
on 2026-07-02.

[WARNING] Front-loaded, before you start:

- The installer is idempotent by design -- `update` (a zsh function) re-runs
  `install/install.sh` on every invocation. Never add a non-idempotent step.
- `install/install.sh` runs under `set -euo pipefail` and asks for sudo up
  front. Run it in an interactive terminal: `chsh` (Trap 8) and macOS
  `defaults`/PlistBuddy steps (Trap 11) can prompt or abort.
- Plugin installs need a logged-in `claude` CLI. On a truly fresh machine they
  WARN and skip (`install/common/claude-plugins.sh`); re-run `ecc-install` and
  `superpowers-install` after `claude` login. This is expected, not a failure.
- Never copy the 1Password signing block from `git/personal/.gitconfig-personal`
  into a container or Linux box -- `op-ssh-sign` is macOS-only (Trap 9).
- Never run ECC's `sync-ecc-to-codex.sh` directly; only via the `codex-ecc-sync`
  wrapper (see repo CLAUDE.md, "Codex plugin integration").

Jargon used below, defined once:

| Term           | Meaning                                                                                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| config dir     | A Claude Code state directory. Two exist: `~/.claude` (personal account) and `~/.claude-work` (work account). Both symlink shared assets from `claude/` in this repo.                        |
| seed-once      | Copy a template to a machine-local file only if the destination is absent (`seed_machine_local_file` in `install/common/claude-links.sh`). Later template changes do NOT propagate (Trap 2). |
| marketplace    | A Claude Code plugin source repo. This setup uses `ecc` (github.com/affaan-m/ECC) and `claude-plugins-official`.                                                                             |
| vendored rules | ECC language rule files copied into `claude/rules/` by `ecc-sync-rules`; untracked per `claude/rules/.gitignore`, reproducible from the ECC repo.                                            |

## Runbook 1: fresh macOS

1. Install Xcode Command Line Tools (provides `git`):

   ```bash
   xcode-select --install
   ```

   Checkpoint: a GUI dialog appears; click Install and wait. `git --version`
   then works.

2. Clone over HTTPS (no SSH keys exist yet) to the personal convention dir --
   the path matters: git identity (`includeIf gitdir/i:~/Git/personal/` in
   `git/.gitconfig`) and Claude account routing both key off `~/Git/personal`
   and `~/Git/work`:

   ```bash
   git clone https://github.com/taloncjones/dotfiles.git ~/Git/personal/dotfiles
   ```

   No remote rewrite needed later: `url.insteadOf`/`pushInsteadOf` in the
   identity includes route `github.com` remotes to the pinned SSH aliases once
   1Password is set up (README.md, "Quick Start").

3. Run bootstrap (interactive terminal; enter your password once for sudo):

   ```bash
   cd ~/Git/personal/dotfiles
   ./bootstrap.sh
   ```

   What runs, in order (`install/install.sh`): Homebrew + both Brewfiles + VS
   Code extensions + Xcode CLI (`install/macos/macos.sh`) -> oh-my-zsh +
   plugins -> symlinks (`install/macos/link.sh` -> `install/common/link.sh`)
   -> macOS defaults (`install/macos/defaults.sh`) -> Claude CLI
   (`install/common/claude-code.sh`) -> Codex CLI (`install/common/codex.sh`)
   -> ECC + Superpowers plugins (`install/common/claude-plugins.sh`) ->
   Homebrew zsh as login shell (`install/common/zsh.sh`).

   Checkpoint: green `Install complete!` banner. A red `Warning: Some Homebrew
packages failed to install.` means re-run `brew bundle` manually -- the rest
   of the install still completed (`BREW_FAILED` is non-fatal by design).
   `[claude-plugins] WARNING: ... skipping` is expected pre-login (see
   warnings above).

4. Log into Claude, then install plugins if step 3 skipped them:

   ```bash
   claude   # complete OAuth login, then exit
   zsh -ic 'ecc-install && superpowers-install'
   ```

   Checkpoint: `[OK] ECC installed` and `[OK] Superpowers installed
(~/.claude)` lines. Prove it on disk (exit codes lie -- see Trap 4):

   ```bash
   grep -o 'ecc@ecc\|superpowers@claude-plugins-official' ~/.claude/plugins/installed_plugins.json
   ```

5. Set up identities (work identity is optional; see Runbook 4):

   ```bash
   identity-setup
   ```

6. Verify the machine:

   ```bash
   identity-doctor
   dotfiles-tests
   ```

   Checkpoint: `identity-doctor: all checks passed.` (exit 0; `[WARNING]`
   lines are informational, `[X]` lines fail) and
   `=== dotfiles-tests: 9 suites passed, 0 failed`.

7. Log out and back in (or `exec zsh`) to pick up the Homebrew zsh login shell.

## Runbook 2: fresh Linux

Debian/Ubuntu-family only -- the installer uses `apt` and `dpkg-query`
(`install/install.sh`, Linux Step 0).

1. Ensure git and clone, same convention path as macOS:

   ```bash
   sudo apt update && sudo apt install -y git
   git clone https://github.com/taloncjones/dotfiles.git ~/Git/personal/dotfiles
   ```

2. Run bootstrap:

   ```bash
   cd ~/Git/personal/dotfiles
   ./bootstrap.sh
   ```

   Linux path differences vs macOS: apt deps first (`curl build-essential
xclip xdg-utils`), then Linuxbrew (`install/linux/linux.sh`) with only the
   common Brewfile (`install/common/Brewfile.rb` -- no casks, no VS Code
   extensions), `install/linux/link.sh` adds no platform links beyond the
   common set, and there is no defaults step.

   Checkpoint: same `Install complete!` banner as macOS.

3. Same post-steps as macOS Runbook steps 4-7 (claude login, plugins,
   identity-setup, identity-doctor, dotfiles-tests).

[WARNING] Known Linux degradations (all open, none fixed as of 2026-07-02):

| Issue                                          | Effect                                                                                                                               | Trap # |
| --- | --- | --- |
| `ripgrep` only in `install/macos/Brewfile.rb`  | commit-msg guard silently skips attribution/emoji checks                                                                             | 12     |
| `op-ssh-sign` path is macOS-only               | commits under `~/Git/personal` fail at signing until you `git config --global commit.gpgsign false` or install an alternative signer | 9      |
| Hardcoded `/home/linuxbrew/.linuxbrew/bin/zsh` | wrong shell path if Homebrew landed in `~/.linuxbrew`                                                                                | 7      |
| BSD-only `sed -i ''` in `codex-ecc-sync`       | the post-sync gitconfig cleanup errors on GNU sed                                                                                    | 10     |
| 1Password agent socket check is a macOS path   | `identity-doctor` warns about the agent socket even when SSH works                                                                   | --     |

## Runbook 3: cloud container (claude.ai/code)

Containers are ephemeral and personal-account only (no `~/.claude-work` story
in cloud -- open limitation). Two mechanisms restore the Claude layer; both are
first-session-safe:

| Mechanism                                                             | When it runs                                 | What it does                                                                                                                                                                        |
| --- | --- | --- |
| `.claude/settings.json` (committed, this repo)                        | Pre-launch, platform-native                  | Declares `enabledPlugins` (ecc@ecc, superpowers@claude-plugins-official) and pins both marketplaces by git URL in `extraKnownMarketplaces`. PRIMARY: plugins are live on session 1. |
| `.claude/hooks/session-start.sh` (SessionStart hook, matcher `startup\|resume`, gated on `CLAUDE_CODE_REMOTE=true`) | Post-launch | Runs `bootstrap-cloud.sh`: links assets into `~/.claude`, reattributes git identity, installs/verifies plugins, reconciles `settings.json` from the template. SELF-HEAL only -- a plugin it installs is not usable until the NEXT session (plugins load at CLI launch). |

1. Working on the dotfiles repo itself in a cloud session: do nothing. Both
   mechanisms fire automatically. Verify:

   ```bash
   grep -c 'ecc@ecc\|superpowers@claude-plugins-official' ~/.claude/plugins/installed_plugins.json
   readlink ~/.claude/CLAUDE.md
   git config --global user.email
   ```

   Checkpoint: count >= 2; readlink points into the dotfiles checkout; email
   is the personal identity, NOT `noreply@anthropic.com`.

2. Optional belt-and-suspenders for any cloud environment (e.g. a repo that
   does not commit the plugin declaration, or to pre-snapshot the install):
   paste into the environment's Setup script field (pre-launch,
   filesystem-snapshotted; repo is public, no GitHub grant needed):

   ```bash
   git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || git -C "$HOME/dotfiles" pull
   "$HOME/dotfiles/bootstrap-cloud.sh"
   ```

   Checkpoint: `[bootstrap-cloud] OK: installed <id>` per plugin, then
   `[bootstrap-cloud] Done.` A `!! FAILED` line names the exact recovery
   command. Retries are backoff-capped at 15s so the worst case stays under
   the Setup script's ~5-minute budget (`PLUGIN_RETRY_MAX_DELAY` in
   `bootstrap-cloud.sh`).

3. What `bootstrap-cloud.sh` deliberately does, beyond linking:
   - Reattributes git author from the platform default
     (`Claude <noreply@anthropic.com>`) to the tracked personal identity, and
     sets `commit.gpgsign false` (no 1Password in a container). A real
     identity already present is left alone (`reattribute_git_identity`).
   - Verifies each plugin against `~/.claude/plugins/installed_plugins.json`
     -- never the install exit code, which can be 0 on a no-op
     (`ensure_plugin`, `plugin_installed`).
   - Reconciles `~/.claude/settings.json` from `claude/settings.json.tmpl`
     LAST, unioning the plugin-installer keys so nothing is lost
     (`reconcile_claude_settings`). Cloud gets this automatically; machines do
     NOT (Trap 2).

4. What it deliberately SKIPS (header comment, `bootstrap-cloud.sh`): brew,
   zsh, ssh, codex, macOS defaults, and `~/.claude-work`. Do not expect
   aliases, the prompt theme, or work-account routing in a container.
   `--no-plugins` skips plugin installs (used by the smoke test; useful
   offline).

## Runbook 4: work identity add-on

Personal identity is tracked in the repo; everything employer-specific is
machine-local. Precondition: `bootstrap.sh` has run (it seeds
`~/.gitconfig-work` from `git/work/.gitconfig-work.tmpl`; `identity-setup`
self-seeds if not).

1. Create or import a work SSH key in 1Password (separate work vault
   recommended) and enable it for the SSH agent in
   `~/.config/1Password/ssh/agent.toml` (machine-local, seeded from
   `ssh/configs/agent.toml`).

2. Run the wizard (re-runnable; empty input keeps current values):

   ```bash
   identity-setup
   ```

   It refuses to write unless both work email and a plausible OpenSSH public
   key (`ssh-*`/`ecdsa-*`/`sk-*` prefix) are given, then finishes by running
   `identity-doctor`.

3. What lands where (all machine-local, never tracked):

   | File                         | Content                                                                                         | Written by                    |
   | ---------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------- |
   | `~/.gitconfig-work`          | work `user.name`/`user.email`/`user.signingkey` (+ template's `url.insteadOf` Git-work routing) | wizard (seeded from template) |
   | `~/.ssh/id_ed25519_work.pub` | work key public half; pins the `Git-work` ssh alias                                             | wizard                        |
   | `~/.ssh/config_local`        | machine-local SSH hosts stub (created only if absent)                                           | wizard                        |

4. Add the work public key to the work GitHub account (auth + signing), clone
   work repos under `~/Git/work`, and verify:

   ```bash
   identity-doctor        # or: git identity
   ```

   Checkpoint: `[OK] ~/.gitconfig-work sets work identity (<email>)` and
   `[OK] Git-work pins the work key`. Until this runs, git refuses to commit
   under `~/Git/work` (`user.useConfigOnly=true`) -- that loud failure is the
   design, not a bug.

5. Claude work account: the `claude()` wrapper in `zsh/functions.zsh` routes
   launches under `~/Git/work` to `CLAUDE_CONFIG_DIR=~/.claude-work`
   (`_claude_config_dir`); the first such launch prompts the work OAuth login.
   `claude-account` prints the routing; `claude --personal` overrides.

## Known traps (all twelve, verified 2026-07-02)

| #   | Trap                                         | Ground truth                                                                                                                                                                                                                      | Consequence / recovery                                                                                                                                                                                                                                           |
| --- | --- | --- | --- |
| 1   | Ordering: apps before symlinks               | macOS install runs Homebrew/casks (Step 1) before `link.sh` (Step 3) "after apps create their directories" (`install/install.sh:63-64`)                                                                                           | Reordering breaks VS Code settings links into `~/Library/Application Support/Code/User/`. Keep the order.                                                                                                                                                        |
| 2   | Seed-once settings template                  | `seed_machine_local_file` copies `claude/settings.json.tmpl` only when the destination file is absent (`install/common/claude-links.sh`)                                                                                          | Template changes never reach existing machines -- merge into `~/.claude/settings.json` and `~/.claude-work/settings.json` by hand. Cloud auto-reconciles (`reconcile_claude_settings`); machines do not. OPEN.                                                   |
| 3   | Real-dir backup migration                    | `link_claude_config_dir` moves any REAL (non-symlink) `commands/agents/hooks/interview/rules/skills` dir to `<name>.bak.<timestamp>` before symlinking (`install/common/claude-links.sh`)                                         | Content from a pre-dotfiles Claude setup is preserved in the `.bak.*` dirs, not deleted -- check there before assuming loss.                                                                                                                                     |
| 4 | Plugin verify still trusts CLI output | Marketplace no-op fixed by 5b799dd (`superpowers-install` registers the official marketplace by git URL first), but the machine path still greps `claude plugins list` output and trusts install exit codes (`superpowers-install`, `ecc-install` in `zsh/functions.zsh`) | An install can exit 0 without installing. Gold standard is `ensure_plugin` in `bootstrap-cloud.sh` (checks `installed_plugins.json`). After any machine install, grep `~/.claude/plugins/installed_plugins.json` yourself. OPEN. |
| 5 | `~/.claude-work` skipped when absent | Plugin functions iterate both config dirs and `continue` past any dir that does not exist (the `[[ -d ... ]]` guard in `zsh/functions.zsh`) | If the work dir does not exist when the installer runs (e.g. plugin functions run before `link.sh`, or the dir was removed), plugins land only in `~/.claude`. Re-run `ecc-install`/`superpowers-install` after it exists. A full `bootstrap.sh` creates both dirs first (`link_claude_config_dir` does `mkdir -p`). |
| 6   | ECC dirty-pull vs reset divergence           | `ecc-install` uses `git pull origin main`; `ecc-update` uses `git fetch` + `git reset --hard origin/main` because `codex-ecc-sync`'s `npm install` rewrites tracked lockfiles every run (`zsh/functions.zsh`, ecc-update comment) | `ecc-install` on an existing dirty ECC clone fails with `[X] git pull failed`. Recovery: run `ecc-update` instead (its hard reset is safe -- the ECC clone at `~/Git/personal/ECC` is a read-only vendored mirror, never committed to).                          |
| 7   | Hardcoded Linuxbrew path                     | `install/common/zsh.sh:19` sets `ZSHBREWSHELL="/home/linuxbrew/.linuxbrew/bin/zsh"` unconditionally on Linux                                                                                                                      | Wrong if Homebrew installed to `~/.linuxbrew` (no sudo installs). Symptom: zsh missing from `/etc/shells` or `chsh` to a nonexistent path. OPEN.                                                                                                                 |
| 8   | `chsh` password prompt                       | `install/common/zsh.sh:33` runs `chsh -s "$ZSHBREWSHELL"` with no non-interactive guard                                                                                                                                           | Unattended runs stall waiting for a password near the end of bootstrap. Run bootstrap in an interactive terminal, or pre-set the shell.                                                                                                                          |
| 9   | `op-ssh-sign` is macOS-only                  | `git/personal/.gitconfig-personal` sets `gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign` with `commit.gpgsign = true`                                                                                   | On Linux, commits under `~/Git/personal` fail at signing. Containers are handled (`bootstrap-cloud.sh` sets `commit.gpgsign false`); plain Linux machines are not. Workaround: `git config --global commit.gpgsign false`. OPEN.                                 |
| 10  | BSD-only `sed -i ''`                         | `codex-ecc-sync` restores the tilde `hooksPath` with `sed -i '' -E ...` (`zsh/functions.zsh:358`)                                                                                                                                 | GNU sed treats `''` as a filename and errors; the gitconfig cleanup step fails on Linux. macOS-only function in practice. OPEN.                                                                                                                                  |
| 11  | PlistBuddy `Set` without `Add` fallback      | `install/macos/defaults.sh:51-53` uses `PlistBuddy -c "Set :...arrangeBy grid"`; `install.sh` sources it under `set -euo pipefail`                                                                                                | On an account where Finder has not yet created those plist keys, `Set` fails and can abort bootstrap at the defaults step (inferred from set -e; not reproduced). Recovery: re-run `./bootstrap.sh` after opening Finder once, or comment the three lines. OPEN. |
| 12  | Missing `rg` silently disables commit checks | `git/hooks/commit-msg:15-18` exits 0 with a stderr note when `rg` is absent (fails open, does NOT block); `ripgrep` is only in `install/macos/Brewfile.rb:14`, not the common Brewfile                                            | Linux machines pass commits with zero attribution/emoji checking and only a one-line stderr warning. Fix: `brew install ripgrep` (or move it to the common Brewfile). OPEN.                                                                                      |

## When NOT to use this skill

| You want                                                                          | Use instead                    |
| --------------------------------------------------------------------------------- | ------------------------------ |
| `update` lifecycle, plugin update/repair, account routing on an installed machine | dotfiles-run-and-operate       |
| A symptom-to-triage table for a broken install                                    | dotfiles-debugging-playbook    |
| To prove a symlink chain / plugin install / identity resolution first-principles  | dotfiles-verification-toolkit  |
| Claude Code platform mechanics (config dirs, marketplaces, hook types) in depth   | claude-code-platform-reference |
| Every env var and flag with defaults and consumers                                | dotfiles-config-and-flags      |
| Test-suite inventory and how to add a test                                        | dotfiles-validation-and-qa     |
| The history behind why cloud bootstrap works this way                             | dotfiles-failure-archaeology   |
| Making cloud sessions first-class (forward-looking campaign)                      | dotfiles-cloud-first-campaign  |

## Provenance and maintenance

Everything above verified against the working tree on 2026-07-02 (HEAD
26eae6d). Volatile facts and their one-line re-checks:

| Fact                                           | Re-verify with                                                                                                                                                                                    |
| --- | --- |
| Install flow and step order                    | `sed -n '40,140p' install/install.sh`                                                                                                                                                             |
| Plugin ids and marketplace URLs                | `cat .claude/settings.json`                                                                                                                                                                       |
| Superpowers marketplace fix landed             | `git show 5b799dd --stat`                                                                                                                                                                         |
| Test-suite count (9 as of 2026-07-02) | `bin/dotfiles-tests --list` (expect 9 lines) |
| Seed-once behavior                             | `grep -n 'seed_machine_local_file' -A 12 install/common/claude-links.sh`                                                                                                                          |
| ECC vendored languages                         | `grep -n 'ECC_VENDOR_LANGS' zsh/functions.zsh`                                                                                                                                                    |
| Cloud retry cap                                | `grep -n 'PLUGIN_RETRY_MAX_DELAY' bootstrap-cloud.sh`                                                                                                                                             |
| Trap line numbers (7, 8, 10, 11, 12) | `grep -n linuxbrew/bin/zsh install/common/zsh.sh; grep -n chsh install/common/zsh.sh; grep -n "sed -i ''" zsh/functions.zsh; grep -n PlistBuddy install/macos/defaults.sh; grep -n 'command -v rg' git/hooks/commit-msg` |
| ripgrep still macOS-only                       | `grep -rn ripgrep install/*/Brewfile.rb install/common/Brewfile.rb`                                                                                                                               |
| Open traps (2, 4, 7, 9, 10, 11, 12) still open | re-run the greps above; if a fix landed, update the OPEN labels                                                                                                                                   |

Upstream URLs that may move: `https://claude.ai/install.sh`
(`install/common/claude-code.sh`), `https://chatgpt.com/codex/install.sh`
(`install/common/codex.sh`), `https://github.com/affaan-m/ECC.git`,
`https://github.com/anthropics/claude-plugins-official.git` (both pinned in
`.claude/settings.json` and `bootstrap-cloud.sh`).
