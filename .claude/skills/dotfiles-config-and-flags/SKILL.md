---
name: dotfiles-config-and-flags
description: Catalog of every environment variable, script flag, and config knob in this dotfiles repo -- consumer, default, effect, and whether it is production, test-only, or emergency-bypass. Load when asking "what does VAR do", "is there a flag for X", "how do I skip a hook", "what reads CLAUDE_CONFIG_DIR / CLAUDE_CODE_REMOTE / ECC_VENDOR_LANGS / GSD_HOOK_REPAIR", "why is --local ignored", "what keys does settings.json.tmpl own", or before adding a new flag. NOT for diagnosing breakage (dotfiles-debugging-playbook), running the update/plugin lifecycle (dotfiles-run-and-operate), platform semantics of the vars Claude Code itself defines (claude-code-platform-reference), or recreating a machine (dotfiles-build-and-env).
---

# Dotfiles Config and Flags

Every configuration axis in this repo, as tables: environment variables the
repo's own code consumes, flags accepted by its scripts and functions, and
edit-in-file knobs. Each entry names the consumer (file + function), the
default, the effect, and its class -- production, test-only, internal, or
emergency-bypass. Verified against the working tree on 2026-07-02.

[WARNING] The bypass variables (`DOTFILES_SKIP_COMMIT_MSG_GUARD`,
`ECC_SKIP_GIT_HOOKS`, `ECC_SKIP_PRECOMMIT`, `ECC_SKIP_PREPUSH`) exist for
emergencies (a hook itself is broken, or you are committing the fix to a hook
that blocks its own diff). They are not a normal-workflow tool: routing around
the guard hooks to land content they would block violates the repo's change
gates. State in the commit/PR why a bypass was used.

[WARNING] Several ALL-CAPS names that look like env vars are NOT overridable
from the environment: `zsh/functions.zsh` assigns them unconditionally at
source time (plain `VAR=value`, no `${VAR:=...}`), so an exported value is
clobbered when the shell starts. They are edit-in-file knobs. Marked
"edit-in-file" below.

## When NOT to use this skill

| You actually want                                                           | Use instead                      |
| --------------------------------------------------------------------------- | -------------------------------- |
| Something is broken and you need triage                                     | `dotfiles-debugging-playbook`    |
| Day-to-day update/plugin/repair operations                                  | `dotfiles-run-and-operate`       |
| How Claude Code itself treats config dirs, plugins, hooks, cloud containers | `claude-code-platform-reference` |
| Fresh-machine or cloud-container setup                                      | `dotfiles-build-and-env`         |
| Why a design decision exists (two config dirs, seed-once settings)          | `dotfiles-architecture-contract` |
| Prove a var actually took effect (symlink/plugin/identity/hook checks)      | `dotfiles-verification-toolkit`  |

## Definitions

- _Config dir_: a Claude Code state directory (`~/.claude` personal,
  `~/.claude-work` work), selected by `CLAUDE_CONFIG_DIR`.
- _Guard hook_: a Python script in `claude/hooks/` registered in
  `claude/settings.json.tmpl`; exit 2 blocks the tool call.
- _Git hook_: a script in `git/hooks/`, active via
  `core.hooksPath=~/.config/git/hooks`.
- _ECC_: the "Everything Claude Code" plugin (`ecc@ecc`, from
  github.com/affaan-m/ECC). _GSD_: "Get Shit Done", retired npm tool; only the
  community redux fork is sanctioned.
- _Edit-in-file_: change by editing the assignment in the repo and reloading,
  not by exporting.

## Environment variables -- production runtime

