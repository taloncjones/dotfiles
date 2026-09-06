# ECC Hook Account Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop every ECC 2.2.1 hook enabled by the settings template from reading or writing state under the other account's config dir, prove it hermetically, and keep every hook that can be scoped enabled.

**Architecture:** The settings template gains a `{{CLAUDE_CONFIG_DIR}}` token in `env` string values; `reconcile_claude_settings_file` substitutes it with the absolute config dir it writes into, so `ECC_AGENT_DATA_HOME` differs per account on every launch path. Five hook ids with no usable scoping knob join `ECC_DISABLED_HOOKS`. A new table-driven suite, `claude/hooks/ecc-hook-isolation.test.sh`, drives the installed hook scripts through ECC's own flag gate under a fake `$HOME` and asserts where state lands, with falsifiable controls.

**Tech Stack:** POSIX `sh` test suites (existing pattern), python3 for JSON handling inside shell, the installed ECC plugin clone (read-only, node), `bin/dotfiles-tests` runner.

**Spec:** `docs/specs/2026-09-06-ecc-hook-account-isolation.md`

## Global Constraints

- Never modify anything under `~/.claude/plugins/marketplaces/ecc/` (or any ECC clone). Tests read it; nothing writes it.
- Never read or write the real `~/.claude` or `~/.claude-work` from a test. Every fixture lives under `mktemp -d`.
- Do not touch `claude/hooks/herdr_orch_core.py`, `claude/skills/herdr-orchestration/`, `claude/skills/co-review/`, `git/hooks/commit-msg`, or `install/common/codex-*` (a parallel branch owns them).
- Do not run `rm` outside `trap 'rm -rf "$TMP"' EXIT` cleanup of your own mktemp dir.
- No emojis, no AI attribution, ASCII only, LF endings. Commit format `<scope>: <summary>` (imperative, under 75 chars).
- Commit with `git -C <worktree>` from the worktree; never on `main`.
- Exact exclusion set (order stylistic): `session-start:plan-canvas-sessions,stop:plan-canvas-pending,post:bash:command-log-audit,post:bash:command-log-cost,post:skill:track,pre:mcp-health-check,post:mcp-health-check`.
- Exact token: `{{CLAUDE_CONFIG_DIR}}`. Substituted only inside `env` string values, with `os.path.dirname(os.path.abspath(dest))`.
- Exact new env key and template value: `ECC_AGENT_DATA_HOME` = `{{CLAUDE_CONFIG_DIR}}`. No other new key (the mcp-health-check knobs are not used; see the spec, D1).
- `plan-canvas-isolation.test.sh` is not modified.
- Every task ends with `bin/dotfiles-tests` green for the suites it touches.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `claude/settings.json.tmpl` | modify `env` | seven-id exclusion; one tokenised key |
| `install/common/claude-links.sh` | modify `reconcile_claude_settings_file` python | token substitution in `env` |
| `install/claude-links.test.sh` | modify | unit case for substitution; link-path delivery; two-dir difference |
| `claude/hooks/claude-hooks.test.sh` | modify two blocks | template pin (seven ids, token key); live per-dir env checks |
| `claude/hooks/ecc-hook-isolation.test.sh` | create | hermetic proof: excluded hooks inert, scoped hooks land in their own dir, controls, flag gate |
| `bin/dotfiles-tests` | modify `SUITES` | register the new suite |
| `CLAUDE.md` | modify one bullet | document ids, token, keys, suites |
| `.todos/pending/2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di.md` | append (machine-local, not committed) | completion note: audit table and upstream draft |

---

### Task 1: Token substitution in the settings reconcile, and the template values

**Files:**
- Modify: `install/common/claude-links.sh` (python block inside `reconcile_claude_settings_file`, after `result = dict(tmpl)` loop and before the `os.makedirs` write)
- Modify: `claude/settings.json.tmpl` (`env` block)
- Test: `install/claude-links.test.sh`

**Interfaces:**
- Consumes: `reconcile_claude_settings_file <template> <dest>` and `link_claude_config_dir <dir>` from `install/common/claude-links.sh` (unchanged signatures).
- Produces: a reconciled `settings.json` whose `env` string values have `{{CLAUDE_CONFIG_DIR}}` replaced by `os.path.dirname(os.path.abspath(dest))`. Later tasks read the template's `env` and apply the same replacement to compute expected live values.

- [ ] **Step 1: Add the failing unit case for substitution to `install/claude-links.test.sh`**

Insert after the existing unit cases (before the line `# --- link_claude_config_dir integration ---` or, if that comment is absent, before `CFG="$TMP/cfg"`):

```sh
# 6. Config-dir token: env string values carry {{CLAUDE_CONFIG_DIR}} in the
# template; reconcile replaces it with the absolute dir it writes into, and
# only inside env (a token elsewhere is left alone). No token survives in env.
TOKTMPL="$TMP/tok-tmpl.json"
cat >"$TOKTMPL" <<'EOF'
{
  "env": {
    "ECC_AGENT_DATA_HOME": "{{CLAUDE_CONFIG_DIR}}",
    "ECC_FIXTURE_MULTI": "a:{{CLAUDE_CONFIG_DIR}}/x:{{CLAUDE_CONFIG_DIR}}/y",
    "PLAIN": "unchanged"
  },
  "statusLine": {"type": "command", "command": "echo {{CLAUDE_CONFIG_DIR}}"}
}
EOF
mkdir -p "$TMP/tok-cfg"
reconcile_claude_settings_file "$TOKTMPL" "$TMP/tok-cfg/settings.json" >/dev/null 2>&1
if jget "$TMP/tok-cfg/settings.json" "d['env']['ECC_AGENT_DATA_HOME'] == '$TMP/tok-cfg'"; then
    pass "reconcile substitutes the config-dir token with the dest dir"
else
    fail "reconcile substitutes the config-dir token with the dest dir"
fi
if jget "$TMP/tok-cfg/settings.json" "d['env']['ECC_FIXTURE_MULTI'] == 'a:$TMP/tok-cfg/x:$TMP/tok-cfg/y'"; then
    pass "reconcile substitutes every token occurrence in one value"
else
    fail "reconcile substitutes every token occurrence in one value"
fi
if jget "$TMP/tok-cfg/settings.json" "d['env']['PLAIN'] == 'unchanged' and d['statusLine']['command'] == 'echo {{CLAUDE_CONFIG_DIR}}'"; then
    pass "reconcile leaves non-env values and token-free env values alone"
else
    fail "reconcile leaves non-env values and token-free env values alone"
fi
if ! grep -q '{{CLAUDE_CONFIG_DIR}}' "$TMP/tok-cfg/settings.json" 2>/dev/null || jget "$TMP/tok-cfg/settings.json" "all('{{CLAUDE_CONFIG_DIR}}' not in v for v in d['env'].values())"; then
    pass "reconcile leaves no token in env"
else
    fail "reconcile leaves no token in env"
fi
```

