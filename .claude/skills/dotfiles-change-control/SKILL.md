---
name: dotfiles-change-control
description: Load BEFORE making, committing, or reviewing ANY change in the dotfiles repo. Covers change classification (tracked asset vs installer logic vs machine-local template vs vendored-untracked vs project .claude config), the full gate chain (guard hooks, bin/dotfiles-tests, public-safety scan, CI), commit/branch/PR rules, and the non-negotiables with their incident history. Trigger phrases -- "commit this", "open a PR", "why did my commit get blocked", "can I edit settings.json.tmpl", "can I edit these rules files", "hook blocked me", "bypass the hook". NOT for diagnosing why something is broken (dotfiles-debugging-playbook), running the tests as evidence (dotfiles-validation-and-qa), or historical why-decisions (dotfiles-failure-archaeology).
---

# Dotfiles Change Control

How changes are classified, gated, tested, and reviewed in this repo, and which
rules are non-negotiable. This repo is PUBLIC (github.com/taloncjones/dotfiles)
and its assets are symlinked live into `~/.claude`, `~/.claude-work`, and
`~/.codex` on every machine that runs it -- a bad commit here ships instantly to
every session on every machine. Read this before your first edit, not after
your first blocked commit.

## Front-loaded warnings

- [WARNING] PUBLIC repo. No secrets, no employer names/URLs, no machine-local
  paths (`/Users/<name>` -- writing the real one out would itself trip the
  scan). The public-safety suite (`git/hooks/public-safety.test.sh`)
  fails the build on violations; do not rely on it as your only check.
- [WARNING] Never hand-edit vendored content: the ECC language dirs under
  `claude/rules/` (everything except `personal/`) and the `<!-- BEGIN ECC -->`
  sentinel block in `codex/AGENTS.md`. Installers overwrite both; your edit
  dies on the next `ecc-update`.
- [WARNING] `claude/settings.json.tmpl` changes reach existing machines only at
  their next `update`/link run (reconcile merge); until then live settings are
  stale -- see the protocol below.
- [WARNING] Hook bypass variables exist for emergencies only (broken hook,
  never a policy disagreement). Every bypass must be mentioned in the PR
  description.
- [WARNING] Everything runs through `update` -> `install/install.sh` repeatedly.
  Any installer change must be idempotent: safe to run twice, safe on a machine
  that already has the state.

## Step 0: classify the change

Every file in this repo belongs to exactly one class. The class determines what
your change needs.

| Class                          | Examples                                                                                                | What a change requires                                                                                                                                                                                            |
| ------------------------------ | ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tracked asset (symlinked live) | `zsh/*.zsh`, `claude/CLAUDE.md`, `claude/skills/`, `claude/hooks/*.py`, `git/hooks/commit-msg`, `bin/*` | Normal commit + tests. Takes effect on machines at next symlink resolution (usually immediately -- symlinks point into the repo checkout). Hook changes: update `claude/hooks/claude-hooks.test.sh` drift checks. |
| Installer logic                | `bootstrap.sh`, `bootstrap-cloud.sh`, `install/**`, `zsh/functions.zsh` install helpers                 | Must stay idempotent (`update` re-runs `install.sh`). Update `install/install.test.sh` if flow shape changes. Platform-gate macOS/Linux paths.                                                                    |
| Machine-local template         | `claude/settings.json.tmpl`, `git/work/.gitconfig-work.tmpl`, `ssh/configs/agent.toml`                  | Seed-once: template edits reach only FRESH machines automatically. Follow the settings.json.tmpl protocol below.                                                                                                  |
| Vendored-untracked             | `claude/rules/{common,cpp,python,rust,typescript,web}/`, ECC skills/commands                            | NEVER edit by hand. Re-vendor via `ecc-update`/`ecc-sync-rules`. Untracked by design (`claude/rules/.gitignore` whitelists only `personal/`). To change behavior, change it upstream in ECC or wrap it.           |
| Project `.claude/` config      | `.claude/settings.json`, `.claude/hooks/session-start.sh`, `.claude/skills/`                            | Tracked, load-bearing for CLOUD sessions (plugin declaration is the pre-launch install path -- see claude-code-platform-reference). Changes here alter what every fresh cloud container gets on session 1.        |

Vendored-but-TRACKED special case: `git/hooks/pre-commit` and `pre-push` are
adapted ECC copies that ARE tracked (and NOTICE-listed) -- do not hand-patch
them; re-vendor or fix upstream (see "Special protocol: vendored content").

Quick classification checks:

```bash
# Run from the repo checkout (canonical machine path ~/Git/personal/dotfiles;
# cloud containers use the platform checkout -- the repo is location-independent)
git ls-files --error-unmatch <path>   # tracked? (fails = untracked/vendored)
readlink ~/.claude/CLAUDE.md          # confirm the live symlink target
```

