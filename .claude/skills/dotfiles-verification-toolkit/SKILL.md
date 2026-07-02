---
name: dotfiles-verification-toolkit
description: First-principles proof recipes for this dotfiles repo -- prove a symlink chain, a plugin install, a git identity resolution, an SSH key selection, a hook firing, a settings merge, a cloud snapshot, or worktree hydration, instead of trusting an exit code or an install log. Load when asked "prove it", "is it actually installed/linked/registered", "which identity/key does this repo use", "did the hook fire", "did the snapshot carry", or before claiming any install/link/config step succeeded. For interpreting a FAILED proof use dotfiles-debugging-playbook; for the packaged doctors and test runner use dotfiles-diagnostics-and-tooling.
---

# Dotfiles Verification Toolkit

Copy-paste recipes that prove state on disk instead of trusting tool output.
The repo's own history shows why: `claude plugins install` exited 0 without
installing (fixed in f91d7d2), and a symlink can dangle silently for months.
Each recipe is claim -> command -> what the output proves -> worked example.
Every worked example below was re-run in a live cloud container on 2026-07-02;
outputs quoted are real.

**[WARNING] Prime rule: exit code 0 proves the command returned, not that the
state changed. Verify the artifact the command was supposed to create.**

**[WARNING] Recipes 1-6 are read-only. Recipe 8 mutates a git repo (worktree
add) -- run it only in a scratch clone, never in the live checkout.**

## Recipe index

| #   | Claim to prove                          | Ground truth artifact                   |
| --- | --------------------------------------- | --------------------------------------- |
| 1   | Symlink chain is intact end-to-end      | `readlink -f` resolution                |
| 2   | Plugin is actually installed            | `installed_plugins.json`                |
| 3   | Repo resolves the intended git identity | `git config --show-origin`              |
| 4   | Host gets the intended SSH key          | `ssh -G` resolved config                |
| 5   | Hook is registered AND fires            | settings.json parse + synthetic payload |
| 6   | Live settings carry the template keys   | python3 key diff                        |
| 7   | Cloud snapshot carried state            | marker file timestamps (method)         |
| 8   | Worktree hydration works                | `.todos` symlink in scratch worktree    |

## 1. Prove a symlink chain end-to-end

**Claim:** `~/.claude/<asset>` resolves to the tracked file in this repo.

The intended map is `link_claude_config_dir` in
`install/common/claude-links.sh` (CLAUDE.md, operating-principles.md, rules,
skills, commands, agents, hooks, statusline.js -> `$DOTFILEDIR/claude/...`;
settings.json is a REAL machine-local file, never a symlink).

```bash
readlink -f ~/.claude/CLAUDE.md          # full-chain resolution
ls -l ~/.claude/statusline.js            # single-hop target
# Dangling-link detector (symlink exists, target does not):
[ -L ~/.claude/CLAUDE.md ] && [ ! -e ~/.claude/CLAUDE.md ] && echo "[X] DANGLING"
# settings.json must NOT be a symlink (installers write through symlinks
# into the repo -- the corruption seed_machine_local_file guards against):
[ -L ~/.claude/settings.json ] && echo "[X] settings.json is a symlink -- re-run install"
```

**Proof:** `readlink -f` prints an absolute path inside the dotfiles checkout
and exits 0. It resolves EVERY hop and fails on a broken chain; `ls -l` shows
only one hop, so use both when a link points at another link.

**Worked example (this container, 2026-07-02):**

```
$ readlink -f ~/.claude/CLAUDE.md
/home/user/dotfiles/claude/CLAUDE.md
$ ls -l ~/.claude/statusline.js
lrwxrwxrwx 1 root root 40 Jul  2 16:42 /root/.claude/statusline.js -> /home/user/dotfiles/claude/statusline.js
```

[OK] Both resolve into the repo. On a full machine, repeat for
`~/.claude-work` (same asset source, second config dir).

## 2. Prove a plugin is actually installed

**Claim:** plugin `<name>@<marketplace>` is installed and its skills load.

**Never trust the install command's exit code.** `claude plugins install` can
resolve a not-yet-fetched marketplace to "nothing to do" and exit 0 without
installing -- the silent no-op fixed in f91d7d2 and root-caused in 7cb28b7
(github-backed marketplace registered but mid-fetch). The on-disk ground truth
is `installed_plugins.json`; `ensure_plugin` in `bootstrap-cloud.sh` is the
canonical verify-then-retry implementation.

Three levels, strongest last:

```bash
# Level 1: recorded as installed (the file `ensure_plugin` verifies against)
grep -c 'superpowers@claude-plugins-official' ~/.claude/plugins/installed_plugins.json
# Level 2: the marketplace manifest actually lists it (what the resolver checks)
grep '"name"[[:space:]]*:[[:space:]]*"superpowers"' \
  ~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json
# Level 3: the plugin payload is on disk where the loader reads it
ls ~/.claude/plugins/cache/claude-plugins-official/superpowers/
```

**Proof:** level 1 nonzero + level 3 non-empty = installed. Level 2 failing
while level 1 passes means a stale manifest (update the marketplace).
[WARNING] Installed is not loaded: plugins load at CLI launch (c1c4500), so a
plugin installed mid-session is dark until the NEXT session. "Loadable now"
requires the install to predate launch -- in cloud, that means the pre-launch
declaration in `.claude/settings.json` or the Setup script, never the
SessionStart hook.

**Worked example (this container, 2026-07-02):**

```
$ python3 -m json.tool ~/.claude/plugins/installed_plugins.json | head -12
{
    "version": 2,
    "plugins": {
        "ecc@ecc": [
            {
                "scope": "user",
                "installPath": "/root/.claude/plugins/cache/ecc/ecc/2.0.0",
                "version": "2.0.0",
...
```

[OK] `ecc@ecc` 2.0.0 and `superpowers@claude-plugins-official` 6.1.0 both
recorded with install paths and git SHAs.

[WARNING] Open weak point: the machine-path installers (`ecc-install` /
`superpowers-install` in `zsh/functions.zsh`) still verify via CLI list
output, not `installed_plugins.json`. Use this recipe after them anyway.

## 3. Prove which git identity a repo resolves

**Claim:** commits in this repo will carry the intended author.

The design (`git/.gitconfig`): no base `[user]` name/email;
`user.useConfigOnly=true` plus `includeIf gitdir/i` for `~/Git/personal/` and
`~/Git/work/`. Outside those dirs, commit FAILS LOUDLY -- that failure is the
verification signal, not a bug.

```bash
cd <repo>
git config --show-origin user.email   # which FILE supplied the value
git var GIT_AUTHOR_IDENT              # exactly what a commit would record
git config commit.gpgsign             # containers: must be false or unset
```