- [ ] **Step 2: Run the links suite to verify the new cases fail**

Run: `sh install/claude-links.test.sh`
Expected: the four new cases print `FAIL`; every pre-existing case still passes.

- [ ] **Step 3: Implement the substitution in `install/common/claude-links.sh`**

In the python heredoc of `reconcile_claude_settings_file`, insert immediately before `os.makedirs(os.path.dirname(dest_path), exist_ok=True)`:

```python
# Per-config-dir values: the template is shared by ~/.claude and
# ~/.claude-work, and Claude Code does not expand variables inside env
# values, so a value that must differ per account carries this token and
# is resolved here to the directory settings.json is written into. env
# only: no other template key is substituted.
CONFIG_DIR_TOKEN = "{{CLAUDE_CONFIG_DIR}}"
config_dir = os.path.dirname(os.path.abspath(dest_path))
env = result.get("env")
if isinstance(env, dict):
    result["env"] = {
        k: (v.replace(CONFIG_DIR_TOKEN, config_dir) if isinstance(v, str) else v)
        for k, v in env.items()
    }
```

Also update the function's header comment (the block starting `# seed_machine_local_file copies the template only when...`) by adding one line after the `template-owned keys` bullet:

```
#   - env string values have {{CLAUDE_CONFIG_DIR}} replaced by the absolute
#     config dir the file lands in (per-account ECC state paths);
```

- [ ] **Step 4: Run the links suite to verify the unit cases pass**

Run: `sh install/claude-links.test.sh`
Expected: all cases PASS (the link-path Plan Canvas assertion still passes because the template is unchanged so far).

- [ ] **Step 5: Add the failing link-path cases**

In `install/claude-links.test.sh`, replace the block

```sh
if jget "$CFG/settings.json" "{x.strip().lower() for x in d['env']['ECC_DISABLED_HOOKS'].split(',') if x.strip()} == {'session-start:plan-canvas-sessions', 'stop:plan-canvas-pending'}"; then
    pass "link path delivers the Plan Canvas hook exclusion"
else
    fail "link path delivers the Plan Canvas hook exclusion"
fi
```

with

```sh
if jget "$CFG/settings.json" "{x.strip().lower() for x in d['env']['ECC_DISABLED_HOOKS'].split(',') if x.strip()} == {'session-start:plan-canvas-sessions', 'stop:plan-canvas-pending', 'post:bash:command-log-audit', 'post:bash:command-log-cost', 'post:skill:track', 'pre:mcp-health-check', 'post:mcp-health-check'}"; then
    pass "link path delivers the seven-id ECC hook exclusion"
else
    fail "link path delivers the seven-id ECC hook exclusion"
fi
if jget "$CFG/settings.json" "d['env']['ECC_AGENT_DATA_HOME'] == '$CFG'"; then
    pass "link path scopes the ECC data home to this config dir"
else
    fail "link path scopes the ECC data home to this config dir"
fi
# A second config dir (the work account) must receive its own path, not a
# copy of the first dir's.
CFG2="$TMP/cfg-work"
mkdir -p "$CFG2"
link_claude_config_dir "$CFG2" >/dev/null 2>&1
if jget "$CFG2/settings.json" "d['env']['ECC_AGENT_DATA_HOME'] == '$CFG2'"; then
    pass "link path gives a second config dir its own ECC data home"
else
    fail "link path gives a second config dir its own ECC data home"
fi
```

- [ ] **Step 6: Run the links suite to verify the link-path cases fail**

Run: `sh install/claude-links.test.sh`
Expected: `FAIL  link path delivers the seven-id ECC hook exclusion` and `FAIL  link path scopes the ECC data home ...` (template still lacks the values); the second-dir case fails too.

- [ ] **Step 7: Update the template `env` block in `claude/settings.json.tmpl`**

Replace the `env` object with exactly:

```json
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1m]",
    "CLAUDE_CODE_DISABLE_TELEMETRY": "1",
    "ECC_CONTEXT_MONITOR_COST_WARNINGS": "0",
    "ECC_DISABLED_HOOKS": "session-start:plan-canvas-sessions,stop:plan-canvas-pending,post:bash:command-log-audit,post:bash:command-log-cost,post:skill:track,pre:mcp-health-check,post:mcp-health-check",
    "ECC_AGENT_DATA_HOME": "{{CLAUDE_CONFIG_DIR}}"
  },
```

- [ ] **Step 8: Run the links suite and the syntax checks**

Run: `sh install/claude-links.test.sh && bash -n install/common/claude-links.sh && python3 -c "import json; json.load(open('claude/settings.json.tmpl'))"`
Expected: all PASS; both syntax checks silent.

The hooks suite (`claude/hooks/claude-hooks.test.sh`) will now FAIL its `canvas: template excludes exactly the two Plan Canvas hooks` case. That is expected and is fixed in Task 2; do not run `bin/dotfiles-tests` as a gate for this task.

- [ ] **Step 9: Commit**

```bash
git -C "$WT" add install/common/claude-links.sh install/claude-links.test.sh claude/settings.json.tmpl
git -C "$WT" commit -m "install: Scope ECC state paths per config dir via a template token"
```

---

### Task 2: Drift checks for the exclusion set and the scoped env keys

**Files:**
- Modify: `claude/hooks/claude-hooks.test.sh` (the block commented `# Plan Canvas exclusion:` around line 349, and the live-settings block commented `# Exclusion drift:` around line 484)

**Interfaces:**
- Consumes: the template `env` values from Task 1.
- Produces: FAIL messages other tests grep for. Exact strings:
  - `FAIL  isolation: template excludes exactly the seven account-leaking ECC hook ids`
  - `FAIL  isolation: template carries the config-dir token in ECC_AGENT_DATA_HOME`
  - `FAIL  settings: <dir> does not exclude the account-leaking ECC hooks (run update to reconcile)`
  - `FAIL  settings: <dir> does not scope ECC state to this config dir (run update to reconcile)`

- [ ] **Step 1: Replace the template pin block**

Replace the whole block from the comment `# Plan Canvas exclusion: ECC 2.2.1 keys Canvas state on ~/.claude/plan-canvas` through its closing `fi` with:

```sh
# Account-leaking ECC hooks: ECC 2.2.1 resolves several hook state paths
# through os.homedir() or $HOME/.claude, ignoring CLAUDE_CONFIG_DIR, so both
# accounts would share them. Hooks with an upstream env knob are scoped per
# config dir by the token key below; the seven ids here have no usable knob
# and are switched off. Exact set: nothing else may ride along, none may be
# missing.
# See claude/hooks/ecc-hook-isolation.test.sh for the behavioural proof.
if python3 - <<'PY'
import json
import sys

env = json.load(open("claude/settings.json.tmpl")).get("env") or {}
ids = {s.strip().lower() for s in env.get("ECC_DISABLED_HOOKS", "").split(",") if s.strip()}
want = {
    "session-start:plan-canvas-sessions",
    "stop:plan-canvas-pending",
    "post:bash:command-log-audit",
    "post:bash:command-log-cost",
    "post:skill:track",
}
sys.exit(0 if ids == want else 1)
PY
then
    printf 'PASS  isolation: template excludes exactly the seven account-leaking ECC hook ids\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  isolation: template excludes exactly the seven account-leaking ECC hook ids\n' >&2
    FAIL=$((FAIL + 1))
fi

# The per-account key must carry the literal token in the template;
# reconcile_claude_settings_file resolves it per config dir.
if python3 - <<'PY'
import json
import sys

env = json.load(open("claude/settings.json.tmpl")).get("env") or {}
sys.exit(0 if env.get("ECC_AGENT_DATA_HOME") == "{{CLAUDE_CONFIG_DIR}}" else 1)
PY
then
    printf 'PASS  isolation: template carries the config-dir token in ECC_AGENT_DATA_HOME\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  isolation: template carries the config-dir token in ECC_AGENT_DATA_HOME\n' >&2
    FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Replace the live-settings exclusion block**

Inside the `for settings_dir in "$HOME/.claude" "$HOME/.claude-work"; do` loop, replace the block starting at the comment `# Exclusion drift: env is template-owned, so a reconciled machine must` through the `fi` that prints `does not exclude the Plan Canvas hooks` with:

```sh
        # Exclusion drift: env is template-owned, so a reconciled machine must
        # carry all seven excluded ids. Superset check so a machine-local extra
        # id does not fail here (the reconcile would drop it on the next
        # update anyway).
        if SETTINGS_PATH="$settings_dir/settings.json" python3 - <<'PY'
import json
import os
import sys

env = json.load(open(os.environ["SETTINGS_PATH"])).get("env") or {}
ids = {s.strip().lower() for s in env.get("ECC_DISABLED_HOOKS", "").split(",") if s.strip()}
want = {
    "session-start:plan-canvas-sessions",
    "stop:plan-canvas-pending",
    "post:bash:command-log-audit",
    "post:bash:command-log-cost",
    "post:skill:track",
}
for missing in sorted(want - ids):
    print("  missing exclusion: " + missing)
sys.exit(0 if want <= ids else 1)
PY
        then
            printf 'PASS  settings: %s excludes the account-leaking ECC hooks\n' "$settings_dir"
            PASS=$((PASS + 1))
        else
            printf 'FAIL  settings: %s does not exclude the account-leaking ECC hooks (run update to reconcile)\n' "$settings_dir" >&2
            FAIL=$((FAIL + 1))
        fi

        # Scope drift: the per-account key must resolve to THIS config dir
        # (abspath, not realpath -- reconcile uses abspath too), and no
        # unsubstituted token may remain anywhere in env.
        if SETTINGS_PATH="$settings_dir/settings.json" SETTINGS_DIR="$settings_dir" python3 - <<'PY'
import json
import os
import sys

env = json.load(open(os.environ["SETTINGS_PATH"])).get("env") or {}
cfg = os.path.abspath(os.environ["SETTINGS_DIR"])
tmpl_env = json.load(open("claude/settings.json.tmpl")).get("env") or {}
ok = True
want = str(tmpl_env.get("ECC_AGENT_DATA_HOME", "")).replace("{{CLAUDE_CONFIG_DIR}}", cfg)
got = env.get("ECC_AGENT_DATA_HOME")
if got != want:
    print("  ECC_AGENT_DATA_HOME: live=" + repr(got) + " want=" + repr(want))
    ok = False
for key, value in env.items():
    if isinstance(value, str) and "{{CLAUDE_CONFIG_DIR}}" in value:
        print("  unsubstituted token in " + key)
        ok = False
sys.exit(0 if ok else 1)
PY
        then
            printf 'PASS  settings: %s scopes ECC state to this config dir\n' "$settings_dir"
            PASS=$((PASS + 1))
        else
            printf 'FAIL  settings: %s does not scope ECC state to this config dir (run update to reconcile)\n' "$settings_dir" >&2
            FAIL=$((FAIL + 1))
        fi
```

- [ ] **Step 3: Run the hooks suite sandboxed and against a synthetic live dir**

Run sandboxed (no live settings, both live checks SKIP):

```sh
HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh
```

Expected: all PASS, including the two new `isolation:` template cases; `SKIP  settings: no live .../settings.json` for both dirs.