| Var                      | Consumer                                                                                                                                                                                                                                                 | Default                                   | Effect                                                                                                                                                                                                                                                                                                                                                                                                             | Class                 |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------- |
| `DOTFILEDIR`             | Everything: `zsh/aliases.zsh`, `zsh/functions.zsh`, all `install/` scripts, `bootstrap-cloud.sh`                                                                                                                                                         | Computed                                  | Absolute path to this repo. Set three independent ways: interactive shells by the symlink-resolving block in `zsh/.zshrc` (`DOTFILEDIR="$(dirname "$ZSHDIR")"`, exported, then `$DOTFILEDIR/bin` goes on PATH); install scripts by sourcing `install/common/resolve_dotfiledir.sh`; `bootstrap-cloud.sh` computes its own at the top. Do not hand-set; a wrong value silently retargets every symlink and function | production (derived)  |
| `CLAUDE_CONFIG_DIR`      | `_claude_config_dir()` + `claude()` wrapper in `zsh/functions.zsh`; `claude/hooks/account_guard.py`; `claude/statusline.js` (`process.env.CLAUDE_CONFIG_DIR`); `bin/identity-doctor`; set per-invocation by all `ecc-*`/`superpowers-*` plugin functions | unset (Claude Code then uses `~/.claude`) | Claude Code's native account-isolation var. A pre-set value ALWAYS wins over directory-based routing -- `identity-doctor` warns when it is exported in your shell. The plugin functions set it per-command to target each config dir explicitly                                                                                                                                                                    | production            |
| `CLAUDE_WORK_CONFIG_DIR` | Assigned `$HOME/.claude-work` in `zsh/functions.zsh` (edit-in-file for zsh); read from env with the same default by `account_guard.py`                                                                                                                   | `~/.claude-work`                          | Which config dir the work account lives in. The zsh assignment is unconditional, so exporting it does not change the wrapper -- only the Python hook honors an env override                                                                                                                                                                                                                                        | production            |
| `CLAUDE_WORK_TREE`       | Assigned `$HOME/Git/work` in `zsh/functions.zsh` (edit-in-file for zsh); read from env with the same default by `account_guard.py` and `bin/identity-doctor`                                                                                             | `~/Git/work`                              | Directory subtree that routes `claude` launches to the work account (symlinks resolved on both sides via zsh `:A`)                                                                                                                                                                                                                                                                                                 | production            |
| `ZSH_CACHE_DIR`          | `_claude_plugin_epoch_write()`, `_claude_plugin_check_update()`, `ecc-uninstall`, `gsd-uninstall` in `zsh/functions.zsh`                                                                                                                                 | fallback `~/.cache/zsh`                   | Where the `.ecc-update` / `.gsd-update` staleness stamps live (the 14-day "Stale: ecc" shell nag). Set by oh-my-zsh, not by this repo; every repo consumer supplies the fallback                                                                                                                                                                                                                                   | production (external) |
| `XDG_CACHE_HOME`         | `_claude_code_update_check()` in `zsh/functions.zsh`                                                                                                                                                                                                     | fallback `~/.cache`                       | Base for the 24h-cached Claude Code CLI update check (`$XDG_CACHE_HOME/dotfiles/claude-code-update-check`)                                                                                                                                                                                                                                                                                                         | production (external) |
| `JIRA_URL`               | Referenced in `claude/CLAUDE.md` PR/plan templates; cached by `claude/hooks/cache_jira_url.py` from Atlassian MCP results                                                                                                                                | unset                                     | Jira base URL for PR links and plan headers. The hook derives it from MCP traffic; not a var you export                                                                                                                                                                                                                                                                                                            | production (derived)  |
| `ZSH_CUSTOM`             | `install/install.sh` (oh-my-zsh plugin clones)                                                                                                                                                                                                           | fallback `~/.oh-my-zsh/custom`            | Where `zsh-autosuggestions` / `zsh-syntax-highlighting` get cloned during install. Set by oh-my-zsh, not by this repo; the installer supplies the fallback                                                                                                                                                                                                                                                         | production (external) |

## Environment variables -- platform-provided (cloud containers)

Set by the claude.ai/code platform, never by you. Full platform semantics:
`claude-code-platform-reference`.

| Var                  | Consumer                                                                                                                        | Value                                              | Effect                                                                                                                                              | Class      |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `CLAUDE_CODE_REMOTE` | `.claude/hooks/session-start.sh` (`!= "true"` -> exit 0)                                                                        | `true` in cloud containers, unset on real machines | Gates the SessionStart self-heal: only in a cloud container does the hook run `bootstrap-cloud.sh`. On a real machine the hook is a no-op BY DESIGN | production |
| `CLAUDE_PROJECT_DIR` | `.claude/hooks/session-start.sh` (repo root, with a `BASH_SOURCE` fallback); the hook command string in `.claude/settings.json` | repo checkout root                                 | Lets the committed hook registration find the repo without hardcoded paths                                                                          | production |

