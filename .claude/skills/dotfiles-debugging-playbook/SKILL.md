---
name: dotfiles-debugging-playbook
description: Symptom-to-fix triage for this dotfiles repo. Load when something is BROKEN and you need to diagnose it -- plugin skills/commands missing from a session, settings.json truncated, dangling or write-through symlinks, "git refuses to commit" or wrong commit identity, SSH offering the wrong key, a guard hook blocking a commit, a cloud session missing its config, blank statusline, dead hooks, zsh nags, prettier rewriting files unexpectedly, or a worktree missing .todos/.planning. Trigger phrases: "why is X missing", "commit blocked", "hook didn't run", "wrong identity", "symlink broken", "plugin not installed". NOT for routine operation (dotfiles-run-and-operate), proving healthy state from first principles (dotfiles-verification-toolkit), or the history of past investigations (dotfiles-failure-archaeology).
---

# Dotfiles Debugging Playbook

Symptom -> likely cause -> discriminating check -> fix, for every failure mode
this repo has actually produced. Each entry with an incident history cites the
settling commit (verify with `git show <hash> --stat`). Run the check BEFORE
applying the fix: half these symptoms have two causes with opposite remedies,
and the check is what tells them apart.

**Jargon, defined once:** a _config dir_ is a Claude Code state directory
(`~/.claude` personal, `~/.claude-work` work; selected by `CLAUDE_CONFIG_DIR`).
A _plugin_ is a Claude Code extension installed from a _marketplace_ (a git
repo with a `.claude-plugin/marketplace.json` manifest). A _guard hook_ is a
Python script in `claude/hooks/` that blocks a tool call by exiting 2. A
_worktree_ is a linked `git worktree` checkout; _hydration_ is the
`git/hooks/post-checkout` hook symlinking/copying untracked `.todos/` and
`.planning/` state into it.

## Front-loaded warnings

- [WARNING] Never run ECC's `sync-ecc-to-codex.sh` directly to "fix" Codex
  state -- it overwrites `core.hooksPath`, writes through the `~/.codex/AGENTS.md`
  symlink into this repo, and leaves nameless agent files. Only the
  `codex-ecc-sync` wrapper in `zsh/functions.zsh` runs it safely
  (`ECC_GLOBAL_HOOKS_DIR` redirect).
- [WARNING] Never "fix" a cloud container's git identity by copying the
  signing block from `~/.gitconfig-personal` -- `op-ssh-sign` needs 1Password
  and every commit would fail. `bootstrap-cloud.sh` `reattribute_git_identity`
  copies name/email only and sets `commit.gpgsign false` (commit 2304015).
- [WARNING] Exit code 0 from `claude plugins install` does NOT mean the plugin
  installed. The on-disk truth is `~/.claude/plugins/installed_plugins.json`
  (commits 722c653, f91d7d2). Never report a plugin fixed without checking it.
- [WARNING] Guard-hook blocks (exit 2) exist to enforce non-negotiables
  (no AI attribution, no emojis, no secrets). Rewording the commit is the fix;
  routing around the hook is not.

## Quick index

| #   | Symptom                                          | Most likely cause                                          |
| --- | ------------------------------------------------ | ---------------------------------------------------------- |
| 1   | Plugin skills/commands missing in a session      | Post-launch install, cold marketplace, or wrong config dir |
| 2   | settings.json truncated or missing dotfiles keys | Write-through stale symlink, or seed-once template drift   |
| 3   | Dangling or write-through symlinks               | Old checkout deleted, or machine-local file got symlinked  |
| 4   | git refuses to commit                            | `useConfigOnly` outside `~/Git/{personal,work}` (intended) |
| 5   | Wrong commit identity used                       | includeIf miss, or cloud platform default author           |
| 6   | Commit signing fails                             | `op-ssh-sign` is macOS-only                                |
| 7   | SSH auth fails / wrong key offered               | Agent down, work pubkey absent, or pinning not applied     |
| 8   | Commit blocked by a guard hook                   | Prohibited term/emoji in message -- read the stderr reason |
| 9   | Cloud session missing config                     | SessionStart hook did not run or ran too late              |
| 10  | Statusline blank / hooks dead                    | `node` / `python3` absent from PATH                        |
| 11  | zsh stale-plugin nag or slow start               | 14-day epoch stamp expired; update check spawn             |
| 12  | File reformatted after your edit                 | `format_files.py` ran prettier -- re-read before next edit |
| 13  | Worktree missing .todos/.planning                | Hook guards not met, wrong shape, or workspace mode        |

