---
name: dotfiles-external-positioning
description: Load BEFORE any action that touches the public surface of this repo -- committing new file types, vendoring or deriving from upstream code, adding a dependency or plugin, publishing/README changes, or deciding whether something belongs in this repo at all. Covers what may NEVER land in the tree (secrets, employer config, 1Password vault names, per-model audit files), the enforcement stack (block_secrets hooks, ECC pre-commit scan, public-safety.test.sh, .gitignore), MIT/NOTICE licensing duties, the upstream trust map (ECC, Superpowers, the compromised GSD original), and the public/private split. Trigger phrases -- "is this safe to commit", "can this go in the repo", "add this upstream tool", "update NOTICE", "license question", "is the repo safe to be public", "should this be private". NOT for the mechanics of committing (dotfiles-change-control), running the test suites (dotfiles-validation-and-qa), or why a hook blocked you (dotfiles-debugging-playbook).
---

# Dotfiles External Positioning

Public-repo posture for github.com/taloncjones/dotfiles. This repo is PUBLIC
on purpose and must stay public: fresh machines and cloud containers HTTPS-clone
it with no SSH keys or GitHub grants (README.md step 2; the cloud plugin
declaration in `.claude/settings.json` depends on the same property). Everything
in the tree is therefore world-readable forever -- git history included. This
skill defines what may never land here, the machinery that enforces it, the
licensing duties when borrowing upstream code, and the trust posture toward
each upstream.

## Front-loaded warnings

- [WARNING] Git history is public too. The safety scans check the CURRENT tree
  only. If a secret ever gets committed and later removed, it is still in
  history: rotate the credential immediately -- deleting the file is not
  remediation.
- [WARNING] Never reinstall the original `get-shit-done-cc` npm package. It was
  compromised via a token rug-pull with retained publish access. Treat it as
  hostile. No GSD variant is sanctioned anymore: the community redux fork
  (`@opengsd/get-shit-done-redux`) had its install path removed, and
  `gsd-uninstall` in `zsh/functions.zsh` actively purges both.
- [WARNING] Employer names, work emails, and work URLs are banned from the
  tree, and NO automated scan catches them -- `git/hooks/public-safety.test.sh`
  checks paths and secret patterns only. This one is enforced by review alone.
  Work identity lives exclusively in machine-local files
  (`~/.gitconfig-work`, `~/.ssh/config_local`, `~/.ssh/id_ed25519_work.pub`),
  written by `bin/identity-setup`, never tracked.
- [WARNING] When you vendor, port, or adapt upstream code, updating `NOTICE`
  is part of the change, not a follow-up. MIT requires the upstream copyright
  and permission notice to travel with the code.

## What may NEVER land in the tree

| Category                    | Rule                                                                                                                                                                                                                   | Where the boundary lives                                                                                                     |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Secrets, keys, tokens       | Never. Only `.pub` public keys are tracked, deliberately: `ssh/keys/id_ed25519_personal.pub` is the single tracked key file.                                                                                           | `.gitignore` security section (`id_*`, `!*.pub`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `.env.*`, `*credentials*`); hooks below |
| Employer/work config        | Names, emails, hosts, org URLs stay machine-local. The repo ships only a commented TEMPLATE: `git/work/.gitconfig-work.tmpl` (seeded once to `~/.gitconfig-work`).                                                     | Template-seed pattern; `identity-setup` wizard writes the real values outside the repo                                       |
| 1Password vault/item names  | The tracked `ssh/configs/agent.toml` carries placeholder personal entries and a commented work stanza; real work vault/item names go only in the machine-local seed copy at `~/.config/1Password/ssh/agent.toml`.      | Seed-once copy on first install (see repo CLAUDE.md symlink table)                                                           |
| Per-model audit files       | `claude/Fable5.md` and `claude/Opus4.md` are derived from private session transcripts and must never be committed. `claude/operating-principles.md` is the sanitized, committed distillation.                          | `claude/.gitignore:5-6`                                                                                                      |
| Machine-local settings      | `settings.json` per Claude config dir, `settings.local.json`, `.env*`, `*.local`, `.netrc`, `*.tfstate`.                                                                                                               | `.gitignore` security section                                                                                                |
| Local user paths            | No literal `/Users/<name>` owner home prefix (or any absolute home path) in tracked content. The scan greps for the owner's exact prefix; writing it out here would trip the scan, which is why this row does not.     | `public-safety.test.sh` assertion 2                                                                                          |
| Personal backlog files      | No tracked `todo.md` (the cross-session backlog lives in the untracked `.todos/` state, hydrated by `git/hooks/post-checkout`).                                                                                        | `public-safety.test.sh` assertion 1                                                                                          |
| GUI-signing config on cloud | Never copy the 1Password `op-ssh-sign` signing block into a cloud container -- every commit would fail (no 1Password app). `bootstrap-cloud.sh` sets `commit.gpgsign false` and copies identity only (commit 2304015). | `bootstrap-cloud.sh` (search `gpgsign`)                                                                                      |