Run against a reconciled synthetic dir (this is what the contract's negative cases build on):

```sh
d="$(mktemp -d)"; mkdir -p "$d/.claude"
DOTFILEDIR="$(pwd)"; export DOTFILEDIR; . install/common/claude-links.sh
reconcile_claude_settings_file claude/settings.json.tmpl "$d/.claude/settings.json" >/dev/null
HOME="$d" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep 'settings: '
```

Expected: `PASS  settings: <d>/.claude registers every template hook`, `... permissions match template`, `... excludes the account-leaking ECC hooks`, `... scopes ECC state to this config dir`.

- [ ] **Step 4: Verify both negative paths fail with the exact messages**

```sh
d="$(mktemp -d)"; mkdir -p "$d/.claude"
python3 -c "import json,sys; t=json.load(open('claude/settings.json.tmpl')); e=t['env']; e['ECC_DISABLED_HOOKS']=e['ECC_DISABLED_HOOKS'].replace(',post:skill:track',''); e['ECC_AGENT_DATA_HOME']='/elsewhere'; json.dump(t, open(sys.argv[1]+'/settings.json','w'), indent=2)" "$d/.claude"
HOME="$d" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E 'FAIL  settings'
```

Expected: both lines present:
`FAIL  settings: <d>/.claude does not exclude the account-leaking ECC hooks (run update to reconcile)` and
`FAIL  settings: <d>/.claude does not scope ECC state to this config dir (run update to reconcile)`.

- [ ] **Step 5: Run the suites that this task and Task 1 touch**

Run: `sh -n claude/hooks/claude-hooks.test.sh && HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh && sh install/claude-links.test.sh && sh claude/hooks/plan-canvas-isolation.test.sh`
Expected: all green. The Plan Canvas suite reads the template's `ECC_DISABLED_HOOKS` and its flag-gate case `both Plan Canvas ids answer no` still holds with the seven-id value.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add claude/hooks/claude-hooks.test.sh
git -C "$WT" commit -m "claude: Drift-check the seven-id ECC exclusion and per-dir data home"
```

---

### Task 3: Isolation suite, part A: harness, excluded hooks, flag gate, registration

**Files:**
- Create: `claude/hooks/ecc-hook-isolation.test.sh`
- Modify: `bin/dotfiles-tests` (`SUITES` list, after `sh claude/hooks/plan-canvas-isolation.test.sh`)

**Interfaces:**
- Consumes: ECC scripts `scripts/hooks/run-with-flags.js`, `scripts/hooks/bash-hook-dispatcher.js`, `scripts/hooks/check-hook-enabled.js`, `scripts/hooks/skill-run-tracker.js`, `scripts/hooks/post-bash-command-log.js`, `scripts/hooks/mcp-health-check.js` from the installed clone; the template `env`.
- Produces (used by Task 4): shell functions `fresh_home <label>` (prints a fresh fake HOME containing `.claude` and `.claude-work`), `template_env <cfgdir>` (prints `KEY=VALUE` lines from the template env with the token substituted), `run_gated <cfgdir> <home> <cwd> <envmode> <id> <script> <profiles>` and `run_bash_dispatcher <cfgdir> <home> <cwd> <envmode>` where `envmode` is `template` or `none`; helpers `pass`, `fail`, `files_under <dir>` (lists regular files, sorted).

Notes for the implementer:
- `post:bash:command-log-audit` and `post:bash:command-log-cost` are hosted only by ECC's Bash dispatcher (`bash-hook-dispatcher.js post`), which gates them with `isHookEnabled`; the script itself has no gate and its exported `run()` ignores the mode when called by `run-with-flags`. Drive the dispatcher. The dispatcher may re-serialise stdout, so the excluded-case assertion for these two ids is exit 0 plus no log file, not byte-identical stdout.
- `post:skill:track` is run through `run-with-flags.js`, which requires the module and calls `run(raw)`; when excluded it echoes stdin untouched, so byte-identical stdout is asserted there.
- Node's `os.homedir()` honours `$HOME` on POSIX, so the fake HOME redirects every `~/.claude` path.

- [ ] **Step 1: Write the suite skeleton with the excluded-hook cases**

Create `claude/hooks/ecc-hook-isolation.test.sh`:

```sh
#!/bin/sh
# ecc-hook-isolation.test.sh -- prove the ECC hooks that key state on
# ~/.claude cannot cross accounts under the settings template env.
#
# ECC 2.2.1 resolves several hook state paths through os.homedir() or
# $HOME/.claude and never consults CLAUDE_CONFIG_DIR, so on a dual-account
# machine (~/.claude personal, ~/.claude-work work, one $HOME) a work session
# would write into, or read from, the personal dir. The template handles the
# class two ways, and this suite proves both:
#   excluded -- ids with no scoping knob are in ECC_DISABLED_HOOKS:
#               post:bash:command-log-audit, post:bash:command-log-cost,
#               post:skill:track, pre:mcp-health-check, post:mcp-health-check
#               (the two Plan Canvas ids have their own suite);
#   scoped   -- ids that read ECC_AGENT_DATA_HOME get it resolved to the
#               account's config dir by the settings reconcile:
#               stop:cost-tracker, post:session-activity-tracker,
#               stop:session-end, pre:compact, session:start.
# Every hook is driven through ECC's own flag gate (run-with-flags.js or the
# Bash dispatcher) against a fake $HOME under mktemp holding fake .claude and
# .claude-work dirs. The real ~/.claude* and the ECC clone are never written.
# Controls run the same fixtures with the template env removed and must show
# the leak; a control that passes without the fix is a suite bug.
#
# Re-check after an ECC upgrade: grep the clone's scripts/hooks for
# os.homedir(), process.env.HOME, and getClaudeDir/getSessionsDir, map each
# hit to its hook id in hooks/hooks.json and the dispatchers, and add a row.
#
# Knobs: ECC_PLUGIN_ROOT overrides ECC root resolution.
#        ECC_HOOK_TEST_REQUIRE_ECC=1 turns the no-ECC SKIP into a FAIL.

set -u

TMPL=claude/settings.json.tmpl
if [ ! -f "$TMPL" ]; then
    echo "FAIL: $TMPL not found (run from repo root)" >&2
    exit 2
fi

require_ecc="${ECC_HOOK_TEST_REQUIRE_ECC:-0}"
missing() {
    if [ "$require_ecc" = 1 ]; then
        echo "FAIL: $1" >&2
        exit 1
    fi
    echo "SKIP: $1"
    exit 0
}

if ! command -v node >/dev/null 2>&1; then
    missing "node not installed; ECC hooks are node scripts"
fi
if ! command -v python3 >/dev/null 2>&1; then
    missing "python3 not installed; fixture and assertions need it"
fi

ECC_ROOT="${ECC_PLUGIN_ROOT:-}"
if [ -z "$ECC_ROOT" ]; then
    for cand in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/ecc" \
                "$HOME/.claude/plugins/marketplaces/ecc" \
                "$HOME/.claude-work/plugins/marketplaces/ecc"; do
        if [ -f "$cand/scripts/hooks/run-with-flags.js" ]; then
            ECC_ROOT="$cand"
            break
        fi
    done
fi
if [ ! -f "$ECC_ROOT/scripts/hooks/run-with-flags.js" ]; then
    missing "ECC plugin scripts not installed (looked under the Claude config dirs)"
fi
for f in scripts/hooks/check-hook-enabled.js scripts/hooks/bash-hook-dispatcher.js \
         scripts/hooks/post-bash-command-log.js scripts/hooks/skill-run-tracker.js \
         scripts/hooks/cost-tracker.js scripts/hooks/session-activity-tracker.js \
         scripts/hooks/session-end.js scripts/hooks/pre-compact.js \
         scripts/hooks/session-start.js scripts/hooks/mcp-health-check.js; do
    if [ ! -f "$ECC_ROOT/$f" ]; then
        echo "FAIL: ECC layout changed: $ECC_ROOT/$f missing" >&2
        exit 1
    fi
done

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ecc-hook-isolation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo"
N=0

# fresh_home <label>: a new fake HOME with empty personal and work config
# dirs. Every scenario gets its own so one hook's writes cannot leak into
# another scenario's assertions.
fresh_home() {
    N=$((N + 1))
    h="$TMP/$1-$N/home"
    mkdir -p "$h/.claude" "$h/.claude-work"
    printf '%s' "$h"
}

# template_env <cfgdir>: the template env as KEY=VALUE lines with the
# config-dir token resolved for <cfgdir>, exactly as reconcile does. Only the
# ECC keys are exported into hook runs; model and telemetry keys are inert.
template_env() {
    python3 - "$TMPL" "$1" <<'PY'
import json, sys
env = json.load(open(sys.argv[1])).get("env") or {}
for k, v in env.items():
    if k.startswith("ECC_") and isinstance(v, str):
        print(k + "=" + v.replace("{{CLAUDE_CONFIG_DIR}}", sys.argv[2]))
PY
}

# env_args <cfgdir> <envmode>: env(1) assignments for a hook run. "template"
# applies the resolved template env; "none" is the control (nothing set, and
# the knobs are explicitly cleared so the hooks fall back to ~/.claude).
env_args() {
    if [ "$2" = template ]; then
        template_env "$1"
    else
        printf 'ECC_DISABLED_HOOKS=\nECC_AGENT_DATA_HOME=\n'
    fi
}

# run_gated <cfgdir> <home> <cwd> <envmode> <id> <script> <profiles>
# Runs one hook through ECC's flag gate exactly as hooks.json does, reading
# $TMP/payload from stdin. Profile and enabled flag are pinned so
# machine-level ECC settings cannot produce false results.
# stdout -> $TMP/out, stderr -> $TMP/err.
run_gated() {
    env_args "$1" "$4" >"$TMP/envfile"
    (
        cd "$3" && env -i PATH="$PATH" HOME="$2" CLAUDE_CONFIG_DIR="$1" \
            CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            CLAUDE_SESSION_ID=fixture-session \
            $(cat "$TMP/envfile") \
            node "$ECC_ROOT/scripts/hooks/run-with-flags.js" "$5" "$6" "$7"
    ) <"$TMP/payload" >"$TMP/out" 2>"$TMP/err"
}

# run_bash_dispatcher <cfgdir> <home> <cwd> <envmode>: the PostToolUse Bash
# dispatcher, which hosts the two command-log ids.
run_bash_dispatcher() {
    env_args "$1" "$4" >"$TMP/envfile"
    (
        cd "$3" && env -i PATH="$PATH" HOME="$2" CLAUDE_CONFIG_DIR="$1" \
            CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            $(cat "$TMP/envfile") \
            node "$ECC_ROOT/scripts/hooks/bash-hook-dispatcher.js" post
    ) <"$TMP/payload" >"$TMP/out" 2>"$TMP/err"
}

# files_under <dir>: regular files below <dir>, relative, sorted; empty when
# the dir does not exist.
files_under() {
    [ -d "$1" ] || return 0
    (cd "$1" && find . -type f | sort)
}

# --- excluded hooks: inert under the template env, live without it ---

printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo FIXTURE-CMD"}}' >"$TMP/payload"
ok=1
for acct in .claude .claude-work; do
    h="$(fresh_home cmdlog)"
    run_bash_dispatcher "$h/$acct" "$h" "$TMP/repo" template; rc=$?
    [ "$rc" = 0 ] || ok=0
    [ -z "$(files_under "$h/.claude")$(files_under "$h/.claude-work")" ] || ok=0
done
if [ "$ok" = 1 ]; then pass "excluded: command-log audit/cost write nothing under either config dir"; else fail "excluded: command-log audit/cost write nothing under either config dir"; fi

h="$(fresh_home cmdlog-control)"
run_bash_dispatcher "$h/.claude-work" "$h" "$TMP/repo" none
if [ -f "$h/.claude/bash-commands.log" ] && [ -f "$h/.claude/cost-tracker.log" ] \
        && grep -q 'FIXTURE-CMD' "$h/.claude/bash-commands.log" \
        && [ -z "$(files_under "$h/.claude-work")" ]; then
    pass "control: without the exclusion a work session logs commands into the personal dir"
else
    fail "control: without the exclusion a work session logs commands into the personal dir"
fi

printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"fixture-skill"}}' >"$TMP/payload"
ok=1
for acct in .claude .claude-work; do
    h="$(fresh_home skill)"
    run_gated "$h/$acct" "$h" "$TMP/repo" template post:skill:track scripts/hooks/skill-run-tracker.js standard,strict
    cmp -s "$TMP/out" "$TMP/payload" || ok=0
    [ -z "$(files_under "$h/.claude")$(files_under "$h/.claude-work")" ] || ok=0