## 1. Plugin skills/commands missing in a session

Three distinct causes. Discriminate in this order:

```bash
# (a) Is it installed at all, per the ground-truth file?
grep -o '"[a-z-]*@[a-z-]*"' ~/.claude/plugins/installed_plugins.json
# (b) Is the session even using ~/.claude? (work dirs route to ~/.claude-work)
claude-account            # zsh wrapper; or: echo "$CLAUDE_CONFIG_DIR"
# (c) Is the marketplace manifest warm (cloud/fresh machine)?
cat ~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json | head -5
```

| Check result                                          | Cause                                                                                                        | Fix                                                                                                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| (a) lists the plugin, session still lacks it          | Installed AFTER launch -- plugins load at CLI launch only (commit c1c4500, the root cause of the cloud saga) | Restart the session; nothing mid-session will help                                                                                                  |
| (a) missing, (c) manifest absent/does not list plugin | Cold marketplace: `plugins install` no-ops with exit 0 while the manifest is mid-fetch (commit 7cb28b7)      | `claude plugin marketplace add <git-url>` (synchronous clone), then install, then re-check (a). `bootstrap-cloud.sh` `ensure_plugin` automates this |
| (b) shows `~/.claude-work`                            | Right install, wrong config dir -- each dir has its own plugin installs                                      | `ecc-install` / `superpowers-install` maintain BOTH dirs; run them, or install with `CLAUDE_CONFIG_DIR` set                                         |

Cloud first session: the PRIMARY mechanism is the repo's committed
`.claude/settings.json` declaring `enabledPlugins` + `extraKnownMarketplaces`
(native pre-launch install, commit 8d4507f). The SessionStart hook is only the
self-heal -- a plugin it installs is dark until the NEXT session. On machines,
`superpowers-install` registers the official marketplace by git URL before
installing (commit 5b799dd; previously a silent no-op risk).

[WARNING] Open weak point: the machine-path installers (`ecc-install`,
`superpowers-install`) still trust `claude plugins list` output, not
`installed_plugins.json`. `bootstrap-cloud.sh` `ensure_plugin` is the gold
standard; when in doubt, check the JSON yourself.

## 2. settings.json truncated or missing dotfiles keys

`~/.claude/settings.json` is machine-local, seeded ONCE from
`claude/settings.json.tmpl` by `seed_machine_local_file`
(install/common/claude-links.sh). Two distinct failures:

```bash
# $DOTFILEDIR is exported by zsh/.zshrc (points at the repo checkout).
# If unset (non-interactive shell), substitute your checkout path
# (canonical machine path: ~/Git/personal/dotfiles; cloud: the repo checkout).
# Discriminate: compare size against the template (repair threshold is <50%)
wc -c ~/.claude/settings.json "$DOTFILEDIR/claude/settings.json.tmpl"
# Which keys are present?
python3 -c 'import json;print(sorted(json.load(open("'"$HOME"'/.claude/settings.json"))))'
```

| Finding                                     | Cause                                                                                                                                              | Fix                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| File is a few bytes / only `enabledPlugins` | Something wrote through a stale symlink, or a plugin installer created the file first so the seed was skipped (commit 910f2bc found this in cloud) | Machine: `bin/dotfiles-repair` (re-seeds safely), or `rm ~/.claude/settings.json && cp "$DOTFILEDIR/claude/settings.json.tmpl" ~/.claude/settings.json` (`$DOTFILEDIR`, not `$DOTFILES` -- the latter is unset in shells), then re-run plugin installers. Cloud: `bootstrap-cloud.sh` runs `reconcile_claude_settings` (merges template + live plugin keys) |
| File healthy but lacks a NEW template key   | Seed-once by design: template changes never auto-land on machines                                                                                  | Manual merge from the template. [WARNING] Open weak point -- machines have no reconcile step; only cloud does                                                                                                                                                                                                                                               |
| File is a symlink                           | Broken invariant (installers must write to a real file)                                                                                            | `bin/dotfiles-repair` step 2 re-links; `seed_machine_local_file` removes the symlink and re-seeds                                                                                                                                                                                                                                                           |

