---
name: dotfiles-validation-and-qa
description: What counts as evidence in the dotfiles repo, the full test-suite inventory with run commands, how to add and register a new test, and the known coverage gaps. Load when asked "how do I run the tests", "is there a test for X", "add a test", "what does this test failure mean", "is this change verified", or before claiming any change is done. Not for diagnosing a live broken machine (dotfiles-debugging-playbook), not for step-by-step proof recipes of symlinks/plugins/identity (dotfiles-verification-toolkit), and not for the change-gating rules themselves (dotfiles-change-control).
---

# Validation and QA

How this repo decides a change is real. Nine standalone shell test suites, one
runner (`bin/dotfiles-tests`), one CI workflow -- plus a house evidence bar that
says test-green is necessary but not sufficient. This skill inventories the
suites, teaches the conventions for adding one, and names the coverage gaps
plainly so nobody mistakes an untested area for a certified one.

## When NOT to use this skill

- Machine is misbehaving and you need triage -- use `dotfiles-debugging-playbook`.
- You need a worked proof recipe (symlink chain, plugin install, identity
  resolution, hook firing) -- use `dotfiles-verification-toolkit`.
- You want the change classification/gating policy and its incident history --
  use `dotfiles-change-control`.
- You want to know what a suite guards ARCHITECTURALLY and why -- use
  `dotfiles-architecture-contract`.
- Public-repo posture questions (what may never land here) -- use
  `dotfiles-external-positioning`; the `public-safety` suite below is its
  enforcement arm.

## The evidence bar

Imported from `claude/operating-principles.md` (loaded into every session);
these are not aspirations, they are the acceptance standard:

| Rule                                    | Meaning here                                                                                                                                                          |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Confirmed vs inferred                   | Label every claim. "Tests pass" is confirmed only after you ran them this session.                                                                                    |
| Exit codes lie                          | `claude plugin install` can exit 0 without installing. Verify state on disk (`~/.claude/plugins/installed_plugins.json`), not return codes. Incident: commit f91d7d2. |
| Verify on-disk before relaying          | Subagent/reviewer self-reports are hypotheses. `git diff` + `grep` the actual files before repeating a claim.                                                         |
| Empty findings = tool-failure signal    | A review or grep returning nothing on a large diff means the tool misfired, not that the diff is clean. Re-run with a known-positive probe.                           |
| Test-green is necessary, not sufficient | Static/grep-based suites pass while runtime behavior is broken. Exercise the changed behavior live (see Acceptance discipline).                                       |
| Baseline first                          | Run `bash bin/dotfiles-tests` BEFORE your first edit and record the verdict line. Regressions are only visible against a baseline.                                    |

## Quick start

```bash
cd ~/dotfiles                    # suites assume repo root; the runner cds there itself
bash bin/dotfiles-tests          # run everything, one verdict, non-zero exit on any failure
bash bin/dotfiles-tests --list   # list suites without running
```

Dependencies: `rg` (ripgrep) for several suites, `jq` + `git` for the skill
suites, `python3` for the settings-drift check. CI installs `zsh` and
`ripgrep` explicitly (`.github/workflows/tests.yml`).

## Test suite inventory

All ten are standalone scripts -- no framework, no shared runner state. Each
prints `PASS`/`FAIL` lines and a final `N passed, M failed` line, exiting
non-zero on any failure. `bin/dotfiles-tests` (bash, added 2026-07-02, commit
465ee17) wraps them with a per-suite verdict and one summary line.

