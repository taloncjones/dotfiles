---
name: dotfiles-research-frontier
description: The open-problems map for this repo -- where it can advance beyond what chezmoi/stow-class dotfiles tools do (they manage files; this repo manages an AGENT operating environment). Load when asked "what should we work on next", "what are the big open problems", "where is this repo ahead of / behind the state of the art", "is there a research angle here", or when scoping a new improvement slice and you need the ratified priority list with first steps and falsifiable milestones. Each problem names its existing repo asset, three concrete first steps, and the exact measuring command that decides success. NOT the executable cloud runbook (dotfiles-cloud-first-campaign), NOT the evidence-bar discipline for landing a change (dotfiles-research-methodology), NOT settled history (dotfiles-failure-archaeology).
---

# Dotfiles research frontier

The five open problems, user-ratified in priority order, where this repo can go
beyond typical dotfiles practice. Common tools (chezmoi, stow, yadm) solve file
placement; this repo's actual product is a reproducible operating environment
for AI agents -- plugins, hooks, guard rails, identity routing, and tests that
hold on ephemeral containers as well as real machines. Every problem below
states why the common approach falls short, the asset this repo already has,
the first three steps IN THIS REPO, and a falsifiable "you have a result
when ..." milestone with its measuring command. No milestone is "looks fine".

[WARNING] This skill is a map, not a license to improvise. Any change these
problems motivate still goes through the normal gates -- worktree, tests
(`bin/dotfiles-tests`), hooks, PR review (see dotfiles-change-control). Run
hunches through dotfiles-research-methodology before they become diffs.

## When NOT to use this skill

| You actually want                                                | Use instead                      |
| ---------------------------------------------------------------- | -------------------------------- |
| Execute the cloud-parity work step by step (problem 1's runbook) | dotfiles-cloud-first-campaign    |
| The discipline for turning a hunch into an accepted change       | dotfiles-research-methodology    |
| What already failed and must not be re-fought                    | dotfiles-failure-archaeology     |
| Diagnose a sick container or machine right now                   | dotfiles-diagnostics-and-tooling |
| How the repo is designed and which invariants must hold          | dotfiles-architecture-contract   |
| Land a change through hooks/tests/review                         | dotfiles-change-control          |
| What may never appear in this PUBLIC repo                        | dotfiles-external-positioning    |

## Vocabulary (once)

- **Cloud container**: the ephemeral VM claude.ai/code creates per environment;
  `~/.claude` dies with it. Detected by `CLAUDE_CODE_REMOTE=true`.
- **Declaration**: the committed `.claude/settings.json` block
  (`enabledPlugins` + `extraKnownMarketplaces`) the platform reads pre-launch
  to install plugins natively on session 1.
- **cloud-doctor**: the read-only end-to-end container verifier at
  `.claude/skills/dotfiles-diagnostics-and-tooling/scripts/cloud-doctor.sh`;
  exits 1 on any `[X]` check.
- **Machine-local file**: seeded once from a tracked template by
  `seed_machine_local_file` (`install/common/claude-links.sh`), then never
  auto-updated -- e.g. `~/.claude/settings.json`, `~/.gitconfig-work`.
- **Drift**: live state diverging from what the repo declares (edited settings,
  moved symlink, stale template merge).

## Problem 1 -- zero-touch cloud sessions (status: mostly solved for THIS repo; open for rollout)

**Gap in common practice.** Dotfiles tools assume a persistent `$HOME` and a
human running an install command. Ephemeral containers invert both: state dies
per environment, and anything a human must paste per environment does not
scale. Typical answer is "run my bootstrap in the setup field" -- which is
exactly the per-environment paste this problem eliminates.

**This repo's asset.** The committed `.claude/settings.json` declaration
(pre-launch, works session 1 -- the settled fix, commit `8d4507f`), the
self-healing SessionStart hook (`.claude/hooks/session-start.sh` ->
`bootstrap-cloud.sh` with its `ensure_plugin` / `reconcile_claude_settings`
functions), and cloud-doctor as the measuring instrument.

**First three steps in this repo:**

1. Baseline: in a fresh dotfiles cloud environment with an EMPTY Setup script,
   run cloud-doctor in session 1 and record the exact output.
2. Close whatever `[X]` remains without touching the Setup script -- fixes must
   land in committed pre-launch surface (`.claude/settings.json`) or the
   self-heal hook, never in per-environment config.
3. Roll out: extract the minimal declaration block other repos need and
   document the copy into their `.claude/settings.json` (execution runbook:
   dotfiles-cloud-first-campaign).

**You have a result when** a fresh cloud environment with no Setup script and
nothing pasted passes on the first session:

```bash
bash .claude/skills/dotfiles-diagnostics-and-tooling/scripts/cloud-doctor.sh; echo "exit=$?"
```

Expected: `exit=0` in session 1.

## Problem 2 -- agent-first dotfiles (status: open)

**Gap in common practice.** Dotfiles READMEs are written for humans; an
unattended Sonnet-class session cannot execute "just run the installer and
check it worked" -- it needs deterministic scripts, machine-checkable success
criteria, and hook-enforced guard rails so mistakes are blocked, not merely
discouraged.

**This repo's asset.** This 16-skill library (zero-context runbooks with
copy-pasteable commands), the guard hooks in `claude/hooks/` (emoji, secrets,
AI-attribution, commit-format -- exit 2 blocks the action), deterministic
verifiers with real exit codes (`bin/identity-doctor`, `bin/dotfiles-tests`,
cloud-doctor, `.claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh`),
and CI as the final arbiter.

