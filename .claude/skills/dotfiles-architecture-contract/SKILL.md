---
name: dotfiles-architecture-contract
description: Load BEFORE proposing any structural or design change to the dotfiles repo, and whenever you catch yourself asking "why is it built this way", "can I just track this file", "why is settings.json not symlinked", "why two config dirs", "why is this untracked", or "can the SessionStart hook install the plugin". Documents the eight load-bearing design decisions with rationale, the invariants that must hold, and the known weak points, plus the Codex plugin integration reference (codex-surfaces.py / codex-roles.py reconciliation, staging provenance, focus mode). NOT for making/committing a change (dotfiles-change-control), diagnosing a breakage (dotfiles-debugging-playbook), or the blow-by-blow incident history (dotfiles-failure-archaeology).
---

# Dotfiles Architecture Contract

The load-bearing design decisions of this repo, each with the WHY that makes it
non-obvious, plus the invariants any change must preserve and the weak points
we know about and have chosen to live with (for now). Every decision here was
paid for -- most have a commit-hash-cited incident behind them (details in
dotfiles-failure-archaeology). If a proposed change violates a decision below,
the change is wrong until proven otherwise.

Jargon, defined once:

- **Symlinked asset**: a file/dir in this repo that `install/common/link.sh`
  (or `bootstrap-cloud.sh`) links into `$HOME` -- edits to the repo take effect
  live on the machine.
- **Seeded machine-local file**: a real file copied from a repo template once,
  then owned by the machine; the repo never sees its contents again.
- **Vendored-untracked**: upstream content copied onto disk inside the repo
  tree by an installer, deliberately gitignored.
- **Superpowers**: the Claude Code plugin this repo depends on
  (`superpowers@claude-plugins-official`). The retired ECC (formerly `ecc@ecc` from github.com/affaan-m/ECC) is retired (2026-09).

## Front-loaded warnings

- [WARNING] This repo is PUBLIC. Decision 8 below is not one constraint among
  eight -- it shapes the other seven. Anything employer-specific, secret, or
  machine-specific must be structurally incapable of landing here.
- [WARNING] Never convert a seeded machine-local file into a symlink "for
  convenience". That exact move corrupted state before: Claude CLI wrote
  through a stale symlink and polluted the repo / dropped plugin config
  (guards and history in `install/common/claude-links.sh`,
  `seed_machine_local_file`).
- [WARNING] Never rely on a SessionStart hook to make a plugin usable in the
  same cloud session. Plugins load at CLI launch; post-launch installs are
  dark until the NEXT session (commit c1c4500). See Decision 5.

## Decision 1: symlink vs seed -- two classes, never blur them

| Class                                       | Examples                                                                                                                                                                                     | Why                                                                                                                                                                    |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Symlinked (repo-owned, live)                | `zsh/` -> `~/.zshrc`; `claude/{CLAUDE.md,commands,agents,hooks,skills,rules}` -> `~/.claude*/`; `git/hooks` -> `~/.config/git/hooks`; `bin/*` -> `~/bin/`                                    | One source of truth; `git pull` updates every machine; edits are testable in-repo                                                                                      |
| Seeded machine-local (template copied once) | `claude/settings.json.tmpl` -> `~/.claude*/settings.json`; `git/work/.gitconfig-work.tmpl` -> `~/.gitconfig-work`; `ssh/configs/agent.toml` -> 1Password agent config; `~/.ssh/config_local` | The live file is WRITTEN BY SOMETHING ELSE (plugin installers write settings.json) or holds data that must never be public (employer identity, vault names, lab hosts) |

The rule: if any tool writes into the file at runtime, or if its real contents
are private, it is seeded -- never symlinked. A symlink there means writes go
through into the public repo. `seed_machine_local_file` in
`install/common/claude-links.sh` enforces this: it removes any pre-existing
symlink at the destination, seeds only if absent, and warns when the existing
file is under 50% of the template size (the signature of a prior write-through
corruption).

Cost accepted knowingly: template changes do not propagate to existing
machines (see Weak points).

## Decision 2: one asset source, two config dirs

