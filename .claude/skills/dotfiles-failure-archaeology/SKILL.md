---
name: dotfiles-failure-archaeology
description: Chronicle of every settled investigation, dead end, and revert in this dotfiles repo, with commit hashes and lessons -- load BEFORE re-investigating anything that smells already-decided. Trigger on "why was X removed", "has this been tried before", "why doesn't the SessionStart hook install plugins", "should we re-add tiered orchestration / a per-task Codex gate", "can we reinstall gsd / get-shit-done", "why are ECC rules untracked", "why not mirror plugins into ~/.codex", or any proposal to revert a revert. For live symptom triage use dotfiles-debugging-playbook; for how changes are gated use dotfiles-change-control; for current design rationale use dotfiles-architecture-contract.
---

# Dotfiles Failure Archaeology

Append-only memory of settled battles in github.com/taloncjones/dotfiles.
Each saga records symptom -> root cause -> evidence -> resolution -> status, so
a zero-context engineer or model never re-fights a fight that already has a
verdict. Every hash below was verified with `git show <hash> --stat` on
2026-07-02; re-verify before acting on one.

**Check here first.** Before proposing to add, remove, or "fix" anything that
touches cloud plugin bootstrap, orchestration skills, ECC rule vendoring,
Codex asset mirroring, GSD, or the secret-blocking hook: scan the table below.
If your idea matches a settled saga, read that saga's Lesson before writing a
line of code. Reverting a settled resolution requires new evidence that the
recorded root cause no longer holds -- not a hunch.

## One-screen summary

| #   | Saga                                     | Verdict                                                                        | Key hashes                                            | Status                                |
| --- | ---------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------- | ------------------------------------- |
| 1   | Cloud first-session plugins              | Pre-launch placement required; SessionStart install is dark until next session | f2f13ab .. 8d4507f (root cause: c1c4500)              | Settled                               |
| 2   | Tiered-orchestrate + per-task Codex gate | Added, debugged, removed whole subsystem as slower/costlier                    | fc88aac, e401175, 7fefcb5                             | Settled (removed)                     |
| 3   | ECC rules tracked in git                 | 39 vendored files churned; now reproducible-untracked                          | e140ab3                                               | Settled; vendoring retired 2026-07-02 |
| 4   | Codex asset mirror into ~/.codex         | Overwrote hooksPath, wrote through symlink, orphaned agent files               | pre-public (no hash); sweep in install/common/link.sh | Settled (abandoned)                   |
| 5   | GSD npm supply-chain compromise          | Original package hostile after token rug-pull; redux fork only                 | 9ad4dc8                                               | Settled                               |
| 6   | todo.md audit file deleted               | Tracking moved off-file; all dropped items resolved 2026-07-02                 | 854228e, c0a9072                                      | Settled 2026-07-02                    |

## When NOT to use this skill

- Debugging a live failure right now -> `dotfiles-debugging-playbook`
  (symptom-to-triage table, discriminating experiments).
- Asking how a change must be classified, tested, reviewed -> `dotfiles-change-control`.
- Asking WHY the current design is shaped this way (invariants, weak points)
  -> `dotfiles-architecture-contract`.
- Claude Code platform mechanics (config dirs, marketplaces, plugin lifecycle)
  -> `claude-code-platform-reference`.
- Proving a symlink/plugin/identity/hook state from first principles
  -> `dotfiles-verification-toolkit`.
- Planning NEW cloud-session work -> `dotfiles-cloud-first-campaign` (this
  skill only tells you what already failed there).

## Saga 1: Cloud first-session plugin bootstrap (PRs #1-#5)

**Symptom.** Fresh claude.ai/code cloud container: ECC and Superpowers plugins
absent or unusable in the first session, despite install code that "ran fine".
Five PRs of partial fixes before the root cause surfaced.