**First three steps in this repo:**

1. Define the benchmark task set in writing: (a) fresh-environment verify,
   (b) drift repair (`bin/dotfiles-repair` path), (c) add-a-package PR
   (`install/common/Brewfile.rb` change through the full gate chain).
2. Dry-run each task yourself using ONLY the skills as instructions; every
   place you fall back to memory of the repo is a skill defect -- fix the skill,
   not the run.
3. Run a Sonnet-class session on the task set hands-off; log every human
   intervention as a defect with the skill file that should have prevented it.

**You have a result when** a Sonnet-class session completes all three tasks
with zero human course-corrections and the gates pass:

```bash
bin/dotfiles-tests; echo "exit=$?"      # plus: PR opens, CI green, no hook blocks overridden
```

Expected: `exit=0` and a reviewable PR produced without human edits.

## Problem 3 -- drift-proof reproducibility (status: open; partial coverage exists)

**Gap in common practice.** Dotfiles drift is normally caught by eye ("my
prompt looks wrong") or never. Seed-once machine-local files make it
structural here: `claude/settings.json.tmpl` changes never reach existing
machines automatically (`seed_machine_local_file` prints re-seed instructions
and moves on), and the machine-path plugin installers still trust
`claude plugins list` output (`zsh/functions.zsh`, the `grep -q "ecc@ecc"`
checks) rather than `installed_plugins.json` -- the ground truth
`bootstrap-cloud.sh`'s `ensure_plugin` already uses.

**This repo's asset.** Nine drift-guard test suites under one runner
(`bin/dotfiles-tests`, `--list` to enumerate), CI (`.github/workflows/tests.yml`,
currently push-to-main + PR only), the doctors (identity, cloud, symlink-audit),
and a working partial-parity precedent: `claude/hooks/claude-hooks.test.sh`
already fails when a live `settings.json` misses a required SessionStart hook.

**First three steps in this repo:**

1. Machine-side settings reconcile: port `bootstrap-cloud.sh`
   `reconcile_claude_settings` (merge template keys into live settings without
   clobbering plugin-written keys) into the machine install path so `update`
   closes template drift instead of printing instructions.
2. Scheduled CI: add a `schedule:` cron trigger to
   `.github/workflows/tests.yml` so drift-guard suites run without waiting for
   a push.
3. Template-parity check: extend the settings test beyond SessionStart hooks
   to assert every hook/key in `claude/settings.json.tmpl` exists in each live
   settings file.

**You have a result when** an induced drift -- delete a hook entry from live
`~/.claude/settings.json`, or replace a symlink with a copy -- is flagged by
tooling on the very next run, with no human eyeballing:

```bash
bin/dotfiles-tests; echo "exit=$?"      # settings drift
bash .claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh  # symlink drift
```

Expected: non-zero exit naming the induced drift, within one run of inducing it.

## Problem 4 -- private overlay without losing the public bootstrap (status: open candidate)

**Gap in common practice.** The usual choices are a fully private dotfiles repo
(loses the public cloud bootstrap -- containers clone without a GitHub grant
precisely BECAUSE this repo is public, per CLAUDE.md) or secrets-in-repo
(forbidden here: `claude/hooks/block_secrets.py`, `git/hooks/public-safety.test.sh`).
The unsolved middle: personal-but-not-secret state (employer hostnames, work
git identity, host aliases) that today is re-typed per machine via
`bin/identity-setup`.

**This repo's asset.** The machine-local-file pattern is already the overlay
seam: `~/.gitconfig-work`, `~/.ssh/config_local`, work SSH pubkey are all
consumed by tracked config via includes but never tracked themselves. And
`bin/setup-claude` shows the local-overlay precedent (`.git/info/exclude`).
An overlay only has to POPULATE files the public repo already points at --
no tracked file changes required.

**First three steps in this repo:**

1. Define the boundary in writing: overlay may only create/populate the
   already-machine-local files (`bin/identity-doctor` enumerates the chain);
   it may never shadow or patch a tracked file. Get the boundary ratified
   before any code.
2. Smallest experiment: hand-build a private repo containing just
   `.gitconfig-work` + `config_local` + an `apply.sh` that copies them into
   place, and run `bin/identity-doctor` after applying on a scratch machine.
3. If the experiment holds, add an optional hook in the install flow (env var
   pointing at the overlay repo; skipped silently when unset) -- public
   bootstrap must remain byte-identical in behavior when no overlay is set.

**You have a result when** a fresh machine plus the overlay repo passes
identity verification with zero interactive wizard steps:

```bash
bin/identity-doctor; echo "exit=$?"
```

Expected: `exit=0` without `bin/identity-setup` having been run interactively.
Open until the boundary is ratified -- do not build past step 2 without it.

## Problem 5 -- work-account cloud parity (status: open; platform dependency unresolved)

**Gap in common practice.** Nobody's dotfiles handle two agent accounts in one
ephemeral container. This repo solved dual accounts on machines (the `claude()`
wrapper and `claude-account` in `zsh/functions.zsh` route `~/Git/work` launches
to `~/.claude-work`), but cloud containers are personal-account only:
`bootstrap-cloud.sh` hardcodes `$HOME/.claude` (5 occurrences, no
`CLAUDE_CONFIG_DIR` support), and cloud-doctor merely defaults to `~/.claude`
while documenting the limitation.

**This repo's asset.** The dual-config-dir architecture already exists and is
symmetric by construction: `link_claude_config_dir`
(`install/common/claude-links.sh`) builds both dirs from one asset source, and
cloud-doctor already respects `CLAUDE_CONFIG_DIR`.

**First three steps in this repo:**

1. Resolve the platform question FIRST: determine whether claude.ai/code
   containers can run under a second account/config dir at all. If the
   platform cannot, this problem is blocked upstream -- record that and stop.
2. Parameterize `bootstrap-cloud.sh` on `CLAUDE_CONFIG_DIR` (replace the
   hardcoded `$HOME/.claude` paths), keeping personal as the default so
   current behavior is unchanged.
3. Define the work-identity story for containers: what subset of
   `~/.gitconfig-work` may exist in an ephemeral VM (never the 1Password
   signing block -- fence: commit `2304015`), likely via the problem-4 overlay.

**You have a result when** a work-account container passes the same gate the
personal path already passes:

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-work" \
  bash .claude/skills/dotfiles-diagnostics-and-tooling/scripts/cloud-doctor.sh; echo "exit=$?"
```

Expected: `exit=0` in session 1 of a work-account container. Blocked-on-platform
until step 1 answers yes; do not oversell partial progress.

## Working the frontier -- standing rules

- Milestones are the contract: a problem moves to "solved" ONLY when its
  measuring command produces the expected output, captured in the PR.
- Label claims: confirmed (command output in hand) vs inferred vs open. This
  file itself marks problems 4 and 5 open -- keep it that way until the
  commands say otherwise.
- Check dotfiles-failure-archaeology before proposing anything cloud- or
  plugin-shaped; the wrong paths are catalogued with commit hashes.
- When a problem's status changes, update THIS file in the same PR as the
  change that moved it.

## Provenance and maintenance

Facts verified against the repo on 2026-07-02. Volatile items and how to
re-verify:

| Fact (as of 2026-07-02)                                                   | Re-verify with                                                                              |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| cloud-doctor path and exit-1-on-failure behavior                          | `head -20 .claude/skills/dotfiles-diagnostics-and-tooling/scripts/cloud-doctor.sh`          |
| `.claude/settings.json` declares both plugins + SessionStart hook         | `cat .claude/settings.json`                                                                 |
| 9 test suites; runner exists                                              | `bin/dotfiles-tests --list`                                                                 |
| CI triggers are push-to-main + PR only (no `schedule:` yet)               | `grep -n -A4 '^on:' .github/workflows/tests.yml`                                            |
| Machine installers grep `claude plugins list`, not installed_plugins.json | `grep -n 'plugins list' zsh/functions.zsh`                                                  |
| `bootstrap-cloud.sh` hardcodes `$HOME/.claude` (no CLAUDE_CONFIG_DIR)     | `grep -c '\$HOME/.claude' bootstrap-cloud.sh; grep -c CLAUDE_CONFIG_DIR bootstrap-cloud.sh` |
| Settings drift test covers SessionStart hooks only                        | `grep -n 'Settings drift' -A8 claude/hooks/claude-hooks.test.sh`                            |
| identity-doctor exits 1 on failures                                       | `tail -8 bin/identity-doctor`                                                               |
| Incident hashes cited (8d4507f, 2304015)                                  | `git show <hash> --stat`                                                                    |
| Problem statuses (1 mostly solved; 2-3 open; 4-5 open/blocked)            | run each problem's measuring command above                                                  |