done
if [ "$ok" = 1 ]; then pass "excluded: skill-run tracker passes the payload through and writes nothing"; else fail "excluded: skill-run tracker passes the payload through and writes nothing"; fi

h="$(fresh_home skill-control)"
run_gated "$h/.claude-work" "$h" "$TMP/repo" none post:skill:track scripts/hooks/skill-run-tracker.js standard,strict
if [ -f "$h/.claude/state/skill-runs.jsonl" ] && grep -q 'fixture-skill' "$h/.claude/state/skill-runs.jsonl" \
        && [ -z "$(files_under "$h/.claude-work")" ]; then
    pass "control: without the exclusion a work session records skill runs into the personal dir"
else
    fail "control: without the exclusion a work session records skill runs into the personal dir"
fi

# mcp-health-check: excluded because its config-path knob cannot name the
# personal account's HOME-root .claude.json. Fixture: the personal dir
# declares a server with no transport (ECC treats it as unsupported: no
# network, no spawn) and a work session asks about it.
mcp_fixture() {
    printf '{"mcpServers":{"personalsrv":{"note":"fixture, no transport"}}}' >"$1/.claude/settings.json"
}
printf '{"hook_event_name":"PreToolUse","tool_name":"mcp__personalsrv__ping","tool_input":{}}' >"$TMP/payload"
ok=1
for acct in .claude .claude-work; do
    h="$(fresh_home mcp)"; mcp_fixture "$h"
    run_gated "$h/$acct" "$h" "$TMP/repo" template pre:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict
    cmp -s "$TMP/out" "$TMP/payload" || ok=0
    [ ! -e "$h/.claude/mcp-health-cache.json" ] || ok=0
    [ ! -e "$h/.claude-work/mcp-health-cache.json" ] || ok=0
