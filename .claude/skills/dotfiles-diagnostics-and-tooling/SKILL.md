---
name: dotfiles-diagnostics-and-tooling
description: Use when you need to MEASURE the state of a dotfiles machine or cloud container instead of eyeballing it -- interpreting identity-doctor output, running/reading bin/dotfiles-tests, inspecting plugin state (installed_plugins.json, known_marketplaces.json), diffing live settings.json against the template, or running this skill's cloud-doctor.sh / symlink-audit.sh scripts. Trigger phrases -- "is this environment healthy", "why did identity-doctor fail", "which test suite broke", "are the plugins actually installed", "did settings drift", "audit the symlinks". NOT for fixing what you find (dotfiles-run-and-operate), rebuilding from scratch (dotfiles-build-and-env), debugging a specific symptom (dotfiles-debugging-playbook), or single-fact verification recipes (dotfiles-verification-toolkit).
---

# Dotfiles diagnostics and tooling

Measure instead of eyeball. This repo ships read-only doctors, an aggregate
test runner, and on-disk state files that answer "is this machine healthy?"
deterministically. This skill is the interpretation guide for each tool plus
two executable doctors in `scripts/` for the cases the built-ins do not cover
(cloud sessions, full symlink audits).

[WARNING] Every tool here is read-only EXCEPT `bin/dotfiles-repair` (mutates
symlinks, may pull main). Never trust `claude plugins install` exit codes --
the on-disk ground truth is `installed_plugins.json` (see Plugin-state
inspection below; incident history in dotfiles-failure-archaeology).

## When NOT to use this skill

| You want to...                                                 | Use instead                   |
| -------------------------------------------------------------- | ----------------------------- |
| Fix what a doctor found (relink, reinstall plugins, update)    | dotfiles-run-and-operate      |
| Rebuild a machine/container from nothing                       | dotfiles-build-and-env        |
| Triage a symptom ("hook not firing", "wrong identity")         | dotfiles-debugging-playbook   |
| One-off proof recipe (a single symlink chain, one hook firing) | dotfiles-verification-toolkit |
| Know what counts as evidence / add a test                      | dotfiles-validation-and-qa    |
| Understand why the exit-code-lies design exists                | dotfiles-failure-archaeology  |

## Tool inventory

| Tool                                         | Scope                              | Mutates? | Exit semantics                    |
| -------------------------------------------- | ---------------------------------- | -------- | --------------------------------- |
| `bin/identity-doctor` (alias `git identity`) | git/SSH/Claude identity chain      | No       | 1 if any `[X]`                    |
| `bin/dotfiles-tests`                         | all nine test suites               | No       | 1 if any suite fails              |
| `bin/dotfiles-repair`                        | symlinks, settings size, GSD check | YES      | non-zero on hard error (`set -e`) |
| `scripts/cloud-doctor.sh` (this skill)       | cloud/ephemeral session health     | No       | 1 if any `[X]`                    |
| `scripts/symlink-audit.sh` (this skill)      | full expected symlink map          | No       | 1 if any non-OK entry             |
| `claude plugin list` / state JSONs           | plugin install truth               | No       | n/a                               |

## identity-doctor interpretation

Run: `identity-doctor` (or `git identity` from any repo). Source:
`bin/identity-doctor`. Sections in output order:

| Section         | Checks                                                                                                            | `[X]` means                                                                                                      | `[WARNING]` means                                                                                                                |
| --------------- | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| dotfiles links  | `~/.gitconfig`, `~/.gitconfig-personal`, `~/.ssh/config` are resolving symlinks                                   | dangling or missing link -- re-run link.sh                                                                       | path exists but is a real file (unmanaged; a prior manual copy shadows the repo)                                                 |
| git identity    | `~/.gitconfig-work` is machine-local; `user.useConfigOnly=true`                                                   | work config is a SYMLINK into the repo (leaks employer values), or useConfigOnly off (silent guessed identities) | work config missing/empty -- commits under `~/Git/work` refused until `identity-setup` runs (expected on personal-only machines) |
| ssh keys        | 1Password agent socket, `agent.toml`, both pubkeys, `ssh -G` pinning                                              | personal pubkey missing, or `ssh -G github.com`/`Git-work` would offer the WRONG key                             | agent socket absent (1Password not running), work pubkey absent (`[INFO]` -- expected on personal-only machines)                 |
| current repo    | resolved `user.email` matches the `~/Git/{personal,work}` path convention; remote routes via the right host alias | identity mismatch or NO resolved email inside a convention dir                                                   | repo outside convention dirs but has an identity (repo-local override?), or work remote not rewritten to `Git-work`              |
| claude accounts | which config dir a `claude` launch here uses; both dirs exist                                                     | --                                                                                                               | `CLAUDE_CONFIG_DIR` exported (overrides directory routing for EVERY launch)                                                      |
| gh              | `gh auth status`                                                                                                  | --                                                                                                               | installed but unauthenticated                                                                                                    |