## Environment variables -- git hook behavior and bypass

All consumed by scripts in `git/hooks/` (active via
`core.hooksPath=~/.config/git/hooks -> $DOTFILEDIR/git/hooks`).

| Var                              | Consumer                                                              | Default | Effect                                                                                                                                                           | Class                    |
| -------------------------------- | --------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `DOTFILES_SKIP_COMMIT_MSG_GUARD` | `git/hooks/commit-msg` (first check)                                  | `0`     | `=1` skips the attribution/emoji commit-message guard for one commit: `DOTFILES_SKIP_COMMIT_MSG_GUARD=1 git commit ...`                                          | emergency-bypass         |
| `ECC_SKIP_GIT_HOOKS`             | `git/hooks/pre-commit` AND `git/hooks/pre-push` (first check in each) | `0`     | `=1` skips BOTH ECC-vendored hooks (secret scan pre-commit, verification pre-push)                                                                               | emergency-bypass         |
| `ECC_SKIP_PRECOMMIT`             | `git/hooks/pre-commit`                                                | `0`     | `=1` skips only pre-commit                                                                                                                                       | emergency-bypass         |
| `ECC_SKIP_PREPUSH`               | `git/hooks/pre-push`                                                  | `0`     | `=1` skips only pre-push                                                                                                                                         | emergency-bypass         |
| `GSD_HOOK_REPAIR`                | `git/hooks/post-checkout`                                             | `0`     | `=1` = maintenance mode: replaces wrong-shape `.todos` / `.planning/*` entries in a worktree with the canonical symlinks to main. Without it the hook only WARNs | production (maintenance) |
| `GSD_HOOK_ISOLATE`               | `git/hooks/post-checkout`                                             | `0`     | `=1` = workspace mode: converts leftover maintenance symlinks (writes would leak to main) into per-worktree copies seeded from main                              | production (maintenance) |
| `ECC_PREPUSH_AUDIT`              | `git/hooks/pre-push`                                                  | `0`     | `=1` adds a dependency audit (`npm audit --omit=dev` or equivalent for the detected package manager) to the pre-push verification flow                           | production (opt-in)      |

File-based gates (no env var): a `.ecc-hooks-disable` or
`.git/ecc-hooks-disable` file in a repo disables pre-commit and pre-push for
that repo entirely. Same bypass caveat as above. Both hooks self-skip when the
repo is not a work tree. The `rg`-absence self-skip (with a printed notice)
exists ONLY in `git/hooks/commit-msg`; `pre-push` never invokes `rg`, and
[WARNING] `pre-commit`'s secret scan silently finds NOTHING when `rg` is
missing (the `rg` call sits inside an if-condition with stderr discarded) --
silent degradation, not a documented skip.

## Environment variables -- plugin, vendoring, and tool knobs

| Var                                         | Consumer                                                                                                                 | Default                                   | Effect                                                                                                                                                                                                                                                                                                                                                                     | Class      |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `ECC_REPO_URL`                              | `ecc-install` in `zsh/functions.zsh`; also an independent copy in `bootstrap-cloud.sh`                                   | `https://github.com/affaan-m/ECC.git`     | Upstream ECC repo registered as the `ecc` plugin marketplace; the local clone now serves only `codex-ecc-sync` (rules vendoring retired 2026-07-02). Edit-in-file (both places; keep in sync)                                                                                                                                                                                                                                       | production |
| `ECC_REPO_DIR`                              | `codex-ecc-sync`, `ecc-install/update/uninstall` in `zsh/functions.zsh`                                                  | `~/Git/personal/ECC`                      | Local clone of upstream ECC -- a read-only vendored mirror (`ecc-update` hard-resets it to `origin/main`). Edit-in-file                                                                                                                                                                                                                                                    | production |
| `ECC_GLOBAL_HOOKS_DIR`                      | Upstream ECC `scripts/sync-ecc-to-codex.sh`; set to `$HOME/.config/git/hooks` by `codex-ecc-sync` in `zsh/functions.zsh` | unset upstream                            | Redirects ECC's git-hook installer into the dotfiles-owned hooks dir so `core.hooksPath` stays dotfiles-managed. [WARNING] Never run `sync-ecc-to-codex.sh` directly without this -- it overwrites `core.hooksPath` and writes through the `~/.codex/AGENTS.md` symlink into this repo (see CLAUDE.md "Codex plugin integration"). Always use the `codex-ecc-sync` wrapper | production |
| `GSD_REDUX_PKG`                             | `_gsd_run()` in `zsh/functions.zsh`                                                                                      | `@opengsd/get-shit-done-redux@latest`     | The ONLY sanctioned GSD package (community fork). The original `get-shit-done-cc` is compromised (token rug-pull, commit `9ad4dc8` retirement); `gsd-uninstall` purges it. Edit-in-file                                                                                                                                                                                    | production |
| `PLUGIN_RETRIES` / `PLUGIN_RETRY_MAX_DELAY` | `ensure_plugin()` in `bootstrap-cloud.sh`                                                                                | `8` / `15` (seconds)                      | Retry budget for cloud plugin installs. The cap is load-bearing: uncapped doubling could blow the Setup script's ~5-minute limit (commit `da54e17`). Edit-in-file constants, not env                                                                                                                                                                                       | production |