done
if [ "$ok" = 1 ]; then pass "excluded: mcp-health-check passes the payload through and writes no cache"; else fail "excluded: mcp-health-check passes the payload through and writes no cache"; fi

h="$(fresh_home mcp-control)"; mcp_fixture "$h"
run_gated "$h/.claude-work" "$h" "$TMP/repo" none pre:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict
if [ -f "$h/.claude/mcp-health-cache.json" ] && grep -q 'personalsrv' "$h/.claude/mcp-health-cache.json" \
        && [ ! -e "$h/.claude-work/mcp-health-cache.json" ]; then
    pass "control: without the exclusion a work session probes the personal MCP server and caches under the personal dir"
else
    fail "control: without the exclusion a work session probes the personal MCP server and caches under the personal dir"
fi

# --- flag gate: exactly the seven ids are off; neighbours stay on ---
DISABLED="$(python3 -c 'import json; print(json.load(open("claude/settings.json.tmpl")).get("env", {}).get("ECC_DISABLED_HOOKS", ""))')"
enabled_is() {
    got="$(CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
        ECC_DISABLED_HOOKS="$DISABLED" node "$ECC_ROOT/scripts/hooks/check-hook-enabled.js" "$1" 2>/dev/null)"
    [ "$got" = "$2" ]
}
ok=1
for id in session-start:plan-canvas-sessions stop:plan-canvas-pending \
          post:bash:command-log-audit post:bash:command-log-cost post:skill:track \
          pre:mcp-health-check post:mcp-health-check; do
    enabled_is "$id" no || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: the seven excluded ids answer no"; else fail "flag gate: the seven excluded ids answer no"; fi
ok=1
for id in stop:session-end stop:cost-tracker pre:bash:dispatcher post:dispatcher:sync \
          pre:bash:gateguard-fact-force session:start; do
    enabled_is "$id" yes || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: TDD, dispatcher, GateGuard, and scoped ids stay enabled"; else fail "flag gate: TDD, dispatcher, GateGuard, and scoped ids stay enabled"; fi

# SCOPED_HOOKS_MARKER (Task 4 inserts the scoped-hook cases here)

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
```

- [ ] **Step 2: Run the suite with ECC required and read every line**

Run: `ECC_HOOK_TEST_REQUIRE_ECC=1 sh claude/hooks/ecc-hook-isolation.test.sh`
Expected: 8 PASS, 0 FAIL. If a control fails, inspect `$TMP/err` by temporarily adding `cat "$TMP/err"` after the run, fix the payload, and remove the debug line. If the `excluded:` case fails because the dispatcher's other post-bash hooks wrote a file, tighten the assertion to the two log basenames rather than "no files" and note why in a comment.

- [ ] **Step 3: Verify the SKIP and FAIL exits without ECC**

```sh
out="$(ECC_PLUGIN_ROOT=/nonexistent sh claude/hooks/ecc-hook-isolation.test.sh)"; echo "rc=$? $out"
ECC_PLUGIN_ROOT=/nonexistent ECC_HOOK_TEST_REQUIRE_ECC=1 sh claude/hooks/ecc-hook-isolation.test.sh; echo "rc=$?"
```

Expected: first prints `rc=0 SKIP: ECC plugin scripts not installed ...`; second prints `FAIL: ...` and `rc=1`.

- [ ] **Step 4: Verify the suite is falsifiable against the template**

```sh
d="$(mktemp -d)"; mkdir -p "$d/claude"
python3 -c "import json,sys; t=json.load(open('claude/settings.json.tmpl')); t['env'].pop('ECC_DISABLED_HOOKS', None); json.dump(t, open(sys.argv[1], 'w'), indent=2)" "$d/claude/settings.json.tmpl"
(cd "$d" && ECC_HOOK_TEST_REQUIRE_ECC=1 sh "$OLDPWD/claude/hooks/ecc-hook-isolation.test.sh"); echo "rc=$?"
```

Expected: `FAIL  excluded: command-log audit/cost write nothing under either config dir`, `FAIL  excluded: skill-run tracker passes the payload through and writes nothing`, `FAIL  excluded: mcp-health-check passes the payload through and writes no cache`, `FAIL  flag gate: the seven excluded ids answer no`, `rc=1`.

- [ ] **Step 5: Register the suite**

In `bin/dotfiles-tests`, insert `sh claude/hooks/ecc-hook-isolation.test.sh` on its own line directly after `sh claude/hooks/plan-canvas-isolation.test.sh`.

Run: `bin/dotfiles-tests --list | grep ecc-hook-isolation && sh -n claude/hooks/ecc-hook-isolation.test.sh`
Expected: the line is listed; syntax check silent.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add claude/hooks/ecc-hook-isolation.test.sh bin/dotfiles-tests
git -C "$WT" commit -m "claude: Add ECC hook isolation suite for the excluded hook ids"
```

---

### Task 4: Isolation suite, part B: scoped hooks land in their own config dir

**Files:**
- Modify: `claude/hooks/ecc-hook-isolation.test.sh` (replace the line `# SCOPED_HOOKS_MARKER ...`)

**Interfaces:**
- Consumes: `fresh_home`, `run_gated`, `files_under`, `pass`, `fail`, `$TMP`, `$TMP/repo`, `$TMP/payload` from Task 3.
- Produces: nothing new; the suite is complete after this task.

Fixture facts (from the ECC 2.2.1 source; the suite FAILs on a layout change):
- `stop:cost-tracker` appends `<ECC_AGENT_DATA_HOME>/metrics/costs.jsonl` on any Stop payload; with no transcript it records zero usage. It looks for `<os.tmpdir()>/harness-cost-<session_id>.json`; the fixture session id never has one.
- `post:session-activity-tracker` needs `tool_name` in the payload and `CLAUDE_SESSION_ID` (set by `run_gated`) and appends `<data-home>/metrics/tool-usage.jsonl`.
- `stop:session-end` writes `<data-home>/session-data/<date>-<id>-session.tmp`; without a transcript it uses a mechanical summary and never calls an LLM.
- `pre:compact` appends `<data-home>/session-data/compaction-log.txt`.
- `session:start` is registered through `session-start-bootstrap.js`, which only resolves the plugin root and delegates to `run-with-flags.js session:start scripts/hooks/session-start.js minimal,standard,strict`; the suite drives that delegated call. It creates `<data-home>/session-data` and `<data-home>/skills/learned` and writes a lease under `$HOME/.local/share/ecc-homunculus` (the fake HOME; out of class, allowed).
- `stop:evaluate-session` and `post:ecc-metrics-bridge` are not driven: the first writes `<data-home>/skills/learned`, which on a real machine is one symlink into this repo for both dirs (isolation is nominal), and the second only reads.