`bin/dotfiles-repair` step 3 automates the size check and prints the re-seed
command. Both config dirs are drift-checked by
`claude/hooks/claude-hooks.test.sh`.

## 3. Dangling or write-through symlinks

Two opposite failures with the same word in them:

- **Dangling**: `~/.zshrc`, `~/.gitconfig`, `~/.claude/*` point at a deleted
  old checkout. Everything silently reverts to defaults.
- **Write-through**: a file that must be machine-local (settings.json) is a
  symlink INTO the repo, so tools writing it pollute the dotfiles checkout.

```bash
# Dangling: symlink exists but target does not
for p in ~/.gitconfig ~/.zshrc ~/.claude/CLAUDE.md ~/.claude/hooks ~/.claude/skills; do
  [ -L "$p" ] && [ ! -e "$p" ] && echo "DANGLING: $p -> $(readlink "$p")"
done
# Write-through pollution: unexpected dirt in the repo ($DOTFILEDIR -- see #2)
git -C "$DOTFILEDIR" status --short
```

Fix for both: `bin/dotfiles-repair` (pulls main if clean, re-runs the platform
`link.sh`, verifies settings.json, flags compromised GSD, spot-checks final
state). `bin/identity-doctor` reports dangling identity links read-only.

## 4. git refuses to commit ("no email... auto-detection is disabled")

This is the INTENDED loud failure, not a bug. `git/.gitconfig` sets
`user.useConfigOnly = true` and has no `[user]` name/email; identity comes only
from `includeIf "gitdir/i:~/Git/personal/"` and `~/Git/work/`.

```bash
git config user.email          # empty => no identity resolved here
git rev-parse --show-toplevel  # is the repo under ~/Git/personal or ~/Git/work?
```

Fix: move the repo under a convention dir, or deliberately set a repo-local
`git config user.email <addr>`. Do NOT set a global user.email -- that
reintroduces the silent-wrong-identity failure the design exists to prevent.

## 5. Wrong commit identity used

Different from #4: a commit SUCCEEDS with the wrong author.

```bash
git config --show-origin user.email   # which file supplied it?
identity-doctor                        # full chain verdict (also: git identity)
```

| Origin shown                                           | Cause                                                                   | Fix                                                                                                               |
| ------------------------------------------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `~/.gitconfig-personal` in a work repo (or vice versa) | Repo is under the wrong convention dir, or `~/.gitconfig-work` unseeded | Move the repo, or run `identity-setup` to populate the work config                                                |
| Global `user.email` = `noreply@anthropic.com`          | Cloud platform default author (commit 2304015)                          | Run `bootstrap-cloud.sh` -- `reattribute_git_identity` overrides only the platform default, never a real identity |
| Repo-local override                                    | Someone set it on purpose                                               | Confirm intent before removing                                                                                    |

Note: linked worktrees resolve to the MAIN repo's gitdir, so a `/tmp` review
worktree inherits the main checkout's identity (documented in
`git/.gitconfig` header comment).

## 6. Commit signing fails

`git/.gitconfig` points `gpg.ssh.program` at
`/Applications/1Password.app/Contents/MacOS/op-ssh-sign` -- macOS-only.
[WARNING] Open weak point: Linux machines with `commit.gpgsign=true` from an
identity include will fail to commit. Containers are handled
(`bootstrap-cloud.sh` sets `commit.gpgsign false`); bare-metal Linux is not.
Workaround: `git config --global commit.gpgsign false` on Linux, or sign via a
locally installed op-ssh-sign path.

## 7. SSH auth fails or wrong key offered

Key pinning design: `~/.ssh/config` includes `config_local`, then personal,
then work sub-configs; first match wins. `github.com` and `Git-Personal` pin
`~/.ssh/id_ed25519_personal` with `IdentitiesOnly yes`; `Git-work` pins
`~/.ssh/id_ed25519_work`. Private keys live only in the 1Password agent.

```bash
ssh -G github.com | awk '/^identityfile/ {print $2}'   # what WOULD be offered
ssh -G Git-work   | awk '/^identityfile/ {print $2}'
ssh -T git@github.com                                   # live auth check
ls -l ~/.ssh/id_ed25519_work.pub ~/.config/1Password/ssh/agent.toml
```

