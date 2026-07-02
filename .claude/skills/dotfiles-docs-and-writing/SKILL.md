---
name: dotfiles-docs-and-writing
description: Use when writing or updating any doc of record in this dotfiles repo -- README.md, repo CLAUDE.md, claude/CLAUDE.md, claude/operating-principles.md, codex/AGENTS.md, NOTICE -- or when authoring a new skill or slash command file. Trigger on "update the README", "document this", "where should this fact live", "add a skill", "add a command", "the docs are stale", "docs drift", or any house-style question (emoji tags, dash style, commit-message format). Not for platform mechanics content itself (use claude-code-platform-reference), change gating and review process (use dotfiles-change-control), or public-repo/licensing posture decisions (use dotfiles-external-positioning).
---

# Dotfiles Docs and Writing

Ownership map for every doc of record in this repo, the hook-enforced house
style, the templates for new skills and commands, and the update-trigger
checklist that keeps docs from drifting when the code surface changes. Rule
zero: every fact has exactly ONE home; other docs point to it, never restate it.
Rule one: always edit the REPO file, never the live symlinked copy under
`~/.claude*` or `~/.codex`.

## Warnings first

- [WARNING] `codex/AGENTS.md` contains an upstream-owned block between
  `<!-- BEGIN ECC -->` (codex/AGENTS.md:143) and `<!-- END ECC -->` (last line).
  NEVER hand-edit inside it -- it is overwritten wholesale by `codex-ecc-sync`
  (zsh/functions.zsh, run by `ecc-install`/`ecc-update`), which writes through
  the `~/.codex/AGENTS.md` symlink into this repo. Hand-maintained content goes
  ABOVE the sentinel only.
- [WARNING] `claude/CLAUDE.md` is symlinked to `~/.claude/CLAUDE.md` and
  `~/.claude-work/CLAUDE.md` and loads in EVERY session in EVERY repo. A bad
  edit propagates globally on the next session start. The
  `protect_claude_md.py` hook warns (does not block) when the live
  `~/.claude/CLAUDE.md` path is edited -- the warning means "edit
  `claude/CLAUDE.md` in the dotfiles repo instead".
- [WARNING] House style is hook-enforced (see table below). Violations are
  blocked at write or commit time, not merely flagged in review. Emojis and AI
  attribution never pass.
- [WARNING] `format_files.py` runs `prettier --write --ignore-unknown` after
  every file edit in Claude sessions. Markdown gets reflowed -- re-read a doc
  after editing before making a second edit (operating-principles: re-read
  after any formatter pass).

## When NOT to use this skill

| You actually want                                            | Go to                          |
| ------------------------------------------------------------ | ------------------------------ |
| How changes are classified, gated, tested, reviewed          | dotfiles-change-control        |
| Content answers about plugins, config dirs, cloud containers | claude-code-platform-reference |
| Adding or running a test suite                               | dotfiles-validation-and-qa     |
| What may never land in this public repo; licensing decisions | dotfiles-external-positioning  |
| Why a doc says what it says (history, reverts)               | dotfiles-failure-archaeology   |
| Day-to-day operation (update, repair, plugin ops)            | dotfiles-run-and-operate       |

This skill covers WHERE a fact lives, HOW to write it, and WHAT else must be
updated when it changes.

## Docs of record: single home per fact

| Doc                              | Owns (nothing else restates these)                                                                                                             | Edit rules                                                                                      |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `README.md`                      | Human-facing setup (fresh Mac quick start), directory structure, command/agent/skill/hook catalogs, identity routing overview, troubleshooting | Catalogs must track the real surface -- see checklist below                                     |
| `CLAUDE.md` (repo root)          | Claude-session guidance for THIS repo: architecture, symlink targets, cloud restore mechanics, plugin model, commit format                     | The doc Claude reads first; keep terse, keep the symlink-targets list authoritative             |
| `claude/CLAUDE.md`               | Global cross-repo rules: strict rules, response style, commit/branch/Jira conventions, skill routing, plan-mode rules                          | Symlinked to `~/.claude*/CLAUDE.md`; edit the repo file only                                    |
| `claude/operating-principles.md` | Model-agnostic engineering discipline (verify-before-claim, scope/safety, judgment, comms)                                                     | `@import`ed by the last line of `claude/CLAUDE.md`; also symlinked into both config dirs        |
| `codex/AGENTS.md`                | Codex global instructions (lines 1-142); ECC upstream block below the sentinel                                                                 | Hand-edit above `<!-- BEGIN ECC -->` only; refresh the block via `codex-ecc-sync`               |
| `NOTICE`                         | Third-party attribution: ECC rules + pre-commit/pre-push hooks, GSD-redux-derived statusline; MIT notices                                      | Add an entry (paths, upstream URL, license, copyright) whenever anything is vendored or adapted |