Key discriminations: `[X]` = broken invariant, fails the run. `[WARNING]` =
degraded but by-design-possible. `[INFO]` = expected on some machine classes.
"repo outside ~/Git/{personal,work} refuses to commit" is `[INFO]` -- that loud
failure IS the design (`user.useConfigOnly`, see dotfiles-architecture-contract).

## dotfiles-tests: the suites

Run: `bin/dotfiles-tests` (what CI `.github/workflows/tests.yml` runs).
List without running: `bin/dotfiles-tests --list`. Each suite prints its own
PASS/FAIL lines; the runner adds per-suite verdicts and a summary.

| Suite                                             | What a failure means                                                                                                                                                                                                                                                          |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `install/install.test.sh`                         | Brewfile regressions (e.g. renamed `docker` cask). Static `rg` asserts -- needs ripgrep on PATH.                                                                                                                                                                              |
| `claude/hooks/claude-hooks.test.sh`               | A guard hook stopped blocking (or started over-blocking) its payload class -- hooks are RUN with real payloads -- OR live `~/.claude*/settings.json` drifted from the template (missing SessionStart hook = "hand-merge required"; see Settings drift below).                 |
| `codex/hooks/codex-hooks.test.sh`                 | Codex twin of the guard hooks regressed.                                                                                                                                                                                                                                      |
| `codex/skills/codex-skills.test.sh`               | Repo-managed Codex bridge skills malformed.                                                                                                                                                                                                                                   |
| `git/hooks/commit-msg.test.sh`                    | Commit-message guard regressed (attribution phrases, AI co-author trailers, emoji -- the hook does NOT check scope/length format; that is review convention).                                                                                                                 |
| `git/hooks/post-checkout.test.sh`                 | Static-shape assertions over the worktree-hydration hook source failed. [WARNING] static-only -- passing does NOT prove runtime behavior (known gap).                                                                                                                         |
| `git/hooks/public-safety.test.sh`                 | Public-repo safety tripped: tracked `todo.md`, a hardcoded local user home path, or a secret-shaped string ANYWHERE in the working tree (`rg --hidden`, so untracked files under `.claude/` count). Find the culprit with the failing suite's own `rg` pattern minus the `!`. |
| `claude/skills/lib/test_work_state.sh`            | Shared work-state library for skills broke.                                                                                                                                                                                                                                   |
| `claude/skills/todos/scripts/tests/todos_test.sh` | todos skill scripts broke (deterministic via `TODOS_TODAY`/`TODOS_REGISTRY`).                                                                                                                                                                                                 |

`[X] MISSING <path>` from the runner means a suite file was moved/deleted --
update the `SUITES` list in `bin/dotfiles-tests` (audit:
`grep -rl 'passed, .* failed'`).

Baseline (2026-07-02): all 9 suites pass. A `public-safety` failure is NEVER
an acceptable baseline -- it is a stop-the-line defect on a public repo; find
the offending content with the failing suite's own `rg` pattern and fix it
before any push.

## dotfiles-repair as a diagnostic

`bin/dotfiles-repair` mutates, but its five steps report state you can read
even when you let it run (each step is idempotent):

| Step         | Reports                                                                   | Diagnostic value                                                                                |
| ------------ | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 1/5 pull     | "not on main" / "local changes; skipping pull"                            | tells you the checkout is dirty or on a branch before anything else runs                        |
| 2/5 re-link  | runs platform `link.sh`                                                   | `[claude-links] Backed up pre-existing ...` lines reveal real dirs that were shadowing symlinks |
| 3/5 settings | `settings.json` size vs template (flags <50% of template size)            | tiny file = something rewrote it through a stale symlink, dropping plugin/hook config           |
| 4/5 GSD      | compromised `get-shit-done-cc` reappearance (command, npm -g, skill dirs) | supply-chain tripwire; if flagged, run `gsd-uninstall` (see dotfiles-external-positioning)      |
| 5/5 verify   | `~/.gitconfig` and one codex hook symlink resolve                         | quick post-fix smoke                                                                            |

Diagnose-only alternative: this skill's `symlink-audit.sh` covers step 2/5's
domain read-only and per-entry.

## Plugin-state inspection

