---
name: dotfiles-cloud-first-campaign
description: The executable campaign runbook for making cloud/ephemeral Claude Code sessions (claude.ai/code containers) a first-class primary environment for this dotfiles setup. Load when planning or executing cloud-parity work -- "make cloud sessions first-class", "roll out plugins to another repo's cloud environment", "why aren't plugins loaded on session 1", "should the Setup script or the settings declaration carry the install", "close the machine/cloud parity gap", "is ECC rules vendoring still needed". Phased with decision gates, exact commands, expected outputs, and fenced wrong paths with incident hashes. NOT for diagnosing a single sick container (dotfiles-diagnostics-and-tooling cloud-doctor), one-time environment rebuild (dotfiles-build-and-env), the settled incident history itself (dotfiles-failure-archaeology), or Claude Code platform mechanics in general (claude-code-platform-reference).
---

# Dotfiles cloud-first campaign

Executable, decision-gated runbook for advancing cloud/ephemeral sessions from
"works with babysitting" to first-class primary environment. The dotfiles repo
itself is already cloud-solved (plugins on session 1, settled 2026-07-02);
this skill hardens that state, rolls it out to other repos, and closes the
remaining machine/cloud parity gaps. Every phase ends in a measurable gate --
success is `cloud-doctor.sh` exit 0 on session 1, never "looks fine".

[WARNING] Front-loaded fences -- these are settled incidents, do not re-fight them
(full narratives: dotfiles-failure-archaeology; verify any hash with
`git show <hash> --stat`):

| Wrong path                                                          | Why it fails                                                                                      | Incident                                                              |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Post-launch plugin install (SessionStart hook) as PRIMARY           | Plugins load at CLI launch; a hook-installed plugin is dark until the NEXT session                | c1c4500                                                               |
| Trusting `claude plugins install` exit code                         | Can exit 0 without installing; only `installed_plugins.json` is ground truth                      | 722c653, f91d7d2                                                      |
| Blind `sleep` timers around marketplace warmup                      | Github-backed marketplace can be registered but mid-fetch; poll its on-disk manifest instead      | 7cb28b7                                                               |
| Uncapped retry backoff                                              | 8 raw doublings = 254s/phase; two phases x two plugins blows the Setup script's ~5-min budget     | da54e17 (cap 15s)                                                     |
| Symlinking `settings.json` into the repo                            | Installers write through the symlink and pollute the repo; must be machine-local (seed-once)      | see `install/common/claude-links.sh` `seed_machine_local_file` header |
| Copying the 1Password signing block into a container                | `op-ssh-sign` is absent in containers; every commit would fail. Copy name+email ONLY, gpgsign off | 2304015                                                               |
| Letting installers create `settings.json` first and calling it done | They write only plugin keys; dotfiles hooks/statusLine/permissions never land without reconcile   | 910f2bc                                                               |

## When NOT to use this skill

| You actually want                                       | Use instead                      |
| ------------------------------------------------------- | -------------------------------- |
| Diagnose one container that is misbehaving right now    | dotfiles-diagnostics-and-tooling |
| Build a fresh machine or container from nothing         | dotfiles-build-and-env           |
| The blow-by-blow history of the cloud plugin saga       | dotfiles-failure-archaeology     |
| How plugins/marketplaces/config dirs work platform-wide | claude-code-platform-reference   |
| Day-to-day plugin ops on an installed machine           | dotfiles-run-and-operate         |
| How to land a campaign change through the gates         | dotfiles-change-control          |
| Prove one fact (a symlink chain, one plugin install)    | dotfiles-verification-toolkit    |

## Vocabulary (once)