## Environment variables -- test-only

Used to make test suites deterministic. Never set in production.

| Var              | Consumer                                                    | Default                     | Effect                                                                                           |
| ---------------- | ----------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------ |
| `TODOS_TODAY`    | `today()` in `claude/skills/todos/scripts/todos.sh`         | `$(date +%Y-%m-%d)`         | Pins "today" for date-relative todo logic; used by `todos_test.sh`                               |
| `TODOS_REGISTRY` | `registry_file()` in `claude/skills/todos/scripts/todos.sh` | `~/.claude/todos/repos.txt` | Repo-registry file location; tests point it at a temp file                                       |
| `WS_GH_CAP`      | `ws_gather_github()` in `claude/skills/lib/work-state.sh`   | `200`                       | Per-query `gh pr list --limit`; results at the cap set `truncated:true`. Tests set `WS_GH_CAP=1` |
| `GH`             | `claude/skills/lib/work-state.sh` (`: "${GH:=gh}"`)         | `gh`                        | Path to the gh binary; tests substitute a stub                                                   |

## Environment variables -- internal (do not set)

| Var                    | Where                                                                                                                                   | Effect                                                                                          |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `BREW_FAILED`          | Set/exported in `install/macos/macos.sh` and `install/linux/linux.sh` when `brew bundle` fails; read at the end of `install/install.sh` | Defers the "some brew packages failed" warning to the end of the install instead of aborting it |
| `NO_PLUGINS`           | Internal to `bootstrap-cloud.sh` arg parsing                                                                                            | Backing variable for `--no-plugins`; use the flag                                               |
| `LAZYGIT_NEW_DIR_FILE` | Exported by `lg()` in `zsh/functions.zsh`                                                                                               | Handshake file lazygit writes its exit directory to so `lg` can `cd` after it quits             |

## Environment variables -- machine-local device file

`zsh/scripts/airpods.zsh` and `zsh/scripts/raycast/bt.sh` source
`~/.config/dotfiles/devices.zsh` (machine-local, never committed) for:

| Var           | Effect                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------- |
| `AIRPODS_MAC` | Bluetooth MAC for the AirPods connect/disconnect helpers (`blueutil --paired` to find it) |
| `MOUSE_MAC`   | Bluetooth MAC for the mouse toggle in the Raycast script                                  |

Missing file -> the scripts print an `[INFO]` pointing here; nothing breaks.

## Script and function flags