`~/.claude` (personal account) and `~/.claude-work` (work account) are both
populated by `link_claude_config_dir` in `install/common/claude-links.sh` from
the SAME `claude/` tree. Each dir keeps only its own machine-local
`settings.json` and its own plugin installs.

Why: accounts must be isolated (separate OAuth, separate plugin state) but the
assets -- CLAUDE.md, skills, hooks, rules -- must never fork. Duplicate asset
trees would drift silently.

Routing: the `claude()` wrapper in `zsh/claude-account.zsh` sets
`CLAUDE_CONFIG_DIR=$HOME/.claude-work` when launched under `~/Git/work`
(symlinks resolved on both sides); a pre-set `CLAUDE_CONFIG_DIR` always wins;
`claude --personal` forces the personal account. `claude-account` prints the
resolution; `claude/hooks/account_guard.py` (SessionStart) warns on a
dir/account mismatch. Unwrapped launches (desktop app) default to `~/.claude`,
which is why personal is the default dir, not work.

Invariant: any new Claude asset goes into `claude/` and gets linked by
`link_claude_config_dir` -- never hand-placed into one config dir.

## Decision 3: fail-loud git identity

`git/.gitconfig` has NO `[user]` block. Instead:

- `user.useConfigOnly = true` -- git refuses to commit anywhere it cannot
  resolve an identity, instead of guessing one. Wrong-identity commits on a
  public repo are unrecallable; a loud failure is the feature.
- `includeIf "gitdir/i:~/Git/personal/"` -> `~/.gitconfig-personal` (tracked);
  `includeIf "gitdir/i:~/Git/work/"` -> `~/.gitconfig-work` (seeded, never
  tracked). `gitdir/i` is case-insensitive for APFS; linked worktrees resolve
  to the main repo's gitdir, so worktrees inherit identity wherever they live.
- Signing lives INSIDE each include (each pairs `gpgsign=true` with its own
  `signingkey`), never at base level -- a base `gpgsign=true` would break the
  repo-local `user.email` escape hatch for repos outside the convention dirs
  (rationale comment in `git/.gitconfig`, `[commit]` block).
- `url insteadOf` in each include rewrites `git@github.com:` to the pinned SSH
  alias (`Git-Personal` / `Git-work`), so fresh clones authenticate with the
  right key with zero manual steps; `pushInsteadOf` keeps https fetch anonymous
  but pushes over SSH.

Verify the whole chain read-only: `git identity` (alias for
`bin/identity-doctor`). Populate work identity: `bin/identity-setup`.

Invariant: identity comes only from the conditional includes. Never add a
`[user]` block to `git/.gitconfig`; never commit `~/.gitconfig-work` contents.

## Decision 4: vendored-but-untracked upstream content (historical; ECC retired)

This decision was born from the retired ECC: its skills/commands/hooks lived
on disk inside the repo tree but were gitignored, and installers re-vendored
them byte-identical from upstream. Why: tracking them once caused 39-file
churn on every upstream sync (fixed at e140ab3). They were reproducible from
the installer, so tracking added noise and invited local edits that died on
the next `ecc-update` (both `ecc-install`/`ecc-update` are now removed along with the retired ECC itself, 2026-09).

ECC RULES vendoring was fully RETIRED ahead of ECC itself (2026-07-02,
settling the former open question): the upstream tree shipped from the retired ECC's marketplace clone, so local copies bought sync code for nothing. Claude Code
natively auto-loads every `.md` under `~/.claude/rules` (`paths:` frontmatter
scopes to matching files; none = every session) -- verified live in a cloud
session 2026-07-02. The retirement-era "nothing auto-loads" finding came from
fresh cloud clones where the untracked vendored dirs did not exist; leftover
language dirs on older machines therefore still auto-load and should be
deleted by hand (the flagging function, `_ecc_legacy_rules_notice`, is gone along with the rest of the retired ECC).

Invariant: never hand-edit any leftover vendored dirs; never `git add -f`
them. Own rules go under `claude/rules/personal/` only (always-on unless
given a `paths:` frontmatter; `claude/rules/.gitignore` whitelists only
`.gitignore` and `personal/`).