Jargon, defined once: "ECC" = Everything Claude Code, a third-party Claude Code
plugin (github.com/affaan-m/ECC). "GSD" = Get Shit Done, a retired third-party
tool whose statusline this repo ported (see NOTICE). "Sentinel block" = the
machine-managed region between `BEGIN ECC`/`END ECC` HTML comments.

## House writing style (hook-enforced)

| Rule                                                                 | Enforced by                                                                                                                                                                                                                        |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No emojis; use `[OK]` `[X]` `[WARNING]` `[INFO]`                     | `claude/hooks/emoji_guard.py` (file edits), `claude/hooks/commit_guard.py` + `git/hooks/commit-msg` (messages)                                                                                                                     |
| No AI attribution anywhere                                           | `claude/hooks/commit_guard.py`, `no_ai_attribution_bash.py`, `no_ai_comments.py`, `git/hooks/commit-msg`                                                                                                                           |
| No secrets in files                                                  | `claude/hooks/block_secrets.py`                                                                                                                                                                                                    |
| Commit messages: no attribution, no AI co-author trailers, no emojis | `git/hooks/commit-msg` (applies to Claude, Codex, and manual commits via `core.hooksPath`) -- this is ALL it checks; the `<scope>: <summary>` format, imperative mood, and <75-char rules are review convention, not hook-enforced |
| Markdown auto-formatted by prettier                                  | `claude/hooks/format_files.py`                                                                                                                                                                                                     |

Convention, not hook-enforced -- still mandatory:

- Commits: `<scope>: <summary>`, imperative mood, <75 chars (claude/CLAUDE.md;
  caught in review, not by any hook).
- Terse, scannable, rationale-carrying. Engineers scan, not read. Tables and
  checklists over prose. Front-load warnings.
- ASCII; `--` for dashes in new content.
- Cite repo files as `path:line`, sparingly -- line numbers drift, so prefer
  stable anchors (function names, headings) and cite lines only where they add
  value.
- Never create new `.md` files unless explicitly instructed
  (claude/CLAUDE.md, Code Standards).
- Cite commit hashes for anything committed (operating-principles.md).

## Templates

### New skill (`claude/skills/<name>/SKILL.md`)

Model: `claude/skills/ship/SKILL.md`. Frontmatter has exactly two keys:

```yaml
---
name: <skill-name>
description: Use when <situation>. Trigger on "<phrase>", "<phrase>". Not for <adjacent case> (use <sibling-skill>).
---
```

The description is the ONLY text the model sees before deciding to load the
skill -- make it trigger-rich (concrete phrases and situations) and
differentiate from siblings. Body: title heading, short purpose paragraph,
terse sections.

[WARNING] Tracking step, load-bearing: `claude/skills/.gitignore` ignores
everything (`/*`) and whitelists specific dirs. A new skill dir is GITIGNORED
until you add a `!/<skill-dir>/` line to that file -- without it, work
silently accumulates on an untracked file (the exact trap
operating-principles.md warns about). Add the line, then verify with
`git ls-files claude/skills/<name>`. Then follow the checklist below (README
skills catalog).

### New slash command (`claude/commands/<name>.md`)

Current style is YAML frontmatter, as in `claude/commands/handoff.md:1-3` and
`kickoff.md`:

```yaml
---
description: <what it does, when to use, one line>
---
# <Name> Command
...
```

The bare-H1 style (`# /commit - Create a commit ...`, `claude/commands/commit.md:1`)
is legacy -- 20 of 22 commands still use it (verified 2026-07-02). Write new
commands in the YAML style; migrate legacy ones opportunistically when already
editing them, not in bulk.

## Update-trigger checklist (the drift preventer)

Run this after ANY surface change. Each row is a required same-PR update.

| You changed                                                | You must also update                                                                                                                                                                                                                             |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Added/renamed/removed a command in `claude/commands/`      | README Commands list (under "Claude Code Configuration")                                                                                                                                                                                         |
| Added a skill under `claude/skills/`                       | README Skills catalog; `!/<skill-dir>/` line in `claude/skills/.gitignore` (dir is otherwise gitignored -- verify with `git ls-files claude/skills/<name>`)                                                                                      |
| Added/changed a Claude hook                                | README Hooks list; registration in `claude/settings.json.tmpl`; expectations in `claude/hooks/claude-hooks.test.sh`; the registration table in claude-code-platform-reference (single home -- change-control and debugging-playbook point to it) |
| Added a test suite (`*.test.sh` or a skill test)           | `SUITES` list in `bin/dotfiles-tests` -- CI runs only the runner, so an unlisted suite NEVER runs in CI (`.github/workflows/tests.yml`)                                                                                                          |
| Added a symlink target                                     | Repo `CLAUDE.md` "Symlink targets" list; README Directory Structure; the relevant link script                                                                                                                                                    |
| Changed `claude/settings.json.tmpl`                        | Announce the manual-merge need in the PR body -- machines seed once and never re-read the template; only cloud reconciles automatically (`bootstrap-cloud.sh` `reconcile_claude_settings`)                                                       |
| Vendored or adapted third-party content                    | `NOTICE` entry: paths, upstream URL, license, copyright                                                                                                                                                                                          |
| Changed cloud restore mechanics                            | Repo `CLAUDE.md` "Cloud sessions" section (the doc of record for that flow)                                                                                                                                                                      |
| Changed a global behavior rule                             | `claude/CLAUDE.md` (repo file) -- and expect it to reach every session in every repo                                                                                                                                                             |
| ECC upstream moved (counts/versions in the sentinel block) | Run `codex-ecc-sync`; never hand-edit the block                                                                                                                                                                                                  |