| Command                                                                                                  | Flags                                                                | Notes                                                                                                                                                                                                                    |
| -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bootstrap-cloud.sh`                                                                                     | `--no-plugins`                                                       | Skip plugin installs (used by the smoke test; useful offline). Any other arg exits 2                                                                                                                                     |
| `bin/dotfiles-tests`                                                                                     | `--list`                                                             | Print the suites without running. No other flags                                                                                                                                                                    |
| `claude()` wrapper (`zsh/functions.zsh`)                                                                 | `--personal`                                                         | Force the personal config dir from inside `~/Git/work`; stripped, NOT forwarded to the CLI. All other args forwarded verbatim                                                                                            |
| `ecc-install`, `ecc-update`, `superpowers-install`, `superpowers-update`                                 | `-l/--local`, `-g/--global`                                          | Parsed by `_claude_plugin_scope()`; `--local` is ACCEPTED BUT IGNORED with a `[WARNING]` -- see below. `--global` is the default and a no-op                                                                             |
| `gsd-install`, `gsd-update`, `gsd-uninstall`                                                             | `-l/--local`, `-g/--global`, `--claude`, `--codex`, plus passthrough | Parsed by `_gsd_parse_args()`. Default: global scope, both runtimes when the `codex` CLI exists (else Claude only). Unrecognized args are forwarded verbatim to the redux installer (e.g. `--profile=core`, `--minimal`) |
| `claude-telegram`                                                                                        | (forwards all)                                                       | Prepends `--channels plugin:telegram@claude-plugins-official`                                                                                                                                                            |
| `bootstrap.sh`, `install/install.sh`, `bin/identity-doctor`, `bin/identity-setup`, `bin/dotfiles-repair` | none                                                                 | No argument parsing; run bare                                                                                                                                                                                            |

**Why Claude plugins ignore `--local`:** Claude Code plugins install into a
config dir (`claude plugins install` under a `CLAUDE_CONFIG_DIR`), which is
per-ACCOUNT state -- there is no per-project plugin install for these
functions to target. The `-l/--local` spelling exists in the shared parser
because GSD genuinely supports it (its installer writes `./.claude` /
`./.codex` in the current directory). `ecc-*` and `superpowers-*` accept the
flag for muscle-memory compatibility, print
`[WARNING] ... global-only; ignoring --local.`, and proceed globally --
into BOTH config dirs (`~/.claude` and, if it exists, `~/.claude-work`).

## Config knobs (edit-in-file)

### ECC rules vendoring -- RETIRED (2026-07-02)

`ECC_VENDOR_LANGS` and `ecc-sync-rules` no longer exist. The upstream rules
tree ships in the marketplace clone
(`~/.claude/plugins/marketplaces/ecc/rules/`); point on-demand consumers (e.g.
`RULES_DISTILL_DIR`) there. Language dirs left under `claude/rules/` are inert
leftovers -- `ecc-install`/`ecc-update` print the removal command.

### settings.json key ownership

Two different settings files; do not conflate them:

| File                                     | Role                                                                                                                                                  | Owner of keys                                                                                                                                                                                 |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claude/settings.json.tmpl`              | Template seeded ONCE to `~/.claude/settings.json` and `~/.claude-work/settings.json` on first install; machine copies are then machine-local          | Dotfiles owns `env`, `permissions`, `hooks`, `statusLine`. Plugin installers write `enabledPlugins` and `extraKnownMarketplaces` into the MACHINE copies (never edit those two by hand there) |
| `.claude/settings.json` (repo-committed) | Cloud pre-launch declaration: `enabledPlugins` (ecc, superpowers), `extraKnownMarketplaces` pinned by git URL, and the SessionStart hook registration | Dotfiles owns all of it; it is the primary cloud plugin mechanism                                                                                                                             |

Template `env` block sets two knobs for every session:
`CLAUDE_CODE_DISABLE_TELEMETRY=1` (Claude Code CLI) and
`ECC_CONTEXT_MONITOR_COST_WARNINGS=0` (ECC plugin).

[WARNING] Open weak point: template changes do NOT propagate to existing
machines (seed-once). Cloud reconciles automatically
(`reconcile_claude_settings` in `bootstrap-cloud.sh`, plugin keys unioned,
template authoritative for the rest); machines require a manual merge into
each `~/.claude*/settings.json`. `claude/hooks/claude-hooks.test.sh`
drift-checks both machine copies.

### Statusline

`statusLine` in `claude/settings.json.tmpl` runs
`node ~/.claude/statusline.js`. The script reads `CLAUDE_CONFIG_DIR` (falls
back to `~/.claude`) so the work account renders its own state. No statusline
= usually `node` missing (`bootstrap-cloud.sh` warns about exactly this).

## How to add a flag or env var (checklist)

- [ ] Name it: `DOTFILES_*` for repo-wide behavior, tool prefix (`ECC_*`,
      `GSD_*`, `TODOS_*`, `WS_*`) for a subsystem. ALL_CAPS, underscores.