| Suite                                             | Run                                                    | Asserts                                                                                                                                                                                                                                                                                                 | Guards against                                                                     | Failure usually means                                                                                                                                                                                                                                                                      |
| ------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `install/install.test.sh`                         | `sh install/install.test.sh`                           | macOS Brewfile uses `cask "docker-desktop"`, not the renamed `cask "docker"`                                                                                                                                                                                                                            | Homebrew cask-rename drift breaking `brew bundle`                                  | Someone reverted the cask name, or `rg` is missing                                                                                                                                                                                                                                         |
| `zsh/functions.test.sh`                           | `sh zsh/functions.test.sh`                             | Plugin ground-truth helpers: `_claude_ensure_plugin` fails closed when the CLI exits 0 without writing `installed_plugins.json`, fails loudly on unreachable marketplaces, succeeds only when the record lands; static asserts that `ecc-install`/`superpowers-install` route through it                | Regression to trusting `claude` CLI exit codes/output for installs (fence f91d7d2) | Behavioral cases need `zsh` (skipped with a notice when absent; CI installs it); a static-assert failure means the install functions stopped using `_claude_ensure_plugin`                                                                                                                 |
| `claude/hooks/claude-hooks.test.sh`               | `sh claude/hooks/claude-hooks.test.sh`                 | Guard-hook behavior contracts: attribution blocker, emoji guard, `block_secrets.py` segment matching (blocks `.env.local`, allows `.env.example` and `src/secrets_manager/`); PLUS live settings drift -- every existing `~/.claude*/settings.json` must register `account_guard.py` under SessionStart | Hook regressions; hand-merged machine settings silently missing a required hook    | A hook's allow/block contract changed, or a machine's `settings.json` needs a hand-merge from `claude/settings.json.tmpl`. `SKIP settings:` lines are normal on CI/fresh machines                                                                                                          |
| `codex/hooks/codex-hooks.test.sh`                 | `sh codex/hooks/codex-hooks.test.sh`                   | Same contracts for the Codex twin hooks in `codex/hooks/`                                                                                                                                                                                                                                               | Claude/Codex hook parity drift                                                     | The twins diverged -- port the fix both ways (segment matching was backported Claude<-Codex in 52f807d)                                                                                                                                                                                    |
| `codex/skills/codex-skills.test.sh`               | `sh codex/skills/codex-skills.test.sh`                 | Codex skill invariants (files exist, correct reviewer invocations, no nested `codex review`); `install/common/link.sh` sweeps stale plugin-skill snapshots; one functional test runs `link.sh` under a temp `$HOME` to prove duplicate Superpowers plugin entries get `enabled = false`                 | Regression of the abandoned-Codex-mirror cleanup; broken skill wiring              | A skill file or `link.sh` lost a load-bearing line; the dedup test failing means `link.sh` mutated its config.toml logic                                                                                                                                                                   |
| `git/hooks/commit-msg.test.sh`                    | `sh git/hooks/commit-msg.test.sh`                      | Hook blocks attribution footers, forbidden co-author trailers, and emoji in commit messages; allows conventional `scope: Summary`; hook warns visibly when `rg` is absent                                                                                                                               | House commit-style rules bypassed at the git layer                                 | Hook logic changed, or `rg` missing locally                                                                                                                                                                                                                                                |
| `git/hooks/post-checkout.test.sh`                 | `sh git/hooks/post-checkout.test.sh`                   | STATIC ONLY: greps the hook source for structural facts (guards, `ensure_symlink`/`ensure_copy` shape and call-site counts, mode detection, `.todos` hydration ordering)                                                                                                                                | Accidental structural edits to the worktree-hydration hook                         | The hook source shape changed -- update hook and test together. Passing says NOTHING about runtime behavior (open gap, below)                                                                                                                                                              |
| `git/hooks/public-safety.test.sh`                 | `sh git/hooks/public-safety.test.sh`                   | No tracked `todo.md`; no hardcoded local home-directory paths; no high-confidence secret patterns anywhere in the working tree                                                                                                                                                                          | Public-repo leaks (this repo is public)                                            | [WARNING] It scans the WHOLE working tree with `rg --hidden`, including UNTRACKED files -- a scratch file with a home path or key-shaped string fails it even when the tracked tree is clean (confirmed live 2026-07-02). Find the culprit by re-running the suite's `rg` line without `!` |
| `claude/skills/lib/test_work_state.sh`            | `bash claude/skills/lib/test_work_state.sh`            | `work-state.sh` library: canonical repo keys proven against real temp git repos, linked worktrees, submodules, bare repos; config selection; time windows; GitHub gathering via a hermetic `gh` stub (`GH=` env override) including partial-failure, cap/truncation, and auth-down paths                | Regressions in the shared library behind `reconcile`/`weekly`/`brief`              | A `ws_*` function's contract changed. Requires `jq` and network-free `git`                                                                                                                                                                                                                 |
| `claude/skills/todos/scripts/tests/todos_test.sh` | `bash claude/skills/todos/scripts/tests/todos_test.sh` | `todos.sh` CLI end-to-end in throwaway repos: date validation/shifting, frontmatter fields, brief/index ordering, registry dedup, unreadable-file skip                                                                                                                                                  | Cross-session todo backlog corruption                                              | Deterministic via `TODOS_TODAY`/`TODOS_REGISTRY`. The chmod-based unreadable test self-SKIPs under root (root ignores file modes; guard added in 465ee17)                                                                                                                                  |