**Root cause (c1c4500).** Claude Code loads plugins at CLI launch. A
SessionStart hook runs AFTER launch, so any plugin it installs is invisible
until the NEXT session. Only pre-launch placement (native `enabledPlugins`
declaration in the repo's `.claude/settings.json`, or the cloud environment
Setup script) can make a plugin usable in session 1.

**Evidence and sub-findings (chronological, all verified).**

| Hash             | Finding                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| f2f13ab          | First attempt: SessionStart self-bootstrap hook (`.claude/hooks/session-start.sh`)                                                                                                         |
| 2304015          | Containers seed the git author as the platform bot; reattribute from the tracked personal gitconfig -- and NEVER copy its 1Password signing block into a container (signing fails there)   |
| 910f2bc          | Plugin installers write only plugin keys into `settings.json`; seed-if-absent never delivers template updates -> `reconcile_claude_settings` merge in bootstrap-cloud.sh                   |
| 722c653, f91d7d2 | Exit codes lie: `claude plugin install` can exit 0 without installing. Verify against `installed_plugins.json`, not the exit code                                                          |
| 7cb28b7          | GitHub-backed official marketplace registers, then fetches its manifest ASYNC -> install during the fetch no-ops. ECC won the race only because plain-git marketplaces clone synchronously |
| c1c4500          | THE root cause (above); PLUGIN_RETRIES 5 -> 8 to outlast ~70s cold warmup                                                                                                                  |
| da54e17          | Register official marketplace by git URL; cap retry backoff at 15s (uncapped doubling could blow the Setup script ~5-min cap)                                                              |
| 8d4507f          | Final design (PR #5): declare plugins + marketplaces in `.claude/settings.json` (native, pre-launch, session-1-safe); demote the SessionStart hook to idempotent self-heal                 |

**Resolution.** Two-layer design documented in CLAUDE.md ("Cloud sessions"):
`.claude/settings.json` declaration is PRIMARY; `.claude/hooks/session-start.sh`
(gated on `CLAUDE_CODE_REMOTE`, matcher `startup|resume`) runs
`bootstrap-cloud.sh` as self-heal only.

**Status: settled.** Do not propose "just install plugins from a hook" again.
Do not trust plugin-install exit codes; `ensure_plugin` in bootstrap-cloud.sh
(checks `installed_plugins.json`) is the gold standard.

## Saga 2: Tiered-orchestrate and the per-task Codex gate (PRs #8-#13)

**Symptom.** Desire for cheap-worker/strong-reviewer orchestration led to a
custom `tiered-orchestrate` skill plus a per-task dual-model (Codex) quality
gate. The gate shipped with live bugs its own commit body documents, and the
whole subsystem was later measured slower and costlier than the stock pipeline.

**Root cause.** Two correctness bugs (recorded in the fc88aac commit body) plus
an economics failure:

- `BASE_SHA` was recaptured each rework round, so retries reviewed only the fix
  commit, not the full task diff -- a partial fix could pass.
- The reviewer received only file NAMES, so under worktree isolation it
  inspected the orchestrator checkout, not the task worktree, and passed
  vacuously.
- Even fixed, per-task dual-model gating cost more wall-clock and tokens than
  superpowers `subagent-driven-development` + a single `co-review` at the
  branch gate.

**Evidence.** fc88aac (PR #8, adds gate + documents both bugs); e401175
(PR #11, reverts the gate, keeps worker-worktree verification fix); 7fefcb5
(PR #13, removes skill + `exec_route.py` + `tiered_orchestrator.py` +
`orchestrator.conf`, 596 deletions).

**Moot note: fable->opus planner stopgap.** 4d8255d switched the orchestrator
planner model to opus as a stopgap. It died with the subsystem at 7fefcb5.
Do not resurrect it; there is no orchestrator.conf to point it at.

**Resolution.** Current standing routing (claude/CLAUDE.md, "Default Skill
Routing"): orchestrate multi-task work with the `Workflow` tool directly
(strong planner/reviewer, cheap workers), implement via superpowers
subagent-driven-development, single `co-review` second-model pass at the
branch gate.

**Status: settled (removed).** Lesson: per-task dual-model gates fail twice --
on worktree-scoping correctness (reviewers MUST get the worktree path and a
pinned base SHA, not file names) and on cost. Any revival proposal must answer
both.

## Saga 3: ECC vendored rules tracked in git

**Symptom.** 39 ECC-vendored rule files under `claude/rules/{common,cpp,python,
rust,typescript,web}/` churned the diff on every `ecc-update`.

**Root cause.** The rules are byte-identical upstream copies re-vendored by
`ecc-sync-rules` (`cp -R` from the ECC repo) -- reproducible artifacts, not
authored content. Tracking reproducible vendored files buys churn, not safety.

**Evidence.** e140ab3 (untracks the rule dirs, adds
`claude/rules/.gitignore` whitelisting only `/personal/`).

**Resolution.** Same model as ECC skills/commands/hooks: on-disk, untracked,
re-vendorable via `ecc-install`/`ecc-update`. Own rules go under
`claude/rules/personal/` (tracked). This is also why bootstrap installs ECC:
a fresh clone has no language rules until it runs.

**Status: settled, with one OPEN sub-question.** Whether vendoring into
`claude/rules/` is needed AT ALL is unresolved as of 2026-07-02: nothing
auto-loads `~/.claude/rules` (claude/CLAUDE.md never references it; only some
ECC skills read it), and cloud containers already have the full tree at
`~/.claude/plugins/marketplaces/ecc/rules/`. Do not "fix" this either way
without settling that question first -- see `dotfiles-research-frontier`.

**Correction (2026-07-02, later the same day): sub-question SETTLED --
vendoring RETIRED.** The decision gate ran: consumer enumeration over the ECC
plugin payload (`grep -rln "claude/rules" ~/.claude/plugins/cache/ecc/`) found
no runtime consumer (no hook reads `~/.claude/rules`; only on-demand skills
with overridable paths, chiefly `rules-distill`'s `scan-rules.sh` via
`RULES_DISTILL_DIR`). `ecc-sync-rules` and `ECC_VENDOR_LANGS` were removed;
`ecc-install`/`ecc-update` now flag inert leftovers
(`_ecc_legacy_rules_notice`); consumers point at the marketplace clone.
Lesson: a vendored copy nobody loads is pure carrying cost -- enumerate
consumers before building parity for an artifact.

**Second correction (2026-07-02): the enumeration's "nothing auto-loads
`~/.claude/rules`" premise was WRONG; the retirement outcome still stands.**
Claude Code natively auto-loads every `.md` under `~/.claude/rules` at launch
(`paths:` frontmatter scopes a rule to matching files; none = every session) --
verified live when a cloud session observed
`claude/rules/shared/claude-prompting.md` injected into its own context. The
enumeration missed the harness itself as a consumer because it ran in fresh
cloud clones where the untracked vendored dirs did not exist. Retirement
survives on the marketplace-clone-superset argument; leftover vendored dirs
are NOT inert (`common/`/`web/` load every session) and are now flagged as
active by `_ecc_legacy_rules_notice`; the tracked namespace is
`claude/rules/shared/` (renamed from `personal/`), home of the always-on
model-tuning layer. Amended lesson: enumerate consumers in an environment
where the artifact exists -- absence of effect on an absent artifact proves
nothing.

## Saga 4: Codex asset mirror into ~/.codex (abandoned)

**Symptom.** Running ECC's `sync-ecc-to-codex.sh` directly on a
dotfiles-managed machine caused three kinds of damage:

- Overwrote git `core.hooksPath`, orphaning the dotfiles-owned
  `post-checkout` hook.
- Wrote through the `~/.codex/AGENTS.md` symlink INTO this repo.
- Left nameless agent role files at `~/.codex/agents/` (codex 0.130+ warns).

**Root cause.** The mirror approach assumed `~/.codex` was script-owned;
here it is symlink-managed by the dotfiles, so upstream scripts writing there
punch through the symlinks and global git config.

**Evidence.** Pre-public -- public history starts at 93f2573 ("dotfiles:
Initial public release"), so no incident hash exists. The scars are in the
live tree: the CLAUDE.md "Codex plugin integration" warning; the leftover
sweep in install/common/link.sh (search `ecc-\|superpowers-`); the safe
wrapper `codex-ecc-sync` in zsh/functions.zsh, which runs the upstream script
with `ECC_GLOBAL_HOOKS_DIR="$HOME/.config/git/hooks"` so hooks land in the
dotfiles-owned dir.

**Resolution.** Never run `sync-ecc-to-codex.sh` directly. `ecc-install` /
`ecc-update` call the `codex-ecc-sync` wrapper; `install/common/link.sh`
sweeps `~/.codex/{skills,agents}/{ecc,superpowers}-*` leftovers on every
`update`.

**Status: settled (abandoned).** Lesson: before letting any upstream installer
write into a symlink-managed dir, check what it writes through and what global
git config it mutates.

## Saga 5: GSD npm package compromise (supply chain)

**Symptom.** The original `get-shit-done-cc` npm package was abandoned after a
token rug-pull with npm publish access RETAINED by the departing party.

**Root cause.** Classic supply-chain risk: retained publish rights on an
abandoned package mean any future version can be hostile.

**Evidence.** 9ad4dc8 (drops retired gsd from the plugin staleness check);
the standing policy lives in the comment block above `GSD_REDUX_PKG` in
zsh/functions.zsh.

**Resolution.** Treat `get-shit-done-cc` as hostile forever: never reinstall;
`gsd-uninstall` actively purges it. The only sanctioned variant is the
community fork `@opengsd/get-shit-done-redux`
(github.com/open-gsd/get-shit-done-redux), installed npx-only via
`gsd-install` (no global package, no gsd-sdk shim).

**Status: settled.** Lesson feeds `dotfiles-external-positioning`: pin what
you can, and treat "abandoned with publish access retained" as compromised,
not merely stale.

## Saga 6: todo.md audit file deletion and the dropped items

**Symptom.** A 2026-05-06 audit produced a tracked `todo.md`. Most items were
fixed (checked off through 854228e), then c0a9072 deleted the file during
public-surface hardening, dropping three still-open low-priority items.

**Evidence.** 854228e (last check-off pass); c0a9072 (deletes todo.md, -28
lines). Recover the full list with `git show c0a9072^:todo.md`.

**Live-verified status of the three dropped items (2026-07-02):**

| Item                                           | Status                                                                                                                                                    | Evidence                                     |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Replace backticks with `$(...)`                | RESOLVED 2026-07-02 -- zsh/.zprofile now uses `$(uname)`/`$(uname -m)`; install/common/zsh.sh was already clean (comment mention only)                    | `grep -n 'uname' zsh/.zprofile`              |
| `update()` should propagate install.sh failure | RESOLVED 2026-07-02 -- `update()` captures the install status before the final `cd` and returns it, printing `[X] update failed: install.sh exited N`     | `grep -n 'install_status' zsh/functions.zsh` |
| Document Brewfile split in README              | RESOLVED -- README.md "Adding New Packages" now distinguishes install/common/Brewfile.rb (CLI, all platforms) from install/macos/Brewfile.rb (macOS apps) | `grep -n 'Adding New Packages' README.md`    |

**Status: settled (2026-07-02).** All three dropped items are resolved; the
deleted todo.md carries no remaining work.

## Minor settled fixes (2026-07-02, same-day -- know the CURRENT state)

| Hash    | Fix                                                                                                                                                                                                                                                                           |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 52f807d | `claude/hooks/block_secrets.py` matched secret patterns as substrings of the full path, blocking innocents like `secrets_manager/util.py` and ITS OWN FILE. Segment-based matching backported from the Codex twin; test cases mirrored into claude/hooks/claude-hooks.test.sh |
| 5b799dd | `superpowers-install` (zsh/functions.zsh) now registers the official marketplace by git URL before install -- previously a silent no-op risk when the marketplace was unregistered                                                                                            |
| 465ee17 | Aggregate test runner `bin/dotfiles-tests` + CI `.github/workflows/tests.yml` added; todos test root-guard                                                                                                                                                                    |
| 26eae6d | README command list synced (/handoff, /kickoff, skills catalog); claude/CLAUDE.md spec path aligned to docs/specs/                                                                                                                                                            |

## Adding a new saga entry (append-only protocol)

When a future investigation SETTLES (root cause identified, resolution merged,
or approach definitively abandoned), append it here. Do not add open
investigations -- those belong in `dotfiles-debugging-playbook` or a ticket
until they settle.

1. Verify every hash you will cite: `git show <hash> --stat` (and `-s
--format=%B` for lessons recorded in commit bodies -- the best evidence is
   a commit body that documents its own bugs, as fc88aac does).
2. Append a numbered `## Saga N:` section using the fixed shape: **Symptom**,
   **Root cause**, **Evidence** (hashes + stable file anchors -- function
   names and headings, not line numbers), **Resolution**, **Status** with a
   one-line **Lesson**.
3. Add one row to the one-screen summary table.
4. Never rewrite a settled saga's history. Allowed edits to existing entries:
   flip a Status (open -> settled) with new dated evidence, or append a dated
   correction line. If a resolution is later reverted, that is a NEW saga
   referencing the old one.
5. Date-stamp anything volatile you state, and add its re-verification command
   to Provenance below.
6. Route the change through normal gates (`dotfiles-change-control`) -- this
   file is tracked and PR-reviewed like everything else.

## Provenance and maintenance

All facts verified against the live repo on **2026-07-02**. History begins at
93f2573 (initial public release, 2026-06-12); anything earlier is pre-public
and hashless by design.

| Volatile fact                                         | Re-verify with                                                                                                                                                                                                                       |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| All cited hashes exist and match descriptions         | `for h in f2f13ab 2304015 910f2bc 722c653 f91d7d2 7cb28b7 c1c4500 da54e17 8d4507f fc88aac e401175 7fefcb5 4d8255d e140ab3 9ad4dc8 854228e c0a9072 52f807d 5b799dd 465ee17 26eae6d 93f2573; do git show -s --format='%h %s' $h; done` |
| tiered-orchestrate truly gone                         | `ls claude/skills/tiered-orchestrate claude/orchestrator.conf 2>&1` (expect: No such file)                                                                                                                                           |
| ECC rules still untracked, personal/ tracked          | `cat claude/rules/.gitignore; git ls-files claude/rules/ \| head`                                                                                                                                                                    |
| Cloud plugin declaration still primary                | `grep -n 'enabledPlugins\|extraKnownMarketplaces' .claude/settings.json`                                                                                                                                                             |
| SessionStart hook still self-heal, gated              | `grep -n 'CLAUDE_CODE_REMOTE' .claude/hooks/session-start.sh`                                                                                                                                                                        |
| GSD policy comment intact                             | `grep -n 'rug-pull' zsh/functions.zsh`                                                                                                                                                                                               |
| codex-ecc-sync wrapper + hooks redirect intact        | `grep -n 'ECC_GLOBAL_HOOKS_DIR' zsh/functions.zsh`                                                                                                                                                                                   |
| link.sh leftover sweep intact                         | `grep -n "name 'ecc-\*'" install/common/link.sh`                                                                                                                                                                                     |
| Saga 6 items resolved (backticks, update propagation) | `grep -n 'uname' zsh/.zprofile; grep -n 'install_status' zsh/functions.zsh`                                                                                                                                                          |
| Deleted todo.md recoverable                           | `git show c0a9072^:todo.md`                                                                                                                                                                                                          |
| block_secrets segment matching present                | `grep -n 'segment' claude/hooks/block_secrets.py`                                                                                                                                                                                    |