- [ ] **Step 1: Add the scoped-hook cases**

Replace the `# SCOPED_HOOKS_MARKER` line with:

```sh
# --- scoped hooks: state lands under the account's own config dir ---

# scoped_case <label> <id> <script> <profiles> <payload-json> <expected-relpath>
# Under the template env: running as the work account creates the expected
# file under .claude-work and nothing under .claude; running as the personal
# account does the reverse. Control (env removed): the work account writes
# under .claude, proving the env is what scopes it.
scoped_case() {
    printf '%s' "$5" >"$TMP/payload"
    ok=1
    h="$(fresh_home scoped-work)"
    run_gated "$h/.claude-work" "$h" "$TMP/repo" template "$2" "$3" "$4"
    [ -e "$h/.claude-work/$6" ] || ok=0
    [ -z "$(files_under "$h/.claude")" ] || ok=0
    h="$(fresh_home scoped-personal)"
    run_gated "$h/.claude" "$h" "$TMP/repo" template "$2" "$3" "$4"
    [ -e "$h/.claude/$6" ] || ok=0
    [ -z "$(files_under "$h/.claude-work")" ] || ok=0
    if [ "$ok" = 1 ]; then pass "scoped: $1"; else fail "scoped: $1"; fi

    h="$(fresh_home scoped-control)"
    run_gated "$h/.claude-work" "$h" "$TMP/repo" none "$2" "$3" "$4"
    if [ -e "$h/.claude/$6" ] && [ -z "$(files_under "$h/.claude-work")" ]; then
        pass "control: without the env a work session puts $1 under the personal dir"
    else
        fail "control: without the env a work session puts $1 under the personal dir"
    fi
}

scoped_case "cost-tracker metrics" stop:cost-tracker scripts/hooks/cost-tracker.js minimal,standard,strict \
    '{"hook_event_name":"Stop","session_id":"fixture-session","cwd":"'"$TMP/repo"'","stop_hook_active":false}' \
    metrics/costs.jsonl
scoped_case "session-activity metrics" post:session-activity-tracker scripts/hooks/session-activity-tracker.js standard,strict \
    '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP/repo/fixture.txt"'"}}' \
    metrics/tool-usage.jsonl
scoped_case "session-end summary" stop:session-end scripts/hooks/session-end.js minimal,standard,strict \
    '{"hook_event_name":"Stop","session_id":"fixture-session","cwd":"'"$TMP/repo"'","stop_hook_active":false}' \
    session-data
scoped_case "compaction log" pre:compact scripts/hooks/pre-compact.js standard,strict \
    '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"fixture-session"}' \
    session-data/compaction-log.txt
scoped_case "session-start data dir" session:start scripts/hooks/session-start.js minimal,standard,strict \
    '{"hook_event_name":"SessionStart","source":"startup","session_id":"fixture-session","cwd":"'"$TMP/repo"'"}' \
    session-data

```

- [ ] **Step 2: Run the suite with ECC required**

Run: `ECC_HOOK_TEST_REQUIRE_ECC=1 sh claude/hooks/ecc-hook-isolation.test.sh`
Expected: 18 PASS, 0 FAIL, wall time under 30 s.

Known adjustment points if a case fails:
- `session-start data dir`: if `session:start` creates a directory (not a file) under the other config dir, that is allowed; `files_under` only lists regular files. If it creates a file under `.claude` when running as work, capture `$TMP/err`, identify the ECC path, and record it as a new audit row before deciding whether to add it to the exclusion (do not silently loosen the assertion).
- `session-end summary`: the file name embeds today's date and a short id; the assertion checks the `session-data` directory exists under the right account, which `ensureDir` guarantees before any write.

- [ ] **Step 3: Re-run the falsifiability checks from Task 3 Step 3 and Step 4**

Expected: unchanged results. SKIP without ECC; without the template's `ECC_DISABLED_HOOKS` the excluded-hook FAIL lines appear while every `scoped:` case still passes, because removing the exclusion leaves `ECC_AGENT_DATA_HOME` in place.

- [ ] **Step 4: Run the touched suites and the full runner**

Run: `sh -n claude/hooks/ecc-hook-isolation.test.sh && bin/dotfiles-tests`
Expected: every suite green, including `plan-canvas-isolation.test.sh` and the new suite.

- [ ] **Step 5: Commit**

```bash
git -C "$WT" add claude/hooks/ecc-hook-isolation.test.sh
git -C "$WT" commit -m "claude: Prove scoped ECC hooks write only to their own config dir"
```

---

### Task 5: Documentation and the completion note