### The runner and CI

- `bin/dotfiles-tests` -- single entrypoint; suite list lives in its `SUITES`
  variable (`interpreter path` pairs). Exits 1 and names failing suites.
- `.github/workflows/tests.yml` -- on push to `main` and on every PR: zsh
  syntax gate (`zsh -n` over `zsh/*.zsh` and `zsh/scripts/*.zsh`), bash syntax
  gate (`bash -n` over bootstrap/install/bin/hook scripts), python syntax gate
  (`py_compile` over `claude/hooks/*.py codex/hooks/*.py`), then
  `bash bin/dotfiles-tests`. CI is Linux-only (`ubuntu-latest`); nothing
  exercises the macOS-only paths.

## How to add a test

House conventions -- copy an existing suite rather than inventing:

1. **Standalone script.** `#!/bin/sh` + `set -e` for grep/assert suites
   (pattern: `install/install.test.sh`); `#!/usr/bin/env bash` +
   `set -uo pipefail` when you need arrays, `local`, or sourcing a library
   (pattern: `claude/skills/lib/test_work_state.sh`). No bats, no framework.
2. **PASS/FAIL counting with the canonical tail.** Increment `PASS`/`FAIL`
   per assertion, then end with exactly:

   ```sh
   printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
   [ "$FAIL" = 0 ]
   ```

   The final bracket test is the exit code; the `passed, ... failed` line is
   also the audit marker the runner's header comment tells you to grep for.

3. **Self-contained temp fixtures.** `mktemp -d`, clean up via `trap ... EXIT`
   or explicit `rm -rf`. Real throwaway git repos are fine and preferred over
   mocks (see `mk_repo` in `todos_test.sh`, worktree/submodule fixtures in
   `test_work_state.sh`).
4. **Hermetic stubs for external tools.** Never call the network. Pattern:
   the `gh` stub in `test_work_state.sh` -- a generated script matched by
   `case "$*"`, injected via the `GH=` env override the library honors. Same
   idea: temp `$HOME` for the `link.sh` dedup test in `codex-skills.test.sh`.
5. **Attribution-safe string splitting.** Guard hooks scan file content, so a
   test fixture containing a forbidden phrase would block its own commit.
   Build the phrase at runtime: `ATTRIBUTION_SUBJECT="A""I"`,
   `CODEX_NAME="Co""dex"` (see `claude/hooks/claude-hooks.test.sh:6`,
   `git/hooks/commit-msg.test.sh:8`). Emoji fixtures: `printf '%b'` with
   octal escapes, never a literal emoji.
6. **Environment guards, not flaky failures.** If an assertion cannot hold in
   some legitimate environment, detect and print an explicit `SKIP`/`ok (SKIP)`
   line -- root bypassing chmod (`todos_test.sh`), absent live `settings.json`
   (`claude-hooks.test.sh`). Silent skips are forbidden; invisible skips are
   how coverage rots.
7. **Assume repo root.** Suites use repo-relative paths; the runner `cd`s to
   the repo root for you. A suite run by hand must be run from repo root.

**Register it in exactly one place:** add an `interp path` line to `SUITES` in
`bin/dotfiles-tests` (bin/dotfiles-tests:21). Nothing else -- CI calls the
runner, so registration there is registration everywhere. Audit for forgotten
suites: `rg -l 'passed, .* failed' -g '*.sh'` vs `bash bin/dotfiles-tests --list`.
One caveat: the CI _syntax gates_ have their own file globs in
`.github/workflows/tests.yml` -- a new script under `bin/` or a new zsh module
is only syntax-checked if the workflow's list covers it; check when adding
top-level scripts.

## Drift-guard coverage: certified vs open

Certified (a suite fails if it drifts):

- Brewfile Docker cask rename (`install.test.sh`).
- Guard-hook allow/block contracts, Claude and Codex twins, including the
  segment-based secret matcher (52f807d fixed it blocking its own file via
  substring match -- the test now pins the segment behavior).