**Proof:** `--show-origin` prints `file:<path> <email>`. The path is the
verdict: `~/.gitconfig-personal` or `~/.gitconfig-work` means the includeIf
routed correctly; a global gitconfig means an override is in play; no output
plus a `git commit` error ("Author identity unknown ... auto-detection is
disabled") means useConfigOnly is doing its job outside the convention dirs.

**Worked example (this container, 2026-07-02) -- the cloud reattribution
guard from 2304015:** the platform seeds `Claude <noreply@anthropic.com>`;
`reattribute_git_identity` in `bootstrap-cloud.sh` overwrites it with the
tracked personal identity and forces `commit.gpgsign false` (the 1Password
`op-ssh-sign` block must never reach a container).

```
$ git config --show-origin user.email
file:/root/.gitconfig   taloncjones@gmail.com
```

[OK] Personal email from the container-global gitconfig = reattribution ran.
[X] `noreply@anthropic.com` here means it did not -- run
`~/dotfiles/bootstrap-cloud.sh` before committing.

Full-chain verifier (machine installs): `bin/identity-doctor`, also wired as
`git identity`.

## 4. Prove which SSH key a host gets

**Claim:** ssh to `<alias>` offers the intended key and no other.

```bash
ssh -G Git-Personal | grep -i identityfile
ssh -G github.com   | grep -i identityfile
```

**Proof:** `ssh -G` prints the fully resolved client config WITHOUT
connecting (read-only, safe anywhere). Expected per
`ssh/configs/personal/config_personal`: both `Git-Personal` and bare
`github.com` resolve to `~/.ssh/id_ed25519_personal` with
`identitiesonly yes` -- the pin that stops the 1Password agent offering the
work key to personal clones. Work aliases (in the machine-local
`~/.ssh/config_work` chain) must resolve to `~/.ssh/id_ed25519_work`.

**Worked example:** [INFO] not runnable in this container (no ssh client on
PATH; cloud bootstrap deliberately skips the ssh layer). On a machine expect:

```
identityfile ~/.ssh/id_ed25519_personal
```

One line only -- multiple identityfile lines mean the pin is missing and key
offer order decides, which is the failure this config exists to prevent.
This expected output is asserted from the tracked config, not demonstrated
live; `bin/identity-doctor` runs the live check on a real machine.

## 5. Prove a hook is registered AND fires

**Claim:** a guard hook (e.g. `block_secrets.py`) is both wired into
settings.json and actually blocks.

Registration alone proves nothing (the file could be broken); firing alone
proves nothing (the harness may never invoke it). Prove both, the way
`claude/hooks/claude-hooks.test.sh` does.

**Part A -- registered** (parse, do not eyeball):

```bash
SETTINGS_PATH="$HOME/.claude/settings.json" REQUIRED_HOOK=block_secrets.py python3 - <<'PY'
import json, os, sys
cfg = json.load(open(os.environ["SETTINGS_PATH"]))
required = os.environ["REQUIRED_HOOK"]
cmds = [h.get("command", "")
        for section in cfg.get("hooks", {}).values()
        for entry in section
        for h in entry.get("hooks", [])]
hit = [c for c in cmds if c.endswith("hooks/" + required)]
print("[OK] registered:" if hit else "[X] NOT registered:", hit or required)
sys.exit(0 if hit else 1)
PY
```

**Part B -- fires** (synthetic payload through the hook binary, from the repo
root; exit 2 = block, 0 = allow, hooks fail open on exceptions):

```bash
printf '%s\n' '{"tool_name":"Read","tool_input":{"file_path":".env.local"}}' \
  | claude/hooks/block_secrets.py; echo "exit=$?"
```

**Worked example (this container, 2026-07-02):**

```
Blocked: '.env.local' contains secrets
Use environment variables or a secret manager instead.
exit=2
```

and the allow case (`.env.example`) exits 0. [OK] Registered and firing.
For the full assertion matrix run the suite: `sh claude/hooks/claude-hooks.test.sh`
(repo root; it also drift-checks both machine-local settings.json copies).
Git hooks are separate plumbing: registration there is
`git config core.hooksPath` -> `~/.config/git/hooks` (recipe 8 proves one
firing live).

## 6. Prove the settings merge result

**Claim:** live `~/.claude/settings.json` carries every template key (the
dotfiles hooks, statusLine, permissions, env) -- not just the plugin keys the
installers write.

Why this drifts: seed-once design -- see dotfiles-architecture-contract
Decision 1 for the rationale. The CANONICAL drift script (both config dirs,
nested plugin-key logic) lives in dotfiles-diagnostics-and-tooling "Settings
drift inspection"; the one-liner below is the quick single-dir, top-level-key
variant of it.

```bash
python3 -c "
import json
tmpl = json.load(open('$HOME/dotfiles/claude/settings.json.tmpl'))
live = json.load(open('$HOME/.claude/settings.json'))
missing = [k for k in tmpl if k not in live]
extra   = [k for k in live if k not in tmpl]
print('missing from live:', missing or 'none')
print('extra in live:', extra or 'none')
"
```

**Proof:** `missing: none` = every template top-level key is present. `extra`
entries are normal (installer/platform keys the merge preserves). This is a
KEY-level compare -- a hook removed from a list inside `hooks` will not show;
for that depth run the settings-drift section of
`claude/hooks/claude-hooks.test.sh` (asserts `account_guard.py` inside
SessionStart) or diff the `hooks` subtree the same way.

**Worked example (this container, 2026-07-02, after reconcile):**

```
missing from live: none
extra in live: none
```

Adjust the template path if the repo is not at `~/dotfiles` (here it was
`/home/user/dotfiles`).

## 7. Prove a cloud snapshot actually carried state

**Claim:** the Setup-script filesystem snapshot persists across sessions, so
pre-launch installs are paid once.

[INFO] Method, not verified fact: proving this needs two sessions and could
not be executed inside this single session.

**Method -- marker file across sessions:**

```bash
# Session A (or in the Setup script itself):
date -u +%FT%TZ > ~/.dotfiles-snapshot-marker
# Session B (a NEW session, later):
cat ~/.dotfiles-snapshot-marker
uptime -s   # this container's boot time
```

**Proof:** marker timestamp EARLIER than session B's boot time = the file
predates this container, so state carried via snapshot. Marker missing =
snapshot expired or was never taken -- expect the SessionStart self-heal
(`.claude/hooks/session-start.sh` -> `bootstrap-cloud.sh`) to have re-run,
and plugins to be dark until the session after it.

**Free natural marker (no setup needed):** `installedAt` in
`installed_plugins.json`. In this container the timestamps read
`2026-07-02T16:42:...Z`; an `installedAt` earlier than the current boot proves
the plugin cache itself rode the snapshot.

## 8. Prove worktree hydration works

**Claim:** `git worktree add` triggers the global `post-checkout` hook
(`git/hooks/post-checkout`), which symlinks `.todos` from the new worktree to
the main checkout (maintenance mode).

[WARNING] `git worktree add` mutates the repo it runs in. Do this in a scratch
CLONE, never the live checkout. The demo is self-contained and disposable:

```bash
S=$(mktemp -d)
git clone -q ~/dotfiles "$S/main"
cd "$S/main"
mkdir -p .todos/pending .todos/completed          # untracked backlog to hydrate
git config core.hooksPath ~/dotfiles/git/hooks    # clone lacks the global hooksPath
git worktree add -q ../scratch -b tmp/hydration-check
ls -l ../scratch/.todos
# teardown
git worktree remove ../scratch --force
git branch -D tmp/hydration-check
cd / && rm -rf "$S"
```

**Proof:** the hook prints `[post-checkout] hydrated .todos -> <main>/.todos`
and `ls -l` shows a symlink into the MAIN clone -- both prerequisites proven
at once (hooksPath wiring works, hook logic works).

**Worked example (this container, 2026-07-02):**

```
[post-checkout] hydrated .todos -> .../wt-demo/main/.todos
lrwxrwxrwx 1 root root 101 Jul  2 17:33 ../scratch/.todos -> .../wt-demo/main/.todos
```

On a real machine, first prove the wiring on the live repo (read-only):
`git config core.hooksPath` must print `~/.config/git/hooks`, and
`readlink -f ~/.config/git/hooks` must land in `<dotfiles>/git/hooks`. In
this container hooksPath was unset (cloud bootstrap does not install the git
layer) -- which is exactly why the demo sets it explicitly in the clone.
Static shape checks live in `git/hooks/post-checkout.test.sh`; the ECC-vendored
`pre-commit`/`pre-push` in the same dir are UNTESTED (open gap).

## When NOT to use this skill

| You want                                                                                    | Use instead                      |
| ------------------------------------------------------------------------------------------- | -------------------------------- |
| To diagnose WHY a proof failed (symptom -> triage)                                          | dotfiles-debugging-playbook      |
| The packaged doctors (`identity-doctor`, `dotfiles-repair`) and `bin/dotfiles-tests` runner | dotfiles-diagnostics-and-tooling |
| What counts as evidence for landing a CHANGE; test-suite inventory                          | dotfiles-validation-and-qa       |
| Background on plugins/marketplaces/config-dir mechanics                                     | claude-code-platform-reference   |
| Rebuilding a machine or container from scratch                                              | dotfiles-build-and-env           |
| The history behind these recipes (silent no-op saga etc.)                                   | dotfiles-failure-archaeology     |

## Provenance and maintenance

Facts verified live in a cloud container on 2026-07-02, HEAD 26eae6d. Volatile
facts and one-line re-checks:

| Fact (as of 2026-07-02)                                                           | Re-verify                                                        |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Symlink map lives in `link_claude_config_dir`                                     | `grep -n 'ln -sf' install/common/claude-links.sh`                |
| `installed_plugins.json` at `~/.claude/plugins/installed_plugins.json`, format v2 | `grep -n INSTALLED_PLUGINS_JSON bootstrap-cloud.sh`              |
| Plugin versions ECC 2.0.0 / superpowers 6.1.0 (container snapshot; WILL drift)    | `python3 -m json.tool ~/.claude/plugins/installed_plugins.json`  |
| Marketplace manifest path `.claude-plugin/marketplace.json`                       | `grep -n marketplace.json bootstrap-cloud.sh`                    |
| identity design: useConfigOnly + includeIf, no base [user] email                  | `grep -n -A4 'useConfigOnly' git/.gitconfig`                     |
| Hook exit-2-blocks contract and payload shape                                     | `head -80 claude/hooks/claude-hooks.test.sh`                     |
| Template keys / seed-once behavior                                                | `grep -n seed_machine_local_file install/common/claude-links.sh` |
| Cloud reconcile merges plugin keys, template wins elsewhere                       | `grep -n -A10 'PLUGIN_KEYS' bootstrap-cloud.sh`                  |
| post-checkout hydrates `.todos` in maintenance mode                               | `grep -n 'hydrated .todos' git/hooks/post-checkout`              |
| Cited commits exist (f91d7d2, 7cb28b7, c1c4500, 2304015)                          | `git show <hash> --stat`                                         |
| ssh pin: `Git-Personal` and `github.com` -> personal key                          | `grep -n -A4 '^Host' ssh/configs/personal/config_personal`       |

If a re-verify command returns nothing, the anchor moved -- fix this file
before trusting it again.