Decision rule when unsure: if the value differs per machine, per employer, or
per account, it does not belong in the tree -- it belongs in a machine-local
file seeded from a tracked placeholder template. That is the established
pattern (`.gitconfig-work.tmpl`, `agent.toml`, `settings.json.tmpl`).

## Enforcement stack (defense in depth)

Four layers between a secret and the public tree. Do not treat any single
layer as sufficient; each has known gaps (listed).

| Layer                                                                           | When it fires                                                                                                 | What it catches                                                                                                                                                                                                      | Gap                                                                                                                                  |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `claude/hooks/block_secrets.py` (+ Codex twin `codex/hooks/block_secrets.py`)   | PreToolUse on Read/Edit/Write in a Claude session                                                             | Access to `.env*`, key files, `credentials`/`secrets` path segments. Segment-based matching (commit 52f807d) -- exact filenames/segments, not substring, so `secrets_manager/util.py` passes. `.pub` always allowed. | Session-time only; fails open on exceptions; does not see `bash echo > file`                                                         |
| `git/hooks/pre-commit` (ECC-vendored, via `core.hooksPath=~/.config/git/hooks`) | Every `git commit`                                                                                            | High-signal secret regexes in ADDED lines only (OpenAI/GitHub/AWS keys, private key blocks, generic `password=...` assignments)                                                                                      | Untested (no suite); bypassable via `ECC_SKIP_GIT_HOOKS=1` / `ECC_SKIP_PRECOMMIT=1` -- emergencies only, per dotfiles-change-control |
| `git/hooks/public-safety.test.sh`                                               | `bin/dotfiles-tests` (suite 7 of 9) and CI (`.github/workflows/tests.yml`) on every push to main and every PR | Whole-tree scan: tracked `todo.md`, the owner's literal `/Users/<name>` home prefix, high-confidence secret patterns (AWS, OpenAI, GitHub, Slack, GitLab, Google, age, private key blocks)                           | Current tree only, not history; no employer-name detection                                                                           |
| `.gitignore` security section                                                   | `git add`                                                                                                     | Keeps whole classes of files (`id_*`, `*.pem`, `.env.*`, `*credentials*`) out of the index by default                                                                                                                | `git add -f` bypasses silently                                                                                                       |

Run before anything public-facing (new file types, README claims, vendoring):

```bash
cd ~/dotfiles
sh git/hooks/public-safety.test.sh    # the public-posture gate alone
bin/dotfiles-tests                    # all suites, the full pre-push bar
```

If `public-safety.test.sh` fails on your change, fix the content -- do not
widen its exclusion globs. The only legitimate exclusions are the test file
itself and `.pub` keys.

## Licensing and attribution

- License: MIT, `LICENSE` (Copyright (c) 2026 Talon Jones).
- Third-party notices: `NOTICE`. It currently lists exactly two upstreams:
  1. ECC -- `claude/rules/` (curated vendored subset) and the adapted
     `git/hooks/pre-commit` + `git/hooks/pre-push`.
  2. GSD redux fork -- `claude/statusline.js` (ported statusline render).

When vendoring or deriving from any upstream, in the same PR:

- [ ] Confirm the upstream license is MIT-compatible; if not, do not vendor.
- [ ] Add/extend the `NOTICE` entry: paths in this repo, upstream URL,
      license, copyright line.
- [ ] No AI-attribution or "generated by" lines (house rule, hook-enforced).
- [ ] If the vendored content is installer-reproducible (like ECC rules),
      prefer keeping it UNTRACKED with a re-vendor command
      (`claude/rules/.gitignore` model) over committing upstream bytes --
      less churn, no license text drift. Adapted-and-diverged code (like the
      git hooks) is tracked and NOTICE-listed.