Quick audit commands:

```bash
ls "$HOME/dotfiles/claude/commands" | sed 's/\.md$//'            # vs README command list
ls -d "$HOME/dotfiles/claude/skills"/*/                          # vs README skills catalog
bash "$HOME/dotfiles/bin/dotfiles-tests" --list                  # vs suites on disk:
grep -rl 'passed, .* failed' "$HOME/dotfiles" --include='*.sh'   #   (runner's own sync-audit hint)
```

(Substitute your checkout path for `$HOME/dotfiles` if cloned elsewhere.)

## Residual known drift (verified 2026-07-02; fix or file, do not re-discover)

1. GSD stance split -- OPEN. `zsh/functions.zsh:760` (commit 9ad4dc8) says
   "GSD is retired... the right move is gsd-uninstall", yet
   `gsd-install`/`gsd-update` in the same file still offer the sanctioned
   community redux fork, and the hand-maintained top of `codex/AGENTS.md`
   ("Codex Backup Mode" section, codex/AGENTS.md:29-35) still describes GSD as
   an active installed surface (`$gsd-*` skills, `~/.claude/get-shit-done/`).
   Reconcile before citing either as authoritative. Ground truth on the
   supply-chain history: the ORIGINAL `get-shit-done-cc` npm package is
   compromised (token rug-pull, publish access retained) and must never be
   reinstalled; only the redux fork is sanctioned (functions.zsh:474-489).
2. ECC sentinel block ages independently -- OPEN by design. The counts inside
   it ("67 specialized agents, 271 skills, 92 commands", "Version: 2.0.0",
   codex/AGENTS.md:146-148) are upstream facts frozen at the last
   `codex-ecc-sync`. Known trap in the refresher: the gitconfig-restore
   `sed -i ''` at zsh/functions.zsh:358 is BSD/macOS-only and fails on Linux.
3. `templates/` (added 8ae7009; contains `templates/python/pyproject.toml`)
   is missing from the README Directory Structure tree.
4. README.md:13 claims a "CLAUDE.md template system" -- CANDIDATE stale:
   `bin/setup-claude` only writes `.git/info/exclude` entries and no CLAUDE.md
   template ships in the repo. Grep for references before deleting the claim
   (Code Cleanup rule in claude/CLAUDE.md).
5. Command frontmatter split: only `handoff.md` and `kickoff.md` use the
   current YAML style; the other 20 commands are legacy H1 (see Templates).
6. `GSD_HOOK_REPAIR`/`GSD_HOOK_ISOLATE` env-flag names in
   `git/hooks/post-checkout` (documented in README "Global Git Hooks") outlived
   the GSD retirement. Functional; naming-only drift.
7. Dropped todo from the deleted `todo.md` (c0a9072): "README Brewfile split
   doc" -- README has an "Adding New Packages" section, but whether it fully
   covers the common-vs-macos Brewfile split was never re-assessed. OPEN.

## Provenance and maintenance

Facts verified against the working tree on 2026-07-02 at commit 26eae6d
(README command list + skills catalog + spec-path fix landed that day; test
runner and CI at 465ee17, same day). Re-verify before trusting:

```bash
git -C "$HOME/dotfiles" log --oneline -3                           # has the repo moved past 26eae6d?
grep -n 'BEGIN ECC\|END ECC' codex/AGENTS.md                       # sentinel bounds (143 / last line today)
grep -n 'GSD is retired' zsh/functions.zsh                         # drift item 1 anchor (line 760 today)
grep -n "sed -i ''" zsh/functions.zsh                              # drift item 2 anchor (line 358 today)
head -3 claude/commands/*.md | grep -c '^description:'             # YAML-style command count (2 today)
ls claude/commands | wc -l                                         # command count (22 today)
bash bin/dotfiles-tests --list | wc -l                             # suite count (9 today)
grep -n 'reconcile_claude_settings' bootstrap-cloud.sh             # cloud settings-merge still exists
grep -rn 'prettier' claude/hooks/format_files.py                   # formatter hook still prettier-based
```

Volatile facts date-stamped above: sentinel line numbers, function line
numbers, command/suite counts, the 20/22 legacy-frontmatter split, and every
entry in "Residual known drift". Line numbers WILL drift -- trust the grep
anchors, not the numbers.