| Finding                                    | Cause                                                                         | Fix                                                                         |
| ------------------------------------------ | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| identityfile is wrong / not the pinned key | `~/.ssh/config_local` host block shadows the pinned one (first value wins)    | Edit `config_local`; it is machine-local by design                          |
| `Git-work` auth fails, pubkey file absent  | Work key never provisioned -- Git-work fails LOUDLY by design until it exists | `identity-setup` writes `~/.ssh/id_ed25519_work.pub`                        |
| All SSH auth fails                         | 1Password agent socket missing                                                | Start 1Password with SSH agent enabled; `identity-doctor` checks the socket |
| Agent offers unexpected vault keys         | `agent.toml` missing                                                          | Re-run `link.sh` to seed `~/.config/1Password/ssh/agent.toml`               |

`identity-doctor` runs all of these read-only and exits 1 on any `[X]`.

## 8. Commit blocked by a guard hook

The block reason is printed to stderr by the hook, e.g.
`Blocked: Commit message contains prohibited AI attribution terms`. Hooks exit
2 to block and fail OPEN on internal exceptions (they never block by crashing).

Registered guards (claude/settings.json.tmpl `hooks` block; block-message
triage view only -- the full registration table, including the non-blocking
`cache_jira_url.py` and `account_guard.py`, lives in
claude-code-platform-reference):

| Hook                                  | Fires on                 | Blocks when                                                                                                                                                                                                 |
| ------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `commit_guard.py`                     | Bash `git commit`        | Message contains claude/anthropic/copilot/gpt terms, AI co-author/generated-with lines, or emojis                                                                                                           |
| `no_ai_attribution_bash.py`           | Bash                     | AI attribution in bash-driven writes                                                                                                                                                                        |
| `block_secrets.py`                    | Read/Edit/Write          | Path is `.env*`, key material, or has a `credentials`/`secrets` segment. Segment-based matching (commit 52f807d) -- it previously blocked innocent paths like `secrets_manager/util.py` via substring match |
| `emoji_guard.py`, `no_ai_comments.py` | Edit/Write (PostToolUse) | Emojis / AI comments in file content                                                                                                                                                                        |
| `protect_claude_md.py`                | Edit/Write               | Warn-only (never blocks)                                                                                                                                                                                    |

Reading `commit_guard.py` behavior before deciding what to do:

- The `<scope>:` prefix is stripped before term matching, so
  `claude: Fix hooks` is a LEGAL commit message; "claude" in the body is not.
- Commands containing `/.claude/` are exempted entirely (config commits).

When is a bypass legitimate? Almost never. Decision rule:

- Blocked for AI attribution or emoji: NOT legitimate -- reword. These are the
  repo's non-negotiables (claude/CLAUDE.md "Strict Rules").
- Blocked for a prohibited term used descriptively (e.g. a commit about the
  claude() wrapper body text): reword to keep the term in the scope prefix or
  out of the message; put detail in the PR body.
- `block_secrets.py` blocking a genuinely innocent path: since 52f807d this
  should not happen; if it does, treat it as a hook bug -- fix the hook (with
  its test in `claude/hooks/claude-hooks.test.sh`), do not disable it.

## 9. Cloud session missing config (SessionStart hook did not run)

Expected chain: repo `.claude/settings.json` SessionStart hook (matcher
`startup|resume`) -> `.claude/hooks/session-start.sh` -> exits 0 unless
`CLAUDE_CODE_REMOTE=true` -> runs `bootstrap-cloud.sh`.

```bash
echo "${CLAUDE_CODE_REMOTE:-unset}"        # must be "true" in a cloud container
grep -A6 SessionStart "$DOTFILEDIR/.claude/settings.json"   # matcher present? ($DOTFILEDIR -- see #2)
bash "$DOTFILEDIR/bootstrap-cloud.sh"   # run it manually; read its [bootstrap-cloud] lines
```