Ground truth is on disk under `$CLAUDE_CONFIG_DIR/plugins/` (default
`~/.claude/plugins/`). NEVER conclude from an install command's exit 0 --
`claude plugins install` can no-op with exit 0 when a marketplace manifest is
not warm yet (commits 722c653, 7cb28b7; full story in
dotfiles-failure-archaeology).

| File / path                                                   | Truth it holds                                                                                                         |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `plugins/installed_plugins.json`                              | THE install record: plugin id -> version, installPath, gitCommitSha. Absent id = not installed, whatever the CLI said. |
| `plugins/known_marketplaces.json`                             | registered marketplaces: source URL, installLocation, lastUpdated                                                      |
| `plugins/marketplaces/<name>/.claude-plugin/marketplace.json` | the resolver's manifest -- a plugin must be listed here before install can succeed                                     |
| `plugins/cache/<marketplace>/<plugin>/<version>/`             | the installed payload itself                                                                                           |

```bash
# The two dotfiles-required plugins, straight from ground truth:
grep -E '"(ecc@ecc|superpowers@claude-plugins-official)"' ~/.claude/plugins/installed_plugins.json

# CLI views (convenient, but derived):
claude plugin list            # installed + enabled status (also: list --json)
claude plugin marketplace list
claude plugin marketplace update <name>   # force a manifest refresh

# Is the plugin even resolvable yet? (the wait condition bootstrap-cloud polls)
grep '"name"' ~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json | head
```

CLI verbs (from `claude plugin --help`, 2026-07-02): `details, disable,
enable, eval, init|new, install|i, list,
marketplace {add,list,remove,update}, prune|autoremove, tag,
uninstall|remove, update, validate`. Machine installs go through the zsh functions `ecc-install` /
`superpowers-install` (`zsh/functions.zsh`), which maintain BOTH config dirs;
cloud installs go through `bootstrap-cloud.sh` `ensure_plugin` -- the gold
standard because it verifies against `installed_plugins.json`.

## Settings drift inspection

`settings.json` is machine-local per config dir, seeded ONCE from
`claude/settings.json.tmpl` (`seed_machine_local_file` in
`install/common/claude-links.sh`). Template changes do NOT propagate to
existing machines -- manual merge required (known open weak point; cloud
reconciles automatically via `reconcile_claude_settings` in
`bootstrap-cloud.sh`, machines do not).

This is the CANONICAL drift script for the library (both config dirs, nested
plugin-key logic); dotfiles-verification-toolkit Recipe 6 defers to it.

```bash
# Key-by-key drift: which top-level keys differ between live and template?
python3 - <<'PY'
import json, os
tmpl = json.load(open(os.path.expanduser("~/dotfiles/claude/settings.json.tmpl")))
for cdir in ("~/.claude", "~/.claude-work"):
    p = os.path.expanduser(cdir + "/settings.json")
    if not os.path.isfile(p):
        print(f"[INFO] {p}: absent"); continue
    live = json.load(open(p))
    for k in sorted(set(tmpl) | set(live)):
        if k in ("enabledPlugins", "extraKnownMarketplaces"):
            missing = set(tmpl.get(k, {})) - set(live.get(k, {}))
            if missing: print(f"[WARNING] {p}: {k} missing template entries: {sorted(missing)}")
        elif tmpl.get(k) != live.get(k):
            tag = "live-only" if k not in tmpl else ("missing" if k not in live else "differs")
            print(f"[WARNING] {p}: {k} {tag}")
PY
```

Interpretation: `enabledPlugins`/`extraKnownMarketplaces` are OWNED by plugin
installers -- live extras there are normal; only template entries MISSING from
live are drift. Everything else (hooks, statusLine, permissions, env)
differing means a hand-merge was missed. `claude/hooks/claude-hooks.test.sh`
enforces the highest-stakes slice of this (SessionStart hooks present) but not
full-key equality. Adjust the `~/dotfiles` path to your checkout.

## Skill scripts

Both are bash, `set -u`, read-only, self-locating (derive the repo root from
their own path; `symlink-audit.sh` accepts a `DOTFILES=` override).

### scripts/cloud-doctor.sh

End-to-end health of a cloud/ephemeral session: `~/.claude` assets link into a
real dotfiles checkout, `settings.json` is machine-local with SessionStart
hooks (`account_guard.py`), both plugins in `installed_plugins.json`, git
author is not the platform default `Claude <noreply@anthropic.com>`, and
python3/node are on PATH. Exit 1 on any `[X]`.

```bash
.claude/skills/dotfiles-diagnostics-and-tooling/scripts/cloud-doctor.sh
```