## Decision 5: the pre-launch placement INVARIANT (cloud plugins)

**Anything that must exist at Claude Code launch must be placed pre-launch.
Post-launch hooks are self-heal only.**

Plugins load when the CLI starts. A SessionStart hook runs AFTER launch, so a
plugin it installs is invisible until the next session (root cause: c1c4500,
after four earlier fixes chased symptoms -- see dotfiles-failure-archaeology).
Final design (8d4507f): the repo's committed `.claude/settings.json` declares
`enabledPlugins` and pins both marketplaces by git URL in
`extraKnownMarketplaces`; the platform installs them natively pre-launch, so
they work on session 1. `.claude/hooks/session-start.sh` (gated on
`CLAUDE_CODE_REMOTE=true`, matcher `startup|resume`) runs `bootstrap-cloud.sh`
as the post-launch SELF-HEAL: assets, settings reconcile, git identity, and a
plugin re-install that only pays off next session if the native path missed.

Corollaries baked into `bootstrap-cloud.sh`, keep them:

- `claude plugin install` can exit 0 without installing; `ensure_plugin`
  verifies against `~/.claude/plugins/installed_plugins.json` instead
  (f91d7d2).
- GitHub-backed marketplaces register async; wait for the manifest before
  installing (7cb28b7), with backoff capped at 15s so the platform Setup
  script's ~5-minute budget is never blown (da54e17).
- Cloud containers seed commits as `Claude <noreply@anthropic.com>`;
  bootstrap-cloud reattributes to the personal identity and disables signing
  (no 1Password in a container) -- never copy the op-ssh-sign block into a
  container (2304015).

## Decision 6: one global git hooks dir for all harnesses

`core.hooksPath = ~/.config/git/hooks` (`git/.gitconfig`), a symlink to this
repo's `git/hooks/` (created by `install/common/link.sh`). One dir serves
Claude sessions, Codex sessions, and manual commits -- git hooks are
harness-agnostic, so guard logic (commit-msg format, secret blocking,
worktree hydration via post-checkout) applies no matter who commits.

Why it is fragile by design: anything that rewrites `core.hooksPath` orphans
ALL of it silently. That is exactly what the retired ECC's `sync-ecc-to-codex.sh` did pre-public (plus writing through the
`~/.codex/AGENTS.md` symlink into the repo). Both direct sync and its
wrapper are retired along with ECC itself (2026-09). `superpowers-install`
stages a self-contained native plugin without any upstream global sync.
`install/common/link.sh` sweeps leftover mirror artifacts on every `update`.

Invariant: no tool may set `core.hooksPath`; hook additions go into
`git/hooks/` with a test.

## Decision 7: idempotency contract

The `update()` zsh function (`zsh/functions.zsh`) pulls the repo and re-runs
`install/install.sh` in full. There is no "first install" vs "update" code
path -- the installer IS the updater. Therefore every install step must be
safely re-runnable on a machine that already has the state: `ln -sfn` not
`ln -s`, seed-if-absent not overwrite, backup-then-replace for real dirs where
a symlink belongs (`link_claude_config_dir` does this for
`commands/agents/hooks/rules/skills`), sweeps for retired artifacts.

Invariant: before merging any installer change, ask "what happens on the
second run, and on a machine with pre-existing real files where symlinks
belong?" If the answer involves data loss or a duplicate, it is not done.

## Decision 8: the public-repo constraint shapes everything

github.com/taloncjones/dotfiles is public. Consequences already visible above:

- Employer identity, vault names, machine-local hosts live ONLY in seeded
  files (`~/.gitconfig-work`, `~/.ssh/config_local`, `agent.toml`) -- Decision 1.
- Only PUBLIC key halves are tracked (`ssh/keys/id_ed25519_personal.pub`);
  private keys never touch disk (1Password agent).
- Wrong-identity commits are prevented structurally, not by discipline --
  Decision 3.
- Guard hooks + `git/hooks/public-safety.test.sh` + CI backstop it, but the
  architecture is arranged so the secret has no natural path into the tree in
  the first place. The gates are the last line, not the design.