- **Cloud container**: the ephemeral VM claude.ai/code creates per environment; `~/.claude` dies with it. Detected by `CLAUDE_CODE_REMOTE=true`.
- **Pre-launch placement**: anything that runs or exists BEFORE the Claude CLI starts (committed `.claude/settings.json`, the environment's Setup script). Only pre-launch placements make plugins usable on session 1.
- **Setup script**: the claude.ai/code environment config field whose commands run pre-launch; its disk writes are filesystem-snapshotted and reused by later sessions.
- **Declaration**: the `enabledPlugins` + `extraKnownMarketplaces` block in a repo's committed `.claude/settings.json`; the platform installs declared plugins natively at session start.
- **Self-heal**: the repo SessionStart hook `.claude/hooks/session-start.sh` running `bootstrap-cloud.sh` post-launch to repair snapshot/cache expiry. Never the primary path (fence c1c4500).

## Phase 0 -- baseline audit (fresh dotfiles-repo cloud session)

Goal: prove the CURRENT state before changing anything. Run all of this
read-only in a fresh claude.ai/code session on the dotfiles repo.

**0.1 Confirm you are in a cloud container.**

```bash
echo "${CLAUDE_CODE_REMOTE:-unset}"
```

Expected: `true`. If `unset` -> you are on a real machine; this phase's gates
do not apply -- use dotfiles-run-and-operate for machine ops and skip to
Phase 3.

**0.2 Mechanized gate: cloud-doctor.**

```bash
"$CLAUDE_PROJECT_DIR/.claude/skills/dotfiles-diagnostics-and-tooling/scripts/cloud-doctor.sh"
```

(Outside a dotfiles-repo session, substitute the checkout path, e.g.
`~/dotfiles/.claude/skills/.../cloud-doctor.sh`.) Expected: `[OK]` on every
line, final line `cloud-doctor: all checks passed.`, exit 0. It checks, in
order: symlinked assets, machine-local `settings.json` with `account_guard.py`
in SessionStart, both plugin ids in `installed_plugins.json`, git author not
the platform default, python3/node on PATH.

If any `[X]` -> run `"$CLAUDE_PROJECT_DIR/bootstrap-cloud.sh"` once, re-run the
doctor. If it still fails -> dotfiles-debugging-playbook.

**0.3 SessionStart hook output.** The dotfiles repo's committed
`.claude/settings.json` registers `.claude/hooks/session-start.sh` on matcher
`startup|resume`; it is gated on `CLAUDE_CODE_REMOTE` and runs
`bootstrap-cloud.sh`. On a healthy warm container the hook's transcript lines
are (verbatim from `bootstrap-cloud.sh` source):

```
[bootstrap-cloud] Linking Claude assets into /root/.claude...
[claude-links] Reconciled settings.json (SessionStart: account_guard.py).
[bootstrap-cloud] Ensuring plugin marketplaces + installs...
[bootstrap-cloud] OK: ecc@ecc already installed.
[bootstrap-cloud] OK: superpowers@claude-plugins-official already installed.
[bootstrap-cloud] Reconciled settings.json (SessionStart: account_guard.py).
[bootstrap-cloud] Done. Plugins and settings load with the NEXT session;
[bootstrap-cloud] an already-running session picks up skills/commands only.
```

Branch lines:

- `OK: installed <id> (attempt N/8).` instead of `already installed` -> cold
  install just happened THIS session. The plugin's skills/commands load next
  session (fence c1c4500). Expected on a first session without pre-launch
  placement; a problem only if it recurs every session (snapshot not persisting).
- `<marketplace> manifest not warm yet (attempt N/8); retrying in Xs...` ->
  the deterministic manifest wait engaging (7cb28b7); fine unless it exhausts.
- `!! FAILED: <id> not installed after 8 attempts.` -> recover manually:
  `claude plugins install <id>`, then verify per 0.4. If the marketplace is
  missing: `claude plugin marketplace add https://github.com/affaan-m/ECC.git`
  (ECC) or `claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git`.
- `WARNING: python3 not on PATH` / `node not on PATH` -> hooks/statusline
  degraded; container image problem, not a dotfiles bug.

**0.4 Plugin ground truth.**

```bash
python3 -c "import json;d=json.load(open('$HOME/.claude/plugins/installed_plugins.json'));print(sorted(d['plugins']))"
```

Expected: `['ecc@ecc', 'superpowers@claude-plugins-official']`. Missing file
or missing id -> plugins are NOT installed regardless of what any install
command printed (fence f91d7d2). Re-run bootstrap-cloud.

**0.5 Git author.**

```bash
git config --global user.name; git config --global user.email
```

Expected: the identity from `git/personal/.gitconfig-personal` (currently
`Talon Jones` / `taloncjones@gmail.com`), never `Claude <noreply@anthropic.com>`.
Also expect `git config --global commit.gpgsign` -> `false` (reattribution
disables signing; fence 2304015). Platform default still present -> re-run
bootstrap-cloud (`reattribute_git_identity` only overrides the platform
default; a real identity is never clobbered).

Gate to pass Phase 0: cloud-doctor exit 0 AND plugin skills actually invocable
in the CURRENT session (try one, e.g. a superpowers skill). Present-on-disk
but not invocable = post-launch install; acceptable only for the self-heal
path.

Baseline (2026-07-02, fresh session-1 dotfiles-repo container, NO Setup
script): full Phase 0 pass. cloud-doctor exit 0 (all checks `[OK]`);
symlink-audit `--cloud` all 9 entries OK, exit 0; `bin/dotfiles-tests` 9/9
suites green; both required plugin ids at `"scope": "project"` in
`installed_plugins.json` with their skills/hooks live in session 1 (ECC
GateGuard fired on the first Bash call; superpowers injected at SessionStart;
project skills invocable) -- the declaration path (option 1) carried the
install with zero per-environment config. SessionStart hook printed the
healthy-warm transcript (`already installed` for both ids). Git author
reattributed, `commit.gpgsign` false. Account sync landed atlassian,
frontend-design, security-guidance at `"scope": "user"`; the three
project-excluded plugins stayed disabled (see Phase 1, now verified).

Observed baseline (2026-07-02, session 1 of a NON-dotfiles repo): the
hook-only rollout (latam-bess: no Setup script, no committed declaration;
that repo's committed SessionStart hook clones this dotfiles repo and runs
`bootstrap-cloud.sh`) was audited fresh the same day. The
asset/identity/settings layer was fully live SAME-session: cloud-doctor exit
0 and symlink-audit `--cloud` 9/9 OK via the hook-cloned checkout,
`bin/dotfiles-tests` 9/9 suites green, git author reattributed (gpgsign
false), statusline registered and resolving, permissions block present after
reconcile, and guard hooks active in that very session (emoji_guard.py
blocked a PostToolUse Write probe); symlinked skills/commands also loaded
same-session. Plugin skills did NOT: ecc@ecc and
superpowers@claude-plugins-official landed in `installed_plugins.json` only
post-launch at `"scope": "user"` and no plugin skill was invocable (fence
c1c4500 reconfirmed). Account sync wrote 13 ids into `enabledPlugins` but
installed ZERO account plugins, because no marketplace was registered
pre-launch (see the Phase 1 hard constraint). The project-layer exclusion
override was not exercisable there (non-dotfiles repo, nothing
account-installed); it is verified only by the dotfiles-repo sessions above
and in Phase 1. Net: the hook-based rollout carries the whole
asset/identity/settings layer same-session -- only plugin skills wait.

## Phase 1 -- placement decision (ranked menu)

Decide, per environment/repo, WHERE the plugin install lives. Ranked:

| Rank | Placement                                     | Timing      | Scope           | Session 1? | Choose when                                                                     |
| ---- | --------------------------------------------- | ----------- | --------------- | ---------- | ------------------------------------------------------------------------------- |
| 1    | Committed `.claude/settings.json` declaration | pre-launch  | per-repo        | YES        | The repo can commit Claude config. Zero per-environment setup. PRIMARY.         |
| 2    | Environment Setup script (two-liner below)    | pre-launch  | per-environment | YES        | Repo does NOT commit the declaration, or you want the slow install snapshotted. |
| 3    | SessionStart hook (self-heal)                 | post-launch | per-repo        | NO         | NEVER primary (fence c1c4500). Keep as repair for snapshot/cache expiry.        |

**Option 1** is what the dotfiles repo ships (commit 8d4507f, the final design
of the cloud saga). The platform installs declared plugins natively pre-launch
from the cloned repo.

**Option 2** -- paste into the environment's Setup script field (verbatim from
`CLAUDE.md` and the `bootstrap-cloud.sh` header; repo is public, no GitHub
grant needed):