**Files:**
- Modify: `CLAUDE.md` (the bullet beginning `` - `ECC_DISABLED_HOOKS` in `claude/settings.json.tmpl` `env` switches off ECC's two Plan Canvas hooks``)
- Append (machine-local, NOT committed): `.todos/pending/2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di.md`

**Interfaces:**
- Consumes: the final id set and key names from Tasks 1 to 4.
- Produces: the CLAUDE.md strings the contract greps: `ECC_DISABLED_HOOKS`, `ecc-hook-isolation.test.sh`, `plan-canvas-isolation.test.sh`, `{{CLAUDE_CONFIG_DIR}}`, `ECC_AGENT_DATA_HOME`, `post:skill:track`, `post:bash:command-log-audit`, `pre:mcp-health-check`.

- [ ] **Step 1: Rewrite the CLAUDE.md bullet**

Replace the whole bullet with:

```markdown
- **ECC account isolation.** ECC 2.2.1 resolves several hook state paths through `os.homedir()` or `$HOME/.claude` and never consults `CLAUDE_CONFIG_DIR`, so on this dual-account machine a work session would read or write personal state (and the reverse). `claude/settings.json.tmpl` `env` handles the class two ways, for BOTH accounts. (1) `ECC_DISABLED_HOOKS` switches off the seven ids that have no usable scoping knob: the two Plan Canvas hooks (`session-start:plan-canvas-sessions`, `stop:plan-canvas-pending`; Canvas state and server port are keyed on `~/.claude/plan-canvas`, the deliberate `plan-canvas await` CLI loop is unaffected), the two Bash command logs (`post:bash:command-log-audit`, `post:bash:command-log-cost`; they append every command to `~/.claude/*.log`), `post:skill:track` (`~/.claude/state/skill-runs.jsonl`), and the MCP preflight probes (`pre:mcp-health-check`, `post:mcp-health-check`; they read `~/.claude.json` and `~/.claude/settings.json` and cache under `~/.claude`, and their path knobs are literal, so no template value can name the personal account's HOME-root `.claude.json` and the work account's `~/.claude-work/.claude.json` at once; neither account declares an MCP server). (2) Hooks that honour `ECC_AGENT_DATA_HOME` stay enabled and are scoped per account (metrics, session-data, learned skills): the template value is the literal token `{{CLAUDE_CONFIG_DIR}}`, and `reconcile_claude_settings_file` replaces it, in `env` string values only, with the absolute config dir it writes into, so the personal file resolves to `~/.claude` (ECC's default, unchanged behaviour) and the work file to `~/.claude-work`. Proven hermetically by `claude/hooks/ecc-hook-isolation.test.sh` (the five newer exclusions and the scoped hooks, with leak controls) and `claude/hooks/plan-canvas-isolation.test.sh` (Canvas); both SKIP where ECC is not installed. Template and live values are drift-checked by `claude-hooks.test.sh` and the link path by `install/claude-links.test.sh`. Not scoped, by design: GateGuard state (`~/.gateguard`, session-keyed), the homunculus store (`~/.local/share/ecc-homunculus`, XDG), and `skills/learned` (one symlink into this repo for both dirs, so its scoping is nominal). Remove each exclusion and the token key once upstream ECC resolves that path through `CLAUDE_CONFIG_DIR`; re-audit after an ECC upgrade with the grep described in the suite header.
```

- [ ] **Step 2: Check the CLAUDE.md strings and the protect hook**

Run: `for s in ECC_DISABLED_HOOKS ecc-hook-isolation.test.sh plan-canvas-isolation.test.sh '{{CLAUDE_CONFIG_DIR}}' ECC_AGENT_DATA_HOME post:skill:track post:bash:command-log-audit pre:mcp-health-check; do grep -qF "$s" CLAUDE.md && echo "ok $s" || echo "MISSING $s"; done`
Expected: eight `ok` lines. (If the `protect_claude_md.py` hook blocks the edit, it is because the bullet is being edited by an agent; the edit is in scope for this task, so re-issue it as a single Edit of the one bullet.)

- [ ] **Step 3: Append the completion note to the todo file**

Append to `.todos/pending/2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di.md` (machine-local; the `.todos` dir is a symlink to the main checkout's todo store and is not tracked):

```markdown

## Completion note (2026-09-06)

Audit of ECC 2.2.1 `scripts/hooks/` for `os.homedir()`, `~/.claude`, `$HOME`, and
the `getClaudeDir`/`getSessionsDir` helpers. Re-run after an ECC upgrade.

| Hook id | Path resolved | Class | Disposition |
|---|---|---|---|
| session-start:plan-canvas-sessions, stop:plan-canvas-pending | ~/.claude/plan-canvas | state r/w | excluded (PR #86) |
| post:bash:command-log-audit, post:bash:command-log-cost | ~/.claude/bash-commands.log, cost-tracker.log | state write | excluded (no knob) |
| post:skill:track | ~/.claude/state/skill-runs.jsonl | state write | excluded (no knob) |
| pre:mcp-health-check, post:mcp-health-check | ~/.claude/settings.json, ~/.claude.json read; ~/.claude/mcp-health-cache.json write | state r/w | excluded: path knobs are literal; personal .claude.json is HOME-root, work is <cfg>/.claude.json |
| stop:cost-tracker, post:session-activity-tracker, post:ecc-metrics-bridge | <data-home>/metrics | state r/w | scoped: ECC_AGENT_DATA_HOME |
| stop:session-end, pre:compact, session:start | <data-home>/session-data | state r/w | scoped: ECC_AGENT_DATA_HOME |
| stop:evaluate-session | <data-home>/skills/learned | state write | scoped in name only; target is one symlink for both dirs (pre-existing) |
| pre:bash:gateguard-fact-force, pre:edit-write:gateguard-fact-force | ~/.gateguard/state-<session>.json | session-keyed | keep |
| stop:format-typecheck | ~/.claude/plugins (skip-list guard) | no state | keep; upstream nit (misses ~/.claude-work/plugins) |
| ecc-statusline.js | CLAUDE_CONFIG_DIR-aware | display | keep |
| pre:observe, post:observe:continuous-learning, session:end:marker | ~/.local/share/ecc-homunculus (XDG) | state | out of class |
| all other ids | cwd, transcript, or /tmp by session | display | keep |

Upstream draft (not filed; needs an explicit go):
Title: Resolve hook state paths through CLAUDE_CONFIG_DIR, not os.homedir()
Body: On machines that run two Claude Code accounts via CLAUDE_CONFIG_DIR,
these hooks read or write the default account's state: plan-canvas-sessions,
plan-canvas-pending, mcp-health-check (settings lookup and cache),
post-bash-command-log, skill-run-tracker, and every getClaudeDir() consumer
(agent-data-home defaults to $HOME/.claude). Proposal: one shared
resolveClaudeConfigDir() (CLAUDE_CONFIG_DIR when set, else ~/.claude) used by
those scripts, and getDefaultClaudeAgentDataHome() returning it. The
stop-format-typecheck plugin-clone guard should include
<CLAUDE_CONFIG_DIR>/plugins as well. Downstream workaround today:
ECC_DISABLED_HOOKS for the first seven ids and ECC_AGENT_DATA_HOME set per
config dir.
```

- [ ] **Step 4: Full verification**

Run: `bin/dotfiles-tests && git -C "$WT" status --short`
Expected: all suites green; `git status` shows only `CLAUDE.md` modified (the todo file is outside the tracked tree).

- [ ] **Step 5: Commit**

```bash
git -C "$WT" add CLAUDE.md
git -C "$WT" commit -m "docs: Document ECC account isolation exclusions and scoped keys"
```

---

## Self-review

- Spec coverage: D1 (Task 1), D2 (Task 1 template), D3 (Tasks 3 and 4), D4 (Tasks 1 and 2), D5 and D6 (Task 5). AC1-AC12 each map to a contract command in `claude/contracts/td-2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di-contract.json`.
- Placeholder scan: none.
- Names used across tasks: `fresh_home`, `run_gated`, `run_bash_dispatcher`, `files_under`, `template_env`, `env_args`, `scoped_case`, `mcp_fixture` (Task 3), `ECC_HOOK_TEST_REQUIRE_ECC`, `ECC_PLUGIN_ROOT`; FAIL strings in Task 2 match the contract's greps.