Captured in this cloud container, 2026-07-02 (abridged):

```
--- claude assets (/root/.claude) ---
[OK]      CLAUDE.md links into dotfiles checkout at /home/user/dotfiles
[OK]      operating-principles.md -> /home/user/dotfiles/claude/operating-principles.md
...
--- settings.json ---
[OK]      SessionStart hooks registered: account_guard.py
--- plugins ---
[OK]      ecc@ecc recorded in installed_plugins.json
[OK]      superpowers@claude-plugins-official recorded in installed_plugins.json
--- git identity ---
[OK]      git author: Talon Jones <taloncjones@gmail.com>
--- runtimes ---
[OK]      python3 on PATH (/usr/local/bin/python3)
[OK]      node on PATH (/opt/node22/bin/node)

cloud-doctor: all checks passed.
```

`[X] git author is still the platform default` = `reattribute_git_identity`
never ran -- commits would be misattributed to the platform seed identity
(incident: commit 2304015).

### scripts/symlink-audit.sh

Walks the expected symlink map transcribed from `install/common/link.sh` and
`link_claude_config_dir` in `install/common/claude-links.sh`. Per entry:
`OK | WRONG-TARGET | DANGLING | NOT-A-LINK | MISSING`; machine-local files
(`settings.json`, `~/.gitconfig-work`) are checked inversely (`IS-A-LINK` is
the failure). `--cloud` restricts to the partial layout bootstrap-cloud.sh
creates (only `~/.claude`).

```bash
.claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh          # full machine
.claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh --cloud  # container
```

Captured in this cloud container, 2026-07-02:

```
symlink-audit: dotfiles root = /home/user/dotfiles  (mode: cloud)

--- claude config dir: /root/.claude ---
[OK] OK            /root/.claude/CLAUDE.md
[OK] OK            /root/.claude/operating-principles.md
[OK] OK            /root/.claude/commands
[OK] OK            /root/.claude/agents
[OK] OK            /root/.claude/hooks
[OK] OK            /root/.claude/skills
[OK] OK            /root/.claude/rules
[OK] OK            /root/.claude/statusline.js
[OK] OK            /root/.claude/settings.json (machine-local file)

symlink-audit: all 9 entries OK.
```

Full mode on the same container correctly reports the zsh/git/ssh/codex and
`~/.claude-work` entries MISSING/NOT-A-LINK -- expected, since
bootstrap-cloud.sh deliberately installs only the Claude layer. On a real
machine, any non-OK line in full mode is actionable: `WRONG-TARGET`/`DANGLING`
usually means a deleted or moved sibling dotfiles checkout was the old target
(the exact rot `dotfiles-repair` step 2/5 fixes).

If the symlink map in `link.sh`/`claude-links.sh` changes, update this
script's entry list -- it is a transcription, not a parser.

## Provenance and maintenance

All facts verified against the working tree and live container on 2026-07-02.
Volatile facts and how to re-verify:

| Fact (as of 2026-07-02)                                                  | Re-verify                                                                                                                                                             |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nine test suites in the runner                                           | `bin/dotfiles-tests --list`                                                                                                                                           |
| CI runs the runner                                                       | `grep dotfiles-tests .github/workflows/tests.yml`                                                                                                                     |
| identity-doctor sections/labels                                          | `grep -n 'section ' bin/identity-doctor`                                                                                                                              |
| repair's five steps                                                      | `grep -n 'step "' bin/dotfiles-repair`                                                                                                                                |
| plugin CLI verbs                                                         | `claude plugin --help; claude plugin marketplace --help`                                                                                                              |
| plugin state paths                                                       | `ls ~/.claude/plugins/`                                                                                                                                               |
| required plugin ids (ecc@ecc, superpowers@claude-plugins-official)       | `grep ensure_plugin bootstrap-cloud.sh`                                                                                                                               |
| template-vs-live drift checker coverage                                  | `sed -n '80,110p' claude/hooks/claude-hooks.test.sh`                                                                                                                  |
| symlink map (script transcription)                                       | `diff <(grep 'ln -sf' install/common/link.sh) <(grep check_link .claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh)` -- eyeball, formats differ |
| baseline (all suites pass; any public-safety failure is stop-the-line) | `bin/dotfiles-tests`                                                                                                                                                  |
| platform default author email `noreply@anthropic.com`                    | `grep PLATFORM_DEFAULT_EMAIL bootstrap-cloud.sh`                                                                                                                      |

Update triggers: adding/removing a test suite, renaming a doctor, changing the
symlink map, template key changes, or a new plugin becoming dotfiles-required.