Invariant: a new feature that needs private data must put that data in a
seeded machine-local file (or env var), with a tracked template documenting
its shape.

## Invariants checklist

Before approving a structural change, confirm each still holds:

- [ ] No runtime-written or private-content file is symlinked into the repo
      (settings.json, .gitconfig-work, config_local, agent.toml stay seeded).
- [ ] All Claude assets flow through `claude/` + `link_claude_config_dir`;
      `~/.claude` and `~/.claude-work` never diverge in assets.
- [ ] `git/.gitconfig` has no `[user]` block; `useConfigOnly` stays true;
      signing stays inside the per-identity includes.
- [ ] Any leftover vendored dirs from the retired ECC stay untracked and
      hand-edit-free; own content stays in whitelisted `personal/` paths.
- [ ] Anything needed at Claude launch in cloud is placed pre-launch
      (settings declaration or Setup script); SessionStart remains self-heal.
- [ ] `core.hooksPath` points at the dotfiles hooks dir and nothing rewrites it.
- [ ] Every installer step is idempotent (safe twice, safe over pre-existing
      state).
- [ ] No secret, employer datum, or machine path can land in the tree by any
      normal workflow.

## Known weak points (open -- stated plainly, not oversold)

| Weak point                                                                                                                                                                                                                               | Status                                                                         |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `claude/settings.json.tmpl` changes need MANUAL merge on existing machines (seed-once); only cloud runs `reconcile_claude_settings` automatically                                                                                        | Open. Accepted cost of Decision 1; change-control skill has the merge protocol |
| Machine-path plugin install (`superpowers-install`; the retired `ecc-install` had the same gap) trusts CLI output (grep of plugins list), not `installed_plugins.json`; `bootstrap-cloud.sh` `ensure_plugin` is the gold standard        | Open. Candidate: port ensure_plugin to the zsh functions                       |
| Git hooks `pre-commit`/`pre-push` (derived from the retired ECC) have behavioral suites; `post-checkout` test remains static-shape-only                                                                                                  | Partially closed; see dotfiles-validation-and-qa                               |
| `op-ssh-sign` path is macOS-only -- commit signing fails on Linux (bootstrap-cloud disables signing in containers); `install/common/zsh.sh` hardcodes the `/home/linuxbrew` path; `defaults.sh` PlistBuddy `Set` lacks an `Add` fallback | Open portability debts                                                         |
| Cloud containers are personal-account only; no `~/.claude-work` story in cloud                                                                                                                                                           | Open                                                                           |
| Whether ECC rules vendoring is still needed at all                                                                                                                                                                                       | CLOSED: ECC is fully retired (2026-09), question moot (Decision 4)             |

## When NOT to use this skill

- Making, committing, or reviewing an actual change (gates, classification,
  commit format) -> **dotfiles-change-control**.
- Something is broken and you need triage -> **dotfiles-debugging-playbook**.
- You want the full incident narrative behind a decision (PR-by-PR, dead ends,
  reverts) -> **dotfiles-failure-archaeology**.
- Claude Code platform mechanics in general (config-dir semantics, plugin/
  marketplace internals, hook lifecycle) -> **claude-code-platform-reference**.
- Recreating a machine or container from scratch -> **dotfiles-build-and-env**.
- Proving an invariant currently holds on a live machine (symlink chains,
  plugin installs, identity resolution) -> **dotfiles-verification-toolkit**.

## Provenance and maintenance

Written 2026-07-02 against the repo at that date. All commit hashes verified
with `git log --format="%h %s" -n1 <hash>` this day. Re-verify volatile facts
before trusting them:

- Symlink/seed behavior: `grep -n "seed_machine_local_file\|ln -sfn" install/common/claude-links.sh`
- Account routing: `grep -n "_claude_config_dir\|CLAUDE_WORK_TREE" zsh/claude-account.zsh`
- Identity chain: `grep -n "useConfigOnly\|includeIf\|hooksPath" git/.gitconfig` and run `bin/identity-doctor`
- Vendored-untracked model: `cat claude/rules/.gitignore`
- Pre-launch plugin declaration: `cat .claude/settings.json` (enabledPlugins + extraKnownMarketplaces); self-heal gate: `head -25 .claude/hooks/session-start.sh`
- ensure_plugin / reconcile: `grep -n "ensure_plugin\|reconcile_claude_settings" bootstrap-cloud.sh`
- update() re-run contract: `grep -n -A8 "function update()" zsh/functions.zsh`
- Incident hashes: `git show <hash> --stat` for c1c4500, 8d4507f, 722c653, 7cb28b7, da54e17, 2304015, e140ab3
- Weak-point status may have improved since 2026-07-02 -- check `git log --oneline -20` and the failure-archaeology skill before repeating an "open" claim.