```bash
git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || git -C "$HOME/dotfiles" pull
"$HOME/dotfiles/bootstrap-cloud.sh"
```

Budget note: the Setup script has a ~5-minute cap; bootstrap-cloud's retry
backoff is capped at 15s / 8 attempts precisely to stay under it (da54e17).
Do not add uncapped waits to this script.

**Option 3** exists in this repo as `.claude/hooks/session-start.sh` -- gated
on `CLAUDE_CODE_REMOTE=true`, matcher `startup|resume`, idempotent. It repairs
a container whose snapshot expired; anything it installs is usable NEXT
session only.

**Account-level plugin sync (observed 2026-07-02, live container).** The
platform ALSO syncs the claude.ai account's own plugin selections into cloud
containers at `"scope": "user"` in `installed_plugins.json` -- but ONLY for
plugins whose marketplace is already registered in the container (observed:
official-marketplace plugins installed; plugins from unregistered marketplaces
like claude-code-workflows landed in `enabledPlugins` yet stayed uninstalled --
the enabled-but-dark class again). Hard constraint (2026-07-02, non-dotfiles
audit): "already registered" means registered BEFORE launch. Account sync
runs at session start, and a hook-based bootstrap (option 3) registers
marketplaces only post-launch -- so under hook-only rollout the platform
synced 13 ids into `enabledPlugins` yet installed ZERO account plugins; even
official-marketplace ones stayed enabled-but-dark. Option 3 can NEVER deliver
account-synced plugins. Only pre-launch placements (option 1 declaration or
option 2 Setup script) make account sync effective. Consequences: (a)
personal official-market plugins (code-review, code-simplifier,
security-guidance, ...) need NO repo change beyond a pre-launch placement
that registers the official marketplace (the option 1 declaration already
pins it), the account carries the selection; (b) to make account-enabled plugins from
OTHER marketplaces work in cloud, pin that marketplace's git URL in the repo's
`.claude/settings.json` `extraKnownMarketplaces`; (c) to EXCLUDE an
account-synced plugin from this repo's sessions, set it to `false` in the
repo's `.claude/settings.json` `enabledPlugins` (project layer overrides user
-- VERIFIED 2026-07-02 on two fresh session-1 dotfiles-repo containers: all
three excluded plugins reported `disabled` in `claude plugin list` despite
`true` in the user layer. Nuance: the platform still INSTALLS them -- they appear at
`"scope": "project"` in `installed_plugins.json` with payloads on disk --
but they load nothing; disabled-but-installed is the expected shape, so do
not read their presence in the install record as a failed exclusion). This
repo excludes `telegram` (unused) and the official `code-review` and
`code-simplifier` plugins (name-collide with the built-in `/code-review` that
the tracked `co-review` skill invokes, and with the built-in `/simplify` +
ECC's simplifier). Verify sync state per container: grep `"scope": "user"` in
`~/.claude/plugins/installed_plugins.json` and compare against
`enabledPlugins` in `~/.claude/settings.json`.

**Env-var alternative: ruled out.** The environment config's variables field
carries data, not execution -- nothing in the platform installs plugins from
an env var, and no pre-launch code can run from one. Env vars remain useful
only for toggles (e.g. `CLAUDE_CONFIG_DIR`), not placement. (Asserted from
platform behavior observed through the saga, not from vendor docs -- re-test
if the platform grows a declarative install feature.)

Decision gate: placement chosen and recorded per repo/environment. For any
repo you touch, options 1+3 together (declaration primary, hook self-heal) is
the proven pattern; option 2 is the belt-and-suspenders overlay.

## Phase 2 -- rollout to other repos

Goal: any OTHER repo you work on in claude.ai/code gets plugins on session 1.

**2.1 Decide committed vs local Claude config.** `bin/setup-claude` adds
`CLAUDE.md`, `AGENTS.md`, and `.claude/` to that repo's `.git/info/exclude`
(local-only, never committed). Tradeoff:

| Approach                       | Session-1 plugins in cloud?                            | Cost                                                                  |
| ------------------------------ | ------------------------------------------------------ | --------------------------------------------------------------------- |
| Commit `.claude/settings.json` | YES (declaration clones with the repo)                 | Needs repo-owner buy-in; content must be public-safe for public repos |
| `setup-claude` (local-only)    | NO (excluded config never reaches the container clone) | Zero repo footprint; MUST pair with the Phase 1 option 2 Setup script |

**2.2 What to commit (declaration snippet, verbatim from this repo's
`.claude/settings.json`).** Commit exactly this into the target repo's
`.claude/settings.json` (merge into an existing file rather than clobbering):

```json
{
  "enabledPlugins": {
    "ecc@ecc": true,
    "superpowers@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "ecc": {
      "source": {
        "source": "git",
        "url": "https://github.com/affaan-m/ECC.git"
      }
    },
    "claude-plugins-official": {
      "source": {
        "source": "git",
        "url": "https://github.com/anthropics/claude-plugins-official.git"
      }
    }
  }
}
```

Do NOT copy the dotfiles repo's `hooks.SessionStart` block into other repos:
it points at `$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh`, which only
exists here. Other repos get the self-heal indirectly by pairing with the
option 2 Setup script (which clones the dotfiles and runs bootstrap-cloud).

**2.3 What stays per-environment.** Assets/settings/git identity are NOT
covered by the declaration -- only plugins are. A non-dotfiles repo that wants
the full Claude layer (symlinked CLAUDE.md/skills/hooks, reconciled settings,
reattributed git author) needs the option 2 Setup script in its environment.

Rollout gate, per repo: open a genuinely FRESH environment on that repo (new
environment, not a resumed one) and pass the Phase 0 checklist -- cloud-doctor
exit 0 (if the Setup script placed the full layer) or, minimum bar for
declaration-only repos, step 0.4 plus one plugin skill invocable in session 1.

## Phase 3 -- parity gaps to close

Each gap: status, first step, measurable gate. Statuses are honest -- 3.2 is
closed (2026-07-02), 3.1 closes in the sibling plugin-verification PR, and two
are open (decision not yet made). Do not report an open one as fixed.

**3.1 Machine-path installs verify against `installed_plugins.json` -- CANDIDATE.**
`ecc-install`/`superpowers-install` (`zsh/functions.zsh`, functions at
`ecc-install` and `superpowers-install`) grep CLI output; `bootstrap-cloud.sh
ensure_plugin` is the gold standard (manifest wait + `installed_plugins.json`
verify). First step: port `plugin_installed`/`ensure_plugin` semantics into
the zsh functions, parameterized by config dir -- machines have TWO
(`~/.claude` and `~/.claude-work`), each with its own
`plugins/installed_plugins.json`. Gate: with a deliberately unreachable
marketplace, `ecc-install` returns non-zero and says so; `bin/dotfiles-tests`
stays green.

**3.2 `reconcile_claude_settings` on machines -- CLOSED (2026-07-02).** The
merge now lives in `install/common/claude-links.sh` as
`reconcile_claude_settings_file` and runs per config dir inside
`link_claude_config_dir`, so every machine `update`/link (and
`dotfiles-repair` step 2) closes template drift automatically -- plugin-installer
keys (`enabledPlugins`, `extraKnownMarketplaces`) are unioned with live state
winning, unknown keys preserved. `bootstrap-cloud.sh
reconcile_claude_settings` delegates to the shared function (its documented
`[bootstrap-cloud] Reconciled settings.json ...` line is unchanged; the link
step now additionally prints a `[claude-links]` reconcile line). The gate held
in `install/claude-links.test.sh` (registered in `bin/dotfiles-tests`): a
scratch config dir holding only installer-written keys gains the template
hooks/permissions/statusLine while those keys survive, plus corrupt-rebuild,
idempotency, and missing-template cases. Verified live on a cloud container
(`bootstrap-cloud.sh --no-plugins`): both reconcile lines print, plugin keys
survive.

**3.3 Work-account cloud story -- OPEN.** Cloud containers are personal-account
only by design (`bootstrap-cloud.sh` header: skips `~/.claude-work`
deliberately). No decision exists on whether work repos ever run in
claude.ai/code. First step: answer that question; if yes, spec
`CLAUDE_CONFIG_DIR` handling and identity boundaries BEFORE writing code
(work values are machine-local secrets -- see dotfiles-external-positioning).
Gate: a recorded decision; no implementation until then.

**3.4 ECC rules vendoring for cloud -- OPEN.** Evidence: nothing auto-loads
`~/.claude/rules` (`claude/CLAUDE.md` never references it; only some ECC
skills read it), and cloud containers already carry the FULL upstream rules
tree at `~/.claude/plugins/marketplaces/ecc/rules/` (verified 2026-07-02).
The vendored copy in `claude/rules/` is untracked (`claude/rules/.gitignore`)
and exists only via `ecc-sync-rules`. Decision options:

| Option                                                   | Upside                   | Risk                                                                 |
| -------------------------------------------------------- | ------------------------ | -------------------------------------------------------------------- |
| Stop vendoring; point consumers at the marketplace clone | One copy, zero sync code | Any ECC skill hardcoding `~/.claude/rules/...` paths breaks          |
| Keep vendoring; symlink ECC language dirs to the clone   | Paths unchanged          | Symlink into installer-managed cache; cache relocation dangles links |

Decision gate BEFORE either: enumerate actual consumers --
`grep -rn "claude/rules\|\.claude/rules" ~/.claude/plugins/cache/ecc/` -- and
test both config dirs on a machine. Until then, vendoring stays.

## Promotion protocol (non-negotiable)

Every campaign change lands through the normal gates -- no side doors:

1. Branch + PR against main (dotfiles-change-control).
2. `bin/dotfiles-tests` green locally; CI (`.github/workflows/tests.yml`)
   green on the PR.
3. Anything touching `bootstrap-cloud.sh`, `.claude/settings.json`, or
   `.claude/hooks/session-start.sh` is proven in a GENUINELY FRESH cloud
   environment (create a new environment; a resumed snapshot proves nothing
   about cold start) before the PR is declared done.
4. Definition of done: `cloud-doctor.sh` exit 0 on SESSION 1 of that fresh
   environment, with a plugin skill invoked successfully in that same session.
   "Looks fine", green exit codes, and install-command output are not
   evidence (fences f91d7d2, 722c653).

## Provenance and maintenance

All facts verified against the repo on 2026-07-02 (HEAD at 26eae6d). Volatile
items and their one-line re-verification commands:

| Fact                                                                                     | Re-verify with                                                                                                          |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Setup script two-liner                                                                   | `grep -n -A2 "Paste into the Setup script" bootstrap-cloud.sh`                                                          |
| Declaration snippet / plugin ids / marketplace URLs                                      | `cat .claude/settings.json`                                                                                             |
| Retry constants (8 attempts, 15s cap)                                                    | `grep -n "PLUGIN_RETRIES\|PLUGIN_RETRY_MAX_DELAY" bootstrap-cloud.sh`                                                   |
| `[bootstrap-cloud]` output lines quoted in Phase 0                                       | `grep -n "bootstrap-cloud\]" bootstrap-cloud.sh`                                                                        |
| SessionStart hook gating + matcher                                                       | `cat .claude/hooks/session-start.sh; python3 -c "import json;print(json.load(open('.claude/settings.json'))['hooks'])"` |
| Reconcile prints `SessionStart: account_guard.py` (template-derived)                     | `python3 -c "import json;c=json.load(open('claude/settings.json.tmpl'));print(c['hooks']['SessionStart'])"`             |
| cloud-doctor path and checks                                                             | `ls .claude/skills/dotfiles-diagnostics-and-tooling/scripts/`                                                           |
| Incident hashes (c1c4500, f91d7d2, 722c653, 7cb28b7, da54e17, 2304015, 910f2bc, 8d4507f) | `git show <hash> --stat`                                                                                                |
| Personal identity values                                                                 | `grep -e name -e email git/personal/.gitconfig-personal`                                                                |
| `setup-claude` excludes `.claude/`                                                       | `grep -n "info/exclude" -B3 bin/setup-claude`                                                                           |
| ECC rules tree inside marketplace clone (cloud)                                          | `ls ~/.claude/plugins/marketplaces/ecc/rules/`                                                                          |
| Phase 3 statuses (candidate/open)                                                        | Re-read `zsh/functions.zsh` install fns and `bootstrap-cloud.sh` -- if 3.1/3.2 landed, update this file                 |

Upstream URLs pinned here (github.com/affaan-m/ECC, anthropics/
claude-plugins-official, taloncjones/dotfiles) drift if forks/renames happen;
the authoritative copies live in `bootstrap-cloud.sh` and
`.claude/settings.json` -- trust those over this page.