- [ ] Run `sh git/hooks/public-safety.test.sh` -- vendored code is a common
      secret-pattern false-positive source and occasionally a true one.

## Upstream ecosystem map

| Upstream                              | Pinned source                                                                                                                       | Trust posture                                                                                                                                                                                                           | Repo integration                                                                                                                                                                                                                      |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ECC v2 (Everything Claude Code)       | `https://github.com/affaan-m/ECC.git` (`ECC_REPO_URL` in `zsh/functions.zsh`; plugin id `ecc@ecc`)                                  | Trusted-but-verified: reproducible vendoring (`ecc-sync-rules`, `cp -R`, reviewable diff), plugin installed from the same pinned git URL. The v1 `everything-claude-code` repo/marketplace is RETIRED -- do not add it. | Plugin in both config dirs; rules vendored untracked; git hooks adapted+tracked. Never run its `sync-ecc-to-codex.sh` directly -- only via the `codex-ecc-sync` wrapper (redirects `ECC_GLOBAL_HOOKS_DIR`, restores `core.hooksPath`) |
| Superpowers                           | `https://github.com/anthropics/claude-plugins-official.git` (official marketplace, plugin id `superpowers@claude-plugins-official`) | Trusted (Anthropic-official). `superpowers-install` registers the marketplace by git URL before installing (commit 5b799dd) rather than assuming it is pre-registered.                                                  | Plugin only; nothing vendored into the tree                                                                                                                                                                                           |
| GSD original (`get-shit-done-cc` npm) | none -- COMPROMISED                                                                                                                 | HOSTILE. Token rug-pull with retained npm publish access. Never reinstall. `gsd-uninstall` purges the package, its npx caches, and all leftover state (retirement completed at commit 9ad4dc8).                         | Nothing remains installed                                                                                                                                                                                                             |
| GSD redux fork                        | npm `@opengsd/get-shit-done-redux`; repo `https://github.com/open-gsd/gsd-core` per `NOTICE` (formerly `get-shit-done-redux`)       | Retired (install path removed 2026-07-10); the package is referenced only by `gsd-uninstall`'s official-uninstaller call. Only the ported statusline survives, as tracked code.                                         | `claude/statusline.js`, NOTICE-listed                                                                                                                                                                                                 |

### Supply-chain rules (paid for in incidents)

1. **Pin by git URL, not by name.** A marketplace/plugin name resolves through
   mutable registries; a git URL is what you audited. Both cloud
   (`.claude/settings.json` `extraKnownMarketplaces`) and machine installers
   (`ECC_REPO_URL`, the official-marketplace URL in `superpowers-install`)
   already do this -- keep it that way.
2. **Prefer reproducible, auditable artifacts over trusting installers.** A
   pinned git clone (the ECC marketplace clone) holds bytes you can diff; an
   installer runs code you did not read. (The old `ecc-sync-rules` vendoring
   copy was retired 2026-07-02 once nothing consumed it -- reproducibility is
   now provided by the pinned marketplace URL, not a second local copy.)
3. **Verify what an installer wrote; exit 0 is not evidence.** The cloud
   plugin saga proved installs can exit 0 without installing (commits 722c653,
   f91d7d2 -- verify `installed_plugins.json`, the gold standard in
   `bootstrap-cloud.sh`). Machine-path installers still grep CLI output
   instead -- a known open weak point, not a pattern to copy.
4. **Assume publish access outlives maintainer intent.** The GSD rug-pull
   (rule source) happened AFTER the package was abandoned. A dead upstream is
   a risk, not a comfort.
5. **Never run an upstream's own sync/install scripts against your global
   state unaudited.** The abandoned Codex mirror (pre-public) showed ECC's
   sync script overwriting `core.hooksPath` and writing through symlinks into
   this repo. Wrap or redirect (see `codex-ecc-sync`).

## The public/private split

**Why public is load-bearing (do not flip to private):**

- Fresh machines HTTPS-clone before any SSH key exists (README.md, install
  step 2).