## Codex plugin integration (reference; migrated from CLAUDE.md 2026-09-13; ECC retired 2026-09)

Superpowers uses a native, independent plugin installation in both runtimes.
Claude installs `superpowers@claude-plugins-official` into both account
config dirs. Codex stages a self-contained copy from its own upstream
checkout under `~/.local/share/dotfiles/codex-workflows`, then installs
`superpowers@dotfiles-workflows`. The retired ECC's equivalent (`ecc@ecc` /
`ecc@dotfiles-workflows`) is retired: the settings reconcile and the Codex
plugin dedupe both force it off, and `ecc-uninstall` removes what remains on
disk. Never run the retired ECC's `sync-ecc-to-codex.sh` on a
dotfiles-managed machine: it mutated shared `AGENTS.md`, MCP, agent, and
git-hook surfaces. `install/common/link.sh` continues to sweep stale direct
skill/agent mirrors from older installs.

`install/common/codex-surfaces.py` reconciles native discovery during install
and update. It disables proven duplicate skill copies and incompatible or inert
Claude-only imports of `security-guidance`, `code-review`, and
`code-simplifier`; custom or compatible implementations are preserved. It
supplies `skills.max_context_tokens = 10000` only when unset; an explicit
budget wins. The helper preserves skill files and unrelated configuration.
Unsupported TOML layouts fail without being rewritten. Optional installer
reconciliation warns and continues; explicit plugin lifecycle commands still
report failure. Managed skill linking preserves existing real files and
directories, including their contents, and warns instead of replacing them;
inspect those destinations before moving custom content to make room for a
managed symlink.

Shared `handoff`, `kickoff`, `todos`, `repo-recall`, and `post-merge` skills
link from `claude/skills` into Codex. Codex review and Herd entrypoints live in
`codex/skills`. Helpers resolve paths from these installed sources, not the
repository being worked on. `workflow_context.py` owns repository/account
identity; handoff history is account/repository/task scoped. Never copy a
personal handoff into a work account's state.

`install/common/codex-roles.py` migrates only byte-exact historical managed
roles left over from the retired ECC (identified by the SHA256 of its
`.codex/agents` files) to Luna/medium explorer, Terra/medium documentation
research, and Astra/high reviewer. Custom role files and model choices
remain untouched; `--check --codex-home <path>` previews its decision.
Repo-owned `codex/AGENTS.md` does not carry a copied upstream instruction
block from any plugin.

Plugin staging records upstream revision and payload digest independently of
the wrapper version. A now-retired Codex ECC cache directory named `2.0.0`
could contain a current upstream payload; verify installed bytes/provenance
before declaring anything stale. Automatic Plan Canvas session/stop hooks (an ECC-only feature) are gone along with the rest of the retired ECC.

Run the helper with `--check` to preview changes or `--apply` to write them.
The old `--focus --apply` flag opted into the retired ECC's core skill catalog in `codex/ecc-skills.txt` (also removed); subsequent updates
retained that choice. Explicit skill overrides are preserved. Any leftover
focused-discovery `[[skills.config]]` blocks marked with the retired ECC's `# dotfiles-managed: ecc-focus` should be removed by hand, then reconcile
without `--focus`. Proven duplicates remain disabled. The compatibility
checks run again on later updates; simply re-enabling an incompatible import
does not opt it out.

Restart Claude or Codex after changing plugin or hook configuration. A running
session may retain old registrations, including across compaction. Verify a
fresh Codex process with a harmless tool call and final response: startup alone
does not exercise PostToolUse or Stop.