| Finding                                         | Cause                                                                                                                                            | Fix                                                                                          |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `CLAUDE_CODE_REMOTE` unset                      | Not a cloud container, or platform changed the env var                                                                                           | On a real machine this hook is a no-op BY DESIGN -- use `update`/`dotfiles-repair` instead   |
| Hook ran but plugins still missing this session | Post-launch timing (see #1); hook is the self-heal, not the primary path                                                                         | Restart the session; plugins load at launch (commit c1c4500)                                 |
| Hook never fired on `/clear`                    | Matcher is `startup\|resume` -- `clear`/`compact` do not match                                                                                   | Expected; run `bootstrap-cloud.sh` manually if needed                                        |
| bootstrap-cloud prints `!! FAILED` for a plugin | Network / marketplace fetch failed after 8 capped retries (backoff capped at 15s, commit da54e17, so it cannot blow the Setup-script ~5-min cap) | `claude plugins install <id>` once network recovers; verify against `installed_plugins.json` |

## 10. Statusline blank or hooks dead

`statusLine.command` is `node ~/.claude/statusline.js`; every guard hook is
`#!/usr/bin/env python3`. `bootstrap-cloud.sh` warns on exit when either
interpreter is missing.

```bash
command -v node python3
node ~/.claude/statusline.js </dev/null   # direct render attempt
ls -l ~/.claude/statusline.js             # dangling symlink? (see #3)
```

Fix: install the missing interpreter, or re-link (`dotfiles-repair`) if the
symlink dangles. Note hooks fail open -- a dead python3 means guards silently
STOP ENFORCING, not that sessions break. Treat missing python3 as a policy
outage, not cosmetic.

## 11. zsh stale-plugin nag or slow start

- `[INFO] Stale: ecc (Nd). Run 'ecc-update' to refresh.` comes from
  `_claude_plugin_check_update` (zsh/functions.zsh): a per-plugin day-epoch
  stamp in `${ZSH_CACHE_DIR:-~/.cache/zsh}/.ecc-update`, threshold 14 days.
  Fix: run `ecc-update`. GSD is deliberately absent from the loop (commit
  9ad4dc8) -- a gsd nag on a current checkout means an old functions.zsh.
- `[INFO] Claude Code update available: ...` comes from
  `_claude_code_update_check`: the `npm view` runs backgrounded and cached 24h
  (`~/.cache/dotfiles/claude-code-update-check`), so it should not block
  startup. If startup IS slow, measure before blaming:

```bash
time zsh -i -c exit          # baseline
zsh -i -x -c exit 2>&1 | tail -50   # what ran last/slowest
```

## 12. Prettier reformatting surprises

`format_files.py` (PostToolUse on Edit/Write) runs
`prettier --write --ignore-unknown <file>` after EVERY edit. Consequences:

- The on-disk file may differ from what you just wrote. Re-read after any
  formatter pass before editing again (operating-principles.md, "Read before
  you edit") -- a stale-content Edit will fail or corrupt.
- Markdown/JSON/YAML get prettier's opinions (wrapping, quotes). If a file
  must not be reformatted, that is a repo `.prettierignore` decision, not a
  reason to disable the hook.
- `prettier` missing from PATH: the hook silently does nothing (fails open).
  Check `command -v prettier` if formatting seems dead.

## 13. Worktree missing .todos/.planning hydration

`git/hooks/post-checkout` (global, via `core.hooksPath = ~/.config/git/hooks`)
hydrates untracked `.todos/` (and legacy `.planning/`) into new linked
worktrees. It exits early unless ALL guards pass -- check them in order:

```bash
git config core.hooksPath                    # must be ~/.config/git/hooks
ls -l ~/.config/git/hooks/post-checkout      # symlink resolves into the repo?
ls -la .git                                  # linked worktree has .git as a FILE
ls -ld /path/to/main/.todos                  # main must actually have .todos/
```

| Finding                                               | Cause                                                                                                                                       | Fix                                                                                                   |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `core.hooksPath` wrong/absent                         | Something rewrote it (the classic culprit: running ECC's sync script directly -- see warnings)                                              | Re-link `~/.gitconfig` (`dotfiles-repair`); use `codex-ecc-sync` only                                 |
| Hook fired but printed `WARN: .todos has wrong shape` | Existing dir/symlink does not match the canonical symlink; hook refuses destructive replace by default                                      | Re-run checkout with `GSD_HOOK_REPAIR=1` (destructive -- rsync worktree-unique content to main FIRST) |
| Hook printed `workspace mode detected`                | `.planning/config.json` declares `"mode": "workspace"` or phases/PROJECT.md exist -- hydration is skipped by design; leftover symlinks warn | `GSD_HOOK_ISOLATE=1` converts leftover symlinks to per-worktree copies                                |
| No output at all                                      | File checkout (not branch), or `.git` is a directory (main checkout), or main has no `.todos/`                                              | Expected no-ops -- see the guard chain at the top of `git/hooks/post-checkout`                        |
| Symlinks broken after moving the main checkout        | Hydration symlinks are ABSOLUTE paths to main (known limit #4 in the hook header)                                                           | Re-run in each worktree with `GSD_HOOK_REPAIR=1`                                                      |

[WARNING] Coverage gap: `git/hooks/post-checkout.test.sh` is static-shape-only,
and the ECC-vendored `pre-commit`/`pre-push` in the same dir are untested. Do
not assume test-green covers live hook behavior here.

## Discriminating-experiment discipline

When the table does not settle it, fall back to method (full treatment:
dotfiles-research-methodology):

1. **One variable per experiment.** "Re-run bootstrap AND restart AND
   reinstall" proves nothing when it works.
2. **Predict the observation BEFORE running.** Write down what a specific
   cause would make this command print. If the output surprises you, the model
   is wrong -- stop and update it before the next command.
3. **Prefer state files over exit codes.** This repo's worst bug class was
   exit-0 lies (`plugins install`, commits 722c653/f91d7d2). Ground truth lives
   in `installed_plugins.json`, the marketplace manifest, `git config
--show-origin`, `ssh -G`, and `readlink` -- not in return status.
4. **Record the baseline first.** `bin/dotfiles-tests` before and after your
   fix; a fix that flips an unrelated suite is a new bug.
5. **Reproduce before claiming fixed.** Trigger the original symptom path once
   more (new session, new worktree, fresh container) -- do not infer from the
   fix's own output.

## When NOT to use this skill

- Routine lifecycle (update, plugin ops, account routing when nothing is
  broken): **dotfiles-run-and-operate**.
- Proving a healthy chain from first principles (symlink chain, plugin
  install, identity resolution, hook firing) with worked examples:
  **dotfiles-verification-toolkit**.
- Why a past decision/revert happened, settled investigations, dead ends:
  **dotfiles-failure-archaeology**.
- Doctor scripts, the test runner, and measurement tooling as such:
  **dotfiles-diagnostics-and-tooling**.
- Standing up a fresh machine or container from zero: **dotfiles-build-and-env**.
- Classifying and gating a CHANGE you are about to make:
  **dotfiles-change-control**.

## Provenance and maintenance

Facts verified against the working tree on 2026-07-02. Volatile items and how
to re-verify:

| Fact                                                                                                                | Re-verify                                                                                |
| ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Incident hashes (2304015, 722c653, f91d7d2, 7cb28b7, c1c4500, da54e17, 8d4507f, 52f807d, 5b799dd, 9ad4dc8, 910f2bc) | `git log -1 --format='%h %s' <hash>`                                                     |
| Guard hook registrations and matchers                                                                               | `python3 -c 'import json;print(json.load(open("claude/settings.json.tmpl"))["hooks"])'`  |
| SessionStart cloud matcher `startup\|resume`                                                                        | `grep -A3 SessionStart .claude/settings.json`                                            |
| `ensure_plugin` retry budget (8 tries, 15s cap)                                                                     | `grep -n 'PLUGIN_RETR' bootstrap-cloud.sh`                                               |
| Settings seed threshold (<50% of template)                                                                          | `grep -n 'dest_size \* 2' install/common/claude-links.sh bin/dotfiles-repair`            |
| Stale-plugin nag threshold (14 days, ecc only)                                                                      | `grep -n 'update_days\|for plugin in' zsh/functions.zsh`                                 |
| post-checkout guard chain and env flags                                                                             | `sed -n '85,100p' git/hooks/post-checkout; grep -n 'GSD_HOOK_' git/hooks/post-checkout`  |
| SSH pinning per host                                                                                                | `grep -n IdentityFile ssh/configs/personal/config_personal ssh/configs/work/config_work` |
| `useConfigOnly` + includeIf routing                                                                                 | `grep -n 'useConfigOnly\|includeIf' git/.gitconfig`                                      |
| Test suite list (9 suites as of 2026-07-02)                                                                         | `bin/dotfiles-tests --list`                                                              |

Open items carried as open (do not document as fixed): machine-path plugin
installers trust CLI output; template changes need manual merge on machines;
Linux commit signing; pre-commit/pre-push untested; ECC rules vendoring
necessity.