- Cloud containers clone with no GitHub grant; the optional Setup-script
  bootstrap in the repo CLAUDE.md relies on it explicitly ("the repo is
  public, so no GitHub grant is needed").
- The plugin marketplaces are pinned by public git URL from this repo's
  committed `.claude/settings.json` -- the whole first-session cloud story
  assumes anonymous clone.

**Private overlay repo -- OPEN candidate, not built.** If genuinely private
config ever needs version control (work SSH host lists, employer gitconfig
values, private skills), the design boundary it would own:

- Everything currently machine-local-by-policy: `~/.gitconfig-work` values,
  `~/.ssh/config_local`, real `agent.toml` vault names, per-model audit files
  (`Fable5.md`/`Opus4.md`), work-account `settings.json` deltas.
- It would layer ON TOP of this repo (seed-file replacement after
  `bootstrap.sh`), never fork it; this repo's templates remain the public
  contract.
- Status: candidate only. Today the answer to "where does private config go"
  is machine-local files written by `identity-setup`, and cloud containers
  are personal-account only (no work story in cloud -- open weak point).

## Reproducibility standard

Anything claimed in `README.md` must work on a fresh machine -- the repo's
public credibility is the install path. Cheapest proof: a fresh claude.ai/code
cloud container (ephemeral, clean clone every session).

```bash
# In a fresh cloud container the platform clones the repo and the committed
# .claude/settings.json declares the plugins; verify the claim chain held:
claude plugins list                          # expect ecc@ecc and superpowers@claude-plugins-official
cat ~/.claude/plugins/installed_plugins.json # ground truth, not CLI output
bin/dotfiles-tests                           # all suites green on a clean clone
```

For macOS/Linux-machine claims a container cannot prove (Homebrew, defaults,
1Password agent): label them "asserted, not demonstrated" until run on real
hardware, per operating-principles.md. Do not merge a README claim you have
not executed somewhere.

## When NOT to use this skill

| You actually want                                                 | Go to                          |
| ----------------------------------------------------------------- | ------------------------------ |
| Commit/branch/PR mechanics, gate order, hook bypass policy        | dotfiles-change-control        |
| Run the test suites as evidence, add a test, coverage gaps        | dotfiles-validation-and-qa     |
| A hook blocked you and you do not know why                        | dotfiles-debugging-playbook    |
| History of the GSD retirement / Codex mirror / cloud saga in full | dotfiles-failure-archaeology   |
| Plugin/marketplace mechanics (how installs actually work)         | claude-code-platform-reference |
| Prove a symlink/identity/plugin state from first principles       | dotfiles-verification-toolkit  |
| Recreate a machine or container from scratch                      | dotfiles-build-and-env         |

## Provenance and maintenance

Facts verified against the working tree on 2026-07-02 (HEAD = 26eae6d).
Volatile items and their one-line re-verification commands:

| Fact (as of 2026-07-02)                                                                      | Re-verify with                                               |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Tracked key files = exactly `ssh/keys/id_ed25519_personal.pub`                               | `git ls-files ssh/keys`                                      |
| public-safety suite is 3 assertions (todo.md, owner home prefix, secret regexes)             | `cat git/hooks/public-safety.test.sh`                        |
| dotfiles-tests runs all suites incl. public-safety                                           | `bin/dotfiles-tests --list`                                  |
| NOTICE lists ECC (pre-commit/pre-push; rules entry historical) and GSD redux (statusline.js) | `cat NOTICE`                                                 |
| Fable5.md/Opus4.md gitignored                                                                | `cat claude/.gitignore`                                      |
| ECC pinned URL                                                                               | `grep -n 'ECC_REPO_URL' zsh/functions.zsh`                   |
| Cloud plugin/marketplace pins                                                                | `cat .claude/settings.json`                                  |
| GSD redux repo name (NOTICE says gsd-core)                                                   | `grep -n 'open-gsd' NOTICE`                                  |
| pre-commit bypass vars (`ECC_SKIP_GIT_HOOKS`, `ECC_SKIP_PRECOMMIT`)                          | `grep -n 'ECC_SKIP' git/hooks/pre-commit git/hooks/pre-push` |
| Cloud disables commit signing                                                                | `grep -n 'gpgsign' bootstrap-cloud.sh`                       |
| CI runs suites on push to main + PRs                                                         | `head -20 .github/workflows/tests.yml`                       |
| Commit hashes cited (52f807d, 5b799dd, 9ad4dc8, 2304015, 722c653, f91d7d2, e140ab3, c0a9072) | `git show --stat <hash>`                                     |

Standing open items relevant here: private overlay repo (candidate, unbuilt);
machine-path installers trusting CLI output instead of
`installed_plugins.json`; no automated employer-name scan; ECC pre-commit /
pre-push untested; cloud has no work-account story.