- [ ] One consumer reads it with an explicit default:
      `"${MY_VAR:-default}"` -- never bare `$MY_VAR` under `set -u`.
- [ ] Decide the class: production, test-only, or bypass. A bypass flag must
      default to OFF and print nothing when unset.
- [ ] If it must be env-overridable from zsh, use `: "${VAR:=default}"`
      (see `GH` in `claude/skills/lib/work-state.sh`), NOT a plain
      assignment in `functions.zsh` (which clobbers exports -- see warning
      at top).
- [ ] Document the flag in the consumer's header comment (house pattern:
      `bootstrap-cloud.sh` "Flags:" block, `post-checkout` header).
- [ ] Test it: extend the matching suite (`bin/dotfiles-tests --list` for the
      inventory; `todos_test.sh` and `test_work_state.sh` show the env-injection
      pattern; `post-checkout.test.sh` shows the grep-the-gate pattern).
- [ ] Add a row to THIS skill and to `dotfiles-validation-and-qa` if a new
      suite appeared.
- [ ] Run `bin/dotfiles-tests` before committing.

## Provenance and maintenance

All facts verified against the working tree on 2026-07-02 (baseline: all nine
test suites passing; `bin/dotfiles-tests` and CI added same day, commit
`465ee17`; `superpowers-install` marketplace-by-URL fix commit `5b799dd`).
Line numbers avoided above in favor of function/file anchors because they
drift. Re-verify before trusting:

Run everything below from the repo checkout root ($DOTFILEDIR in interactive
shells; if unset, substitute your checkout path -- canonical machine path
`~/Git/personal/dotfiles`, cloud containers use the platform checkout):

```bash
# Whole-catalog sweep: ALL-CAPS tokens consumed by repo scripts. NO extension
# filter -- the git hooks (git/hooks/{commit-msg,pre-commit,pre-push,post-checkout})
# and the bin/ scripts are extensionless and would be silently skipped by
# --include='*.sh'-style filters.
grep -rn -oE '\$\{?[A-Z][A-Z0-9_]{2,}\}?' \
  . --exclude-dir=.git --exclude-dir=node_modules \
  | grep -oE '[A-Z][A-Z0-9_]{2,}' | sort -u
# Interpretation: hits with the documented prefixes (DOTFILES_, CLAUDE_, ECC_,
# GSD_, TODOS_, WS_, PLUGIN_) that are absent from this file mean the catalog
# has drifted. Other hits are mostly single-script internal locals (BAD, CFG,
# OUT, ...) and are EXPECTED to be absent; investigate only ones you do not
# recognize.

# Per-var consumer check (substitute any var name)
grep -rn 'CLAUDE_CODE_REMOTE' . --exclude-dir=.git

# Bypass gates still where documented
grep -n 'DOTFILES_SKIP_COMMIT_MSG_GUARD' git/hooks/commit-msg
grep -n 'ECC_SKIP' git/hooks/pre-commit git/hooks/pre-push
grep -n 'GSD_HOOK_REPAIR\|GSD_HOOK_ISOLATE' git/hooks/post-checkout
grep -n 'ECC_PREPUSH_AUDIT' git/hooks/pre-push

# Flags still as documented
grep -n 'no-plugins' bootstrap-cloud.sh
grep -n -- '--list' bin/dotfiles-tests
grep -n '_claude_plugin_scope\|_gsd_parse_args' zsh/functions.zsh

# Edit-in-file knob values
grep -n 'ECC_REPO_URL=\|ECC_REPO_DIR=\|GSD_REDUX_PKG=' zsh/functions.zsh
grep -n 'PLUGIN_RETRIES=\|PLUGIN_RETRY_MAX_DELAY=' bootstrap-cloud.sh

# settings ownership + statusline
grep -n '"env"\|statusLine\|enabledPlugins' claude/settings.json.tmpl .claude/settings.json
```

Volatile facts most likely to drift: the plugin retry constants, the template
`env` keys, and the test-suite count (`bin/dotfiles-tests --list`). Upstream
URLs pinned as of today:
`https://github.com/affaan-m/ECC.git`,
`https://github.com/anthropics/claude-plugins-official.git`,
`@opengsd/get-shit-done-redux` on npm.