- `account_guard.py` SessionStart registration in every live `settings.json`.
- Codex skill invariants and the `link.sh` stale-snapshot sweep + plugin dedup.
- commit-msg hook message rules.
- post-checkout hook SOURCE SHAPE (not behavior).
- Public-tree safety (no local paths, no secret patterns, no tracked backlog).
- `work-state.sh` and `todos.sh` runtime behavior.

Open gaps (label them open; do not claim coverage that does not exist):

| Gap                                                                                       | Status                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ECC-vendored `git/hooks/pre-commit` and `git/hooks/pre-push`                              | UNTESTED entirely                                                                                                                                                                 |
| `git/hooks/post-checkout` runtime behavior (actual worktree hydration)                    | Static-shape test only; no runtime exercise                                                                                                                                       |
| `install/install.sh` end-to-end                                                           | No test; CI gives `bash -n` syntax only. `bootstrap-cloud.sh` likewise syntax-only (its `ensure_plugin` self-verifies at runtime, but nothing tests it)                           |
| `settings.json.tmpl` parity on machines                                                   | Only `account_guard.py` registration is drift-checked; any other template change silently misses hand-merged machines (cloud reconciles automatically; machines do not)           |
| Machine-path plugin installs (`ecc-install`/`superpowers-install` in `zsh/functions.zsh`) | CLOSED 2026-07-02: `_claude_ensure_plugin` verifies against `installed_plugins.json` (ported from `bootstrap-cloud.sh` `ensure_plugin`); behavioral suite `zsh/functions.test.sh` |
| macOS-only paths (defaults.sh, op-ssh-sign signing)                                       | CI is Linux-only; nothing exercises them                                                                                                                                          |

## Acceptance discipline

A change is DONE when both hold:

1. `bash bin/dotfiles-tests` exits 0 (and you recorded the pre-change baseline
   to compare against), and
2. the specific behavior you changed was exercised LIVE -- not just its suite.
   Grep-based suites cannot notice a behavioral bug that keeps the grepped
   strings intact. For the how (prove a symlink resolved, a plugin actually
   installed, a hook actually fired), use `dotfiles-verification-toolkit`.

Close every change report by naming what is still unverified and why. If a
change touches an open-gap area above (e.g. post-checkout runtime), say so
explicitly -- test-green there is close to meaningless.

## Provenance and maintenance

Facts verified live on 2026-07-02. Volatile items and their re-checks:

| Fact (as of 2026-07-02)                                                                                                                            | Re-verify                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| 10 suites in the runner                                                                                                                            | `bash bin/dotfiles-tests --list`                                                                                                                   |
| Baseline: all suites pass (any `public-safety` failure -- tracked OR untracked content -- is a stop-the-line defect, never an acceptable baseline) | `git status --short && bash bin/dotfiles-tests`                                                                                                    |
| Runner + CI added commit 465ee17 (2026-07-02)                                                                                                      | `git show 465ee17 --stat`                                                                                                                          |
| Secret-matcher segment fix + its tests: 52f807d                                                                                                    | `git show 52f807d --stat`                                                                                                                          |
| Exit-codes-lie incident (plugin install exit 0 without installing): f91d7d2                                                                        | `git show f91d7d2 --stat`                                                                                                                          |
| CI triggers: push to main + all PRs, ubuntu-latest                                                                                                 | `sed -n '1,15p' .github/workflows/tests.yml`                                                                                                       |
| Suite registration point is `SUITES` in the runner                                                                                                 | `sed -n '19,31p' bin/dotfiles-tests`                                                                                                               |
| No suite left unregistered                                                                                                                         | diff `rg -l 'passed, .* failed' -g '*.sh'` against `--list` output                                                                                 |
| `ensure_plugin` gold standard location                                                                                                             | `rg -n 'ensure_plugin\(\)' bootstrap-cloud.sh`                                                                                                     |
| Open gaps table still open                                                                                                                         | re-run the gap checks: `ls git/hooks/`, `rg -n '_claude_ensure_plugin' zsh/functions.zsh`, `rg -n account_guard claude/hooks/claude-hooks.test.sh` |

Line-number citations (`bin/dotfiles-tests:21`, `bootstrap-cloud.sh:107`,
`claude-hooks.test.sh:6`, `commit-msg.test.sh:8`) drift with edits; the
anchors (`SUITES`, `ensure_plugin`, `ATTRIBUTION_SUBJECT`, `CODEX_NAME`) are
stable -- prefer them.