## The gate chain (what fires between edit and merge)

In order, for a change made inside a Claude Code session:

1. **Claude guard hooks** (session-time, registered in
   `claude/settings.json.tmpl`, active via each machine's `settings.json`):

   | Hook (`claude/hooks/`)      | Event / matcher              | Blocks                                                                                                                                                                               |
   | --------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
   | `commit_guard.py`           | PreToolUse Bash              | `git commit` commands whose message mentions Claude/Anthropic/Copilot/ChatGPT, AI co-author lines, "Generated with" footers, emojis                                                  |
   | `no_ai_attribution_bash.py` | PreToolUse Bash              | AI attribution in ANY outbound command payload (`gh pr comment`, `curl --data`) -- closes the non-commit gap                                                                         |
   | `block_secrets.py`          | PreToolUse Read\|Edit\|Write | Access to `.env`, key files (`.pem`, `id_ed25519`, ...), credential dirs. Segment/basename matching, not substring (substring matching blocked the hook's own file -- fixed 52f807d) |
   | `protect_claude_md.py`      | PreToolUse Edit\|Write       | Nothing -- WARNS on global CLAUDE.md edits                                                                                                                                           |
   | `emoji_guard.py`            | PostToolUse Edit\|Write      | Emojis written into files (exit 2 = block)                                                                                                                                           |
   | `no_ai_comments.py`         | PostToolUse Edit\|Write      | "Generated by ..." comments in code (markdown exempt)                                                                                                                                |
   | `format_files.py`           | PostToolUse Edit\|Write      | Nothing -- runs prettier                                                                                                                                                             |

   Hooks exit 2 to block and fail OPEN on internal exceptions (a crashed hook
   never blocks work -- it also never protects it, so do not assume silence
   means clean). This table covers only the BLOCKING gates relevant to a
   change; the full registration table (including `cache_jira_url.py` and
   `account_guard.py`) lives in claude-code-platform-reference -- that skill
   is the single home for it.

2. **Git hooks** (`core.hooksPath = ~/.config/git/hooks` -> symlink to
   `git/hooks/`; fire on EVERY commit, any tool, any editor -- LINKED MACHINES
   ONLY: cloud containers never set `core.hooksPath` (`bootstrap-cloud.sh`
   does not link `~/.gitconfig`), so none of these hooks fire there and the
   Claude guard hooks plus CI are the only gates):

   | Hook                        | Fires                 | Blocks                                                                                             | Bypass (EMERGENCY ONLY)                          |
   | --------------------------- | --------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
   | `commit-msg`                | commit                | attribution terms, AI co-author lines, emojis in the message                                       | `DOTFILES_SKIP_COMMIT_MSG_GUARD=1`               |
   | `pre-commit` (ECC-vendored) | commit                | staged high-signal secrets                                                                         | `ECC_SKIP_PRECOMMIT=1` or `ECC_SKIP_GIT_HOOKS=1` |
   | `pre-push` (ECC-vendored)   | push                  | failing lint/typecheck/test/build in Node projects (verification flow -- it does NOT scan secrets) | `ECC_SKIP_PREPUSH=1` or `ECC_SKIP_GIT_HOOKS=1`   |
   | `post-checkout`             | checkout/worktree add | nothing -- hydrates `.todos`/`.planning` into worktrees                                            | n/a                                              |

   Bypass discipline: use only when the hook itself is broken (e.g. `rg`
   missing false-positive), never to land content the hook correctly rejects.
   State the bypass and the reason in the PR description. Note `commit-msg`
   silently SKIPS its checks if `rg` is not installed -- absence of a block is
   not proof of a clean message.

3. **Tests, before every push** -- the single runner:

   ```bash
   bash bin/dotfiles-tests           # from the repo checkout: all suites, one verdict
   bash bin/dotfiles-tests --list    # enumerate suites
   ```

   Non-zero exit = do not push. The public-safety suite
   (`git/hooks/public-safety.test.sh`) is part of this run: no tracked
   `todo.md`, no `/Users/<name>` paths, no high-confidence secret patterns in
   the tree.

4. **CI** (`.github/workflows/tests.yml`): runs on push to `main` and on every
   PR. zsh syntax gate, bash syntax gate, python `py_compile` on all hooks,
   then `bash bin/dotfiles-tests`. CI green is necessary, not sufficient --
   syntax gates and drift checks do not execute installers end-to-end.

5. **PR review**: target `main`, squash merge, description + test plan. Do not
   push directly to `main` for anything non-trivial.

## Commit, branch, PR format (from claude/CLAUDE.md, hook-enforced)

- Commit: `<scope>: <summary>` -- imperative mood, under 75 chars, scope =
  affected area. Examples: `zsh: Add geoip lookup function`,
  `install: Fix Brewfile path`.
- Branch: `<user>/<topic-slug>`; with a Jira ticket
  `<user>/<PROJ-###>/<topic-slug>`.
- PR: target `main`, squash merge, include description and test plan; Jira link
  at the bottom if one exists.
- Author: the human's git identity only. No Claude author, no co-author, no
  attribution anywhere in message or body.

## Special protocol: claude/settings.json.tmpl

Why it is special: `~/.claude/settings.json` and `~/.claude-work/settings.json`
are machine-local because plugin installers (ECC) WRITE into them at runtime.
The installer therefore seeds the file from the template only if it is absent
(`seed_machine_local_file` in `install/common/claude-links.sh`, called by
`link_claude_config_dir`) -- re-copying on every `update` would clobber the
installer-written plugin keys. Consequence: a template edit lands on fresh
machines only.

When you change the template:

1. Edit `claude/settings.json.tmpl` (e.g. register a new hook).
2. Run `bash bin/dotfiles-tests` -- `claude/hooks/claude-hooks.test.sh`
   drift-checks live `settings.json` against the template on each machine, and
   `install/claude-links.test.sh` proves the reconcile merge semantics.
3. Existing machines pick the change up at their next `update` (or any
   `link.sh`/`dotfiles-repair` run): `reconcile_claude_settings_file`
   (`install/common/claude-links.sh`) reasserts template-owned keys per config
   dir while plugin-installer keys survive (closed 2026-07-02; previously a
   manual hand-merge). A machine that never runs `update` stays stale -- the
   drift check in step 2 is what surfaces it.
4. Cloud uses the same shared merge: `bootstrap-cloud.sh`
   `reconcile_claude_settings` delegates to `reconcile_claude_settings_file`
   (template supplies defaults, live plugin keys win) -- history: 910f2bc.

## Special protocol: vendored content

- ECC language rules: vendoring RETIRED (2026-07-02) -- `ecc-sync-rules` and
  `ECC_VENDOR_LANGS` are gone; the upstream rules tree lives in the ECC
  marketplace clone (`~/.claude/plugins/marketplaces/ecc/rules/`). Language
  dirs still under `claude/rules/` are inert pre-retirement leftovers, kept
  uncommitted by `claude/rules/.gitignore`. Your own rules go in
  `claude/rules/personal/` -- the only whitelisted, tracked subdir. History:
  tracked vendored rules caused 39-file churn (untracked at e140ab3), then
  vendoring itself was retired once consumer enumeration found no runtime
  reader of `~/.claude/rules`.
- `codex/AGENTS.md`: everything between `<!-- BEGIN ECC -->` and the matching
  end marker is a sync-managed sentinel block. Edit only the text outside it;
  regenerate the block via `codex-ecc-sync` (in `zsh/functions.zsh`), which
  runs ECC's sync script SAFELY with `ECC_GLOBAL_HOOKS_DIR` redirected. Never
  run ECC's `sync-ecc-to-codex.sh` directly -- it overwrites `core.hooksPath`
  and writes through the `~/.codex/AGENTS.md` symlink into this repo
  (documented incident, CLAUDE.md "Codex plugin integration").
- ECC git hooks `git/hooks/pre-commit` and `pre-push` are vendored copies
  that are TRACKED in git (adapted from ECC, listed in `NOTICE`): do not patch
  them by hand; fix upstream or re-vendor.

## Non-negotiables, with rationale and incident

| Rule                                           | Enforced by                                                                       | Why (incident)                                                                                                                                                                                                                |
| ---------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No AI attribution; commits look human-authored | `commit_guard.py`, `no_ai_attribution_bash.py`, `no_ai_comments.py`, `commit-msg` | Cloud containers seed `Claude <noreply@anthropic.com>` as git identity; 2304015 reattributes cloud commits to the personal identity. Attribution that slips through is permanent public history.                              |
| No secrets, ever                               | `block_secrets.py`, ECC `pre-commit` secret scan, public-safety suite, CI         | PUBLIC repo. A leaked key is compromised the moment it is pushed. Related supply-chain lesson: the GSD npm package was compromised via token rug-pull (retired at 9ad4dc8) -- never reinstall it.                             |
| Machine-local files never tracked              | seed-once design, public-safety "no tracked todo.md" check                        | Tracking installer-written files causes write-through corruption: the abandoned Codex mirror wrote through symlinks into the repo and orphaned `core.hooksPath`. Machine state and repo state must not share a writable file. |
| No emojis anywhere                             | `emoji_guard.py`, `commit_guard.py`, `commit-msg`                                 | House style (`~/.claude/CLAUDE.md`); use `[OK]` `[X]` `[WARNING]` `[INFO]`. Hook exit 2 blocks the write.                                                                                                                     |
| Idempotent installers                          | convention + `install/install.test.sh`                                            | `update` re-runs `install.sh` on every invocation; a non-idempotent step breaks every machine on its next update.                                                                                                             |
| Pre-launch placement for cloud plugins         | `.claude/settings.json` declaration                                               | Plugins load at CLI launch; a post-launch install is dark until next session (root cause c1c4500; final design 8d4507f). Do not "simplify" the declaration away into the SessionStart hook.                                   |

## Pre-push checklist

- [ ] Change classified (table above) and its class requirements met?
- [ ] `bash bin/dotfiles-tests` green locally (all suites)?
- [ ] Installer edits idempotent and platform-gated?
- [ ] No secrets, no employer strings, no `/Users/<name>` paths in the diff?
- [ ] Commit message `<scope>: <summary>`, <75 chars, imperative, no attribution, no emojis?
- [ ] Template edits: manual-merge plan for existing machines stated in the PR?
- [ ] Vendored files untouched (or re-vendored, not hand-edited)?
- [ ] Any hook bypass used? If yes: broken-hook justification in the PR description.
- [ ] PR targets `main`, squash merge, description + test plan?

## When NOT to use this skill

- Diagnosing WHY something broke (symlink dead, hook not firing, plugin
  missing) -> `dotfiles-debugging-playbook`.
- Test-suite inventory, what counts as evidence, adding a test ->
  `dotfiles-validation-and-qa`.
- Why a past decision was made, settled reverts, dead ends with hashes ->
  `dotfiles-failure-archaeology`.
- Design invariants and load-bearing architecture -> `dotfiles-architecture-contract`.
- Claude Code platform mechanics (config dirs, plugin/marketplace internals,
  cloud container lifecycle) -> `claude-code-platform-reference`.
- Public-repo posture in depth (what may never land, licensing, supply chain)
  -> `dotfiles-external-positioning`.
- Day-to-day ops (update lifecycle, plugin repair, account routing) ->
  `dotfiles-run-and-operate`.

## Provenance and maintenance

Facts verified against the repo on 2026-07-02. Volatile items and how to
re-verify:

All commands run from the repo checkout root (the repo is
location-independent; canonical machine path `~/Git/personal/dotfiles`, cloud
containers use the platform checkout):

| Fact                                                                                   | Re-verify                                                                                                                  |
| -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| 10 test suites in the runner                                                            | `bash bin/dotfiles-tests --list`                                                                                           |
| Guard-hook registrations and matchers                                                  | `grep -n -A4 'matcher' claude/settings.json.tmpl`                                                                          |
| Hook inventory                                                                         | `ls claude/hooks/ git/hooks/`                                                                                              |
| `DOTFILES_SKIP_COMMIT_MSG_GUARD` still the commit-msg bypass                           | `grep -n 'SKIP' git/hooks/commit-msg`                                                                                      |
| ECC bypass vars                                                                        | `grep -n 'ECC_SKIP' git/hooks/pre-commit git/hooks/pre-push`                                                               |
| hooksPath indirection                                                                  | `git config --get core.hooksPath` (expect `~/.config/git/hooks`; EMPTY in cloud containers -- git hooks do not fire there) |
| Seed-once settings behavior                                                            | `grep -n 'seed_machine_local_file' install/common/claude-links.sh`                                                         |
| Cloud settings reconcile                                                               | `grep -n 'reconcile_claude_settings' bootstrap-cloud.sh`                                                                   |
| Rules whitelist (only `personal/` tracked)                                             | `cat claude/rules/.gitignore`                                                                                              |
| AGENTS.md sentinel marker                                                              | `grep -n 'BEGIN ECC' codex/AGENTS.md`                                                                                      |
| CI trigger + steps                                                                     | `cat .github/workflows/tests.yml`                                                                                          |
| Cited commits (2304015, 52f807d, e140ab3, 910f2bc, c1c4500, 8d4507f, 9ad4dc8, 465ee17) | `git show -s --format='%h %s' <hash>`                                                                                      |

Known-open as of 2026-07-02: all three original entries closed the same day --
machine-path plugin installs verify against `installed_plugins.json`
(`_claude_ensure_plugin` + `zsh/functions.test.sh`); machine-side auto-merge
for `settings.json.tmpl` (`reconcile_claude_settings_file` +
`install/claude-links.test.sh`); ECC `pre-commit`/`pre-push` behavioral suites
and a post-checkout runtime suite
(`git/hooks/{pre-commit,pre-push,post-checkout-runtime}.test.sh`).
