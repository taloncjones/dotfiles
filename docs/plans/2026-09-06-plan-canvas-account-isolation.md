# Plan Canvas Account Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch off ECC's two Plan Canvas hooks for both Claude accounts through the dotfiles settings template, and prove with tests that they are inert while every other ECC hook stays on.

**Architecture:** One new key in the template's `env` block (`ECC_DISABLED_HOOKS`) reaches both machine-local `settings.json` files through the existing reconcile step, because `env` is a template-owned key that is reasserted wholesale. Tests cover three layers: the template (static), the reconcile path (scratch config dir), and the installed ECC hook scripts (hermetic fixture with a fake home). Nothing under any plugin cache is modified.

**Tech Stack:** POSIX sh test scripts, python3 for JSON assertions, node (ECC hook scripts are node), `bin/dotfiles-tests` runner.

**Spec:** `docs/specs/2026-09-06-plan-canvas-account-isolation.md`

**Status:** branch-only document; dropped before merge together with the spec.

## Global Constraints

- Exclusion value, verbatim: `session-start:plan-canvas-sessions,stop:plan-canvas-pending` (spec R1). Assertions compare the set of ids, not the string.
- The three existing env keys keep their values: `ANTHROPIC_DEFAULT_OPUS_MODEL` = `claude-opus-4-8[1m]`, `CLAUDE_CODE_DISABLE_TELEMETRY` = `1`, `ECC_CONTEXT_MONITOR_COST_WARNINGS` = `0` (spec R2).
- Files that may change: `claude/settings.json.tmpl`, `claude/hooks/claude-hooks.test.sh`, `install/claude-links.test.sh`, `claude/hooks/plan-canvas-isolation.test.sh` (new), `bin/dotfiles-tests`, `CLAUDE.md` (spec R8). Never `zsh/functions.zsh` or `install/common/claude-links.sh`.
- Never write under any `plugins/` cache or marketplace clone, the real `~/.claude*/plan-canvas`, or either live `settings.json` (spec R6). Tests write only under a `mktemp -d` sandbox they remove on exit.
- No emojis, no AI attribution, ASCII only, LF line endings. Shell scripts start with `#!/bin/sh` like the sibling test files.
- Commit format: `<scope>: <summary>`, imperative, under 75 chars.
- Test baseline before the first change (recorded 2026-09-06 on this machine, see "Baseline" at the end): `claude/hooks/claude-hooks.test.sh` 80 passed 0 failed; `install/claude-links.test.sh` 16 passed 0 failed. AC7 means no new failures against that baseline.

## File Structure

| File | Responsibility |
|---|---|
| `claude/settings.json.tmpl` | Source of truth for both accounts' settings; gains the exclusion in `env`. |
| `claude/hooks/claude-hooks.test.sh` | Existing hook and settings drift suite; gains a static template assertion and a live-settings assertion for the exclusion. |
| `install/claude-links.test.sh` | Existing reconcile suite; its real-template integration case gains an assertion that the exclusion lands and that a second link run is byte-identical. |
| `claude/hooks/plan-canvas-isolation.test.sh` | New hermetic behavioral suite driving the installed ECC hook scripts against a fake home; SKIPs when ECC is absent unless required. |
| `bin/dotfiles-tests` | Suite registry; gains one line. |
| `CLAUDE.md` | Documents the exclusion, its reason, and its removal condition. |
| `claude/contracts/td-2026-09-05-isolate-ecc-plan-canvas-state-across-accounts-contract.json` | Verification contract (written with this plan, run by the orchestrator). |

Task order: 1 template, 2 static and live drift assertions, 3 reconcile assertions, 4 behavioral suite, 5 runner registration, 6 docs. Tasks 2 and 3 are written test-first against the unmodified template so their red state is observed before Task 1 lands; to keep that honest, Task 1's step 1 runs the Task 2 assertion inline before editing.

---

### Task 1: Add the exclusion to the settings template

**Files:**
- Modify: `claude/settings.json.tmpl:8-12` (the `env` object)

**Interfaces:**
- Produces: `env.ECC_DISABLED_HOOKS` string consumed by every later task.

- [ ] **Step 1: Observe the failing static check against the current template**

Run:
```bash
python3 - <<'PY'
import json, sys
env = json.load(open("claude/settings.json.tmpl")).get("env", {})
ids = {s.strip().lower() for s in env.get("ECC_DISABLED_HOOKS", "").split(",") if s.strip()}
sys.exit(0 if ids == {"session-start:plan-canvas-sessions", "stop:plan-canvas-pending"} else 1)
PY
echo "exit=$?"
```
Expected: `exit=1` (key absent today).

- [ ] **Step 2: Add the key**

Edit the `env` object so it reads exactly:
```json
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1m]",
    "CLAUDE_CODE_DISABLE_TELEMETRY": "1",
    "ECC_CONTEXT_MONITOR_COST_WARNINGS": "0",
    "ECC_DISABLED_HOOKS": "session-start:plan-canvas-sessions,stop:plan-canvas-pending"
  },
```

- [ ] **Step 3: Re-run the static check and confirm the file is still valid JSON**

Run:
```bash
python3 -c 'import json; json.load(open("claude/settings.json.tmpl"))' && echo json-ok
python3 - <<'PY'
import json, sys
env = json.load(open("claude/settings.json.tmpl")).get("env", {})
ids = {s.strip().lower() for s in env.get("ECC_DISABLED_HOOKS", "").split(",") if s.strip()}
assert ids == {"session-start:plan-canvas-sessions", "stop:plan-canvas-pending"}, ids
assert env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-4-8[1m]"
assert env["CLAUDE_CODE_DISABLE_TELEMETRY"] == "1"
assert env["ECC_CONTEXT_MONITOR_COST_WARNINGS"] == "0"
print("env-ok")
PY
```
Expected: `json-ok` then `env-ok`.

- [ ] **Step 4: Commit**

```bash
git add claude/settings.json.tmpl
git commit -m "claude: Disable ECC Plan Canvas hooks via ECC_DISABLED_HOOKS"
```

---

### Task 2: Drift assertions in the hooks suite

**Files:**
- Modify: `claude/hooks/claude-hooks.test.sh` (insert a static block after the existing "Static registration" block that ends near line 340, and a live block inside the `for settings_dir in ...` loop after the permissions drift check, before the `else` that prints `SKIP  settings: no live ...`)
- Test: the file itself; run with `sh claude/hooks/claude-hooks.test.sh`

**Interfaces:**
- Consumes: `env.ECC_DISABLED_HOOKS` from Task 1.
- Produces: two new PASS lines: `PASS  canvas: template excludes exactly the two Plan Canvas hooks` and `PASS  settings: <dir> excludes the Plan Canvas hooks`.

- [ ] **Step 1: Add the static template assertion**

Insert directly after the existing block whose PASS line is `hwg: template lists the Bash guards in order, worktree guard last`:

```sh
# Plan Canvas exclusion: ECC 2.2.1 keys Canvas state on ~/.claude/plan-canvas
# regardless of CLAUDE_CONFIG_DIR, so both accounts share it. The template
# switches off exactly the two Canvas hooks; nothing else may ride along in
# the exclusion, and both ids must be present. Set comparison: ECC parses the
# value into a set, so order is stylistic.
if python3 - <<'PY'
import json
import sys

env = json.load(open("claude/settings.json.tmpl")).get("env") or {}
ids = {s.strip().lower() for s in env.get("ECC_DISABLED_HOOKS", "").split(",") if s.strip()}
want = {"session-start:plan-canvas-sessions", "stop:plan-canvas-pending"}
sys.exit(0 if ids == want else 1)
PY
then
    printf 'PASS  canvas: template excludes exactly the two Plan Canvas hooks\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  canvas: template excludes exactly the two Plan Canvas hooks\n' >&2
    FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Add the live-settings assertion inside the drift loop**

Insert after the permissions drift `if ... fi` block (the one whose FAIL line mentions `permissions drifted`) and before the loop's `else` branch:

```sh
        # Exclusion drift: env is template-owned, so a reconciled machine must
        # carry both Plan Canvas ids. Superset check so a machine-local extra
        # id does not fail here (the reconcile would drop it on the next
        # update anyway).
        if SETTINGS_PATH="$settings_dir/settings.json" python3 - <<'PY'
import json
import os
import sys

env = json.load(open(os.environ["SETTINGS_PATH"])).get("env") or {}
ids = {s.strip().lower() for s in env.get("ECC_DISABLED_HOOKS", "").split(",") if s.strip()}
want = {"session-start:plan-canvas-sessions", "stop:plan-canvas-pending"}
for missing in sorted(want - ids):
    print("  missing exclusion: " + missing)
sys.exit(0 if want <= ids else 1)
PY
        then
            printf 'PASS  settings: %s excludes the Plan Canvas hooks\n' "$settings_dir"
            PASS=$((PASS + 1))
        else
            printf 'FAIL  settings: %s does not exclude the Plan Canvas hooks (run update to reconcile)\n' "$settings_dir" >&2
            FAIL=$((FAIL + 1))
        fi
```

- [ ] **Step 3: Prove the assertions are falsifiable, then green**

Run the suite against a scratch HOME whose settings lack the key (must fail), then sandboxed with no live settings (static assertion only, must pass):
```bash
d="$(mktemp -d)"; mkdir -p "$d/.claude"
python3 -c 'import json; t=json.load(open("claude/settings.json.tmpl")); t["env"].pop("ECC_DISABLED_HOOKS", None); json.dump(t, open("'"$d"'/.claude/settings.json","w"), indent=2)'
HOME="$d" sh claude/hooks/claude-hooks.test.sh; echo "exit=$?"
rm -rf "$d"
HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh | tail -1
```
Expected: first run prints `FAIL  settings: .../.claude does not exclude the Plan Canvas hooks` and `exit=1`; second run ends `81 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add claude/hooks/claude-hooks.test.sh
git commit -m "claude: Drift-check the Plan Canvas hook exclusion"
```

---

### Task 3: Reconcile assertions in the links suite

**Files:**
- Modify: `install/claude-links.test.sh:167-175` (append after the `link path maps the Opus alias to Opus 4.8 1M` case, before the `symlinks assets but keeps settings.json a real file` case)

**Interfaces:**
- Consumes: `link_claude_config_dir` and `jget` already defined in the file; `env.ECC_DISABLED_HOOKS` from Task 1.
- Produces: PASS lines `link path delivers the Plan Canvas hook exclusion` and `second link run leaves settings.json byte-identical`.

- [ ] **Step 1: Add the assertions**

```sh
if jget "$CFG/settings.json" "{x.strip() for x in d['env']['ECC_DISABLED_HOOKS'].split(',') if x.strip()} == {'session-start:plan-canvas-sessions', 'stop:plan-canvas-pending'}"; then
    pass "link path delivers the Plan Canvas hook exclusion"
else
    fail "link path delivers the Plan Canvas hook exclusion"
fi
# Two consecutive update runs must converge: the exclusion is delivered once
# and never re-written differently.
cp "$CFG/settings.json" "$TMP/link-first.json"
link_claude_config_dir "$CFG" >/dev/null 2>&1
if cmp -s "$CFG/settings.json" "$TMP/link-first.json"; then
    pass "second link run leaves settings.json byte-identical"
else
    fail "second link run leaves settings.json byte-identical"
fi
```

- [ ] **Step 2: Run the suite**

Run: `sh install/claude-links.test.sh | tail -3`
Expected: both new PASS lines and `18 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add install/claude-links.test.sh
git commit -m "install: Assert reconcile delivers the Plan Canvas exclusion"
```

---

### Task 4: Hermetic behavioral suite against the installed ECC hooks

**Files:**
- Create: `claude/hooks/plan-canvas-isolation.test.sh`

**Interfaces:**
- Consumes: the template's `env.ECC_DISABLED_HOOKS` (read at runtime, never hardcoded, so the suite proves the committed value); ECC scripts `scripts/hooks/run-with-flags.js`, `scripts/hooks/plan-canvas-pending.js`, `scripts/hooks/plan-canvas-sessions.js`, `scripts/hooks/check-hook-enabled.js` under the resolved ECC root.
- Produces: exit 0 with `N passed, 0 failed`; exit 0 with a `SKIP:` line when ECC is absent; exit 1 when `PLAN_CANVAS_TEST_REQUIRE_ECC=1` and ECC is absent.
- Env knobs: `ECC_PLUGIN_ROOT` overrides root resolution; `PLAN_CANVAS_TEST_REQUIRE_ECC=1` turns SKIP into FAIL (the contract uses it).

Behavior facts the suite relies on (verified 2026-09-06 against ECC 2.2.1 with a scratchpad prototype): a disabled hook echoes stdin unchanged and exits 0; an enabled Stop hook with pending feedback under its cwd prints `{"decision":"block","reason":...}` containing the feedback text and rewrites `sessions.json`; an enabled SessionStart hook prints `[PlanCanvas] Open browser review sessions` with every open artifact path; the Stop hook honors the payload `cwd` for scoping; `os.homedir()` follows `HOME`; `check-hook-enabled.js <id>` prints `no` for excluded ids before any profile check.

- [ ] **Step 1: Write the suite**

```sh
#!/bin/sh
# plan-canvas-isolation.test.sh -- prove the two ECC Plan Canvas hooks are
# inert under the settings template env, and live without it.
#
# ECC 2.2.1 resolves Plan Canvas state to ~/.claude/plan-canvas regardless of
# CLAUDE_CONFIG_DIR, so on a dual-account machine the work account would see
# personal Canvas sessions (SessionStart) and receive personal feedback (Stop).
# The template excludes both hooks via ECC_DISABLED_HOOKS. This suite drives
# the INSTALLED hook scripts against a fake home under mktemp; the real
# ~/.claude*/plan-canvas is never read or written. It proves the hooks are
# switched off, not that Canvas state is account-scoped.
#
# Knobs: ECC_PLUGIN_ROOT overrides ECC root resolution.
#        PLAN_CANVAS_TEST_REQUIRE_ECC=1 turns the no-ECC SKIP into a FAIL.

set -u

TMPL=claude/settings.json.tmpl
if [ ! -f "$TMPL" ]; then
    echo "FAIL: $TMPL not found (run from repo root)" >&2
    exit 2
fi

require_ecc="${PLAN_CANVAS_TEST_REQUIRE_ECC:-0}"
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
for f in scripts/hooks/plan-canvas-pending.js scripts/hooks/plan-canvas-sessions.js scripts/hooks/check-hook-enabled.js; do
    if [ ! -f "$ECC_ROOT/$f" ]; then
        echo "FAIL: ECC layout changed: $ECC_ROOT/$f missing" >&2
        exit 1
    fi
done

DISABLED="$(python3 -c 'import json; print(json.load(open("claude/settings.json.tmpl")).get("env", {}).get("ECC_DISABLED_HOOKS", ""))')"

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/plan-canvas-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fixture: two open Canvas sessions with undelivered feedback, one artifact
# per fixture repo. Text markers are what the assertions grep for. No
# server.json, so the Stop hook can never contact a real Canvas server.
mkdir -p "$TMP/repo-a/docs" "$TMP/repo-b/docs" "$TMP/repo-c" "$TMP/personal" "$TMP/work"
: > "$TMP/repo-a/docs/plan.md"
: > "$TMP/repo-b/docs/plan.md"
python3 - "$TMP" <<'PY'
import json, sys
t = sys.argv[1]
state = {"sessions": {
    "aaa": {"key": "aaa", "file": t + "/repo-a/docs/plan.md", "status": "open",
            "pendingFeedback": [{"id": "fb-1", "kind": "chat", "text": "FIXTURE-FEEDBACK-A"}],
            "updatedAt": "2026-09-06T00:00:00.000Z"},
    "bbb": {"key": "bbb", "file": t + "/repo-b/docs/plan.md", "status": "open",
            "pendingFeedback": [{"id": "fb-2", "kind": "chat", "text": "FIXTURE-FEEDBACK-B"}],
            "updatedAt": "2026-09-06T00:00:01.000Z"}}}
with open(t + "/fixture.json", "w") as fh:
    json.dump(state, fh, indent=2)
PY

# fresh_home <name>: a new fake HOME holding a pristine copy of the fixture.
# Every scenario gets its own so the enabled control's drain cannot leak.
fresh_home() {
    h="$TMP/$1/home"
    mkdir -p "$h/.claude/plan-canvas"
    cp "$TMP/fixture.json" "$h/.claude/plan-canvas/sessions.json"
    printf '%s' "$h"
}

# run_hook <event> <home> <cfgdir> <cwd> <disabled-value>
# Runs the installed hook through ECC's flag gate exactly as hooks.json does.
# Profile and enabled flag are pinned so machine-level ECC settings cannot
# produce false results. stdout -> $TMP/out, stderr -> $TMP/err.
run_hook() {
    case "$1" in
        stop)
            payload="$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$4")"
            hook_id=stop:plan-canvas-pending
            script=scripts/hooks/plan-canvas-pending.js
            profiles=minimal,standard,strict
            ;;
        start)
            payload='{"hook_event_name":"SessionStart","source":"startup"}'
            hook_id=session-start:plan-canvas-sessions
            script=scripts/hooks/plan-canvas-sessions.js
            profiles=standard,strict
            ;;
    esac
    printf '%s' "$payload" | (
        cd "$4" && HOME="$2" CLAUDE_CONFIG_DIR="$3" CLAUDE_PLUGIN_ROOT="$ECC_ROOT" \
            ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            ECC_DISABLED_HOOKS="$5" ECC_PLAN_CANVAS_STATE_DIR= \
            node "$ECC_ROOT/scripts/hooks/run-with-flags.js" "$hook_id" "$script" "$profiles"
    ) >"$TMP/out" 2>"$TMP/err"
    printf '%s' "$payload" >"$TMP/payload"
}

# silent_case <label> <event> <cwd> <disabled-value>
# Under both fake accounts: output is the untouched payload and the fixture
# state file is byte-identical afterwards.
silent_case() {
    ok=1
    for acct in personal work; do
        h="$(fresh_home "$acct-$PASS-$FAIL-$2")"
        run_hook "$2" "$h" "$TMP/$acct" "$3" "$4"
        if ! cmp -s "$TMP/out" "$TMP/payload"; then ok=0; fi
        if grep -q 'FIXTURE-FEEDBACK\|"decision"\|PlanCanvas' "$TMP/out"; then ok=0; fi
        if ! cmp -s "$h/.claude/plan-canvas/sessions.json" "$TMP/fixture.json"; then ok=0; fi
    done
    if [ "$ok" = 1 ]; then pass "$1"; else fail "$1"; fi
}

# --- hooks inert under the template env ---
silent_case "stop: pending personal feedback in this repo is not delivered" \
    stop "$TMP/repo-a" "$DISABLED"
silent_case "stop: concurrent pending feedback in the other reviewed repo is not delivered" \
    stop "$TMP/repo-b" "$DISABLED"
silent_case "stop: unrelated repo stays silent with the exclusion" \
    stop "$TMP/repo-c" "$DISABLED"
silent_case "stop: unrelated repo stays silent without the exclusion (hook cwd scoping)" \
    stop "$TMP/repo-c" ""
silent_case "session-start: open personal sessions are not enumerated" \
    start "$TMP/repo-a" "$DISABLED"

# --- falsifiable controls: same fixture, no exclusion ---
h="$(fresh_home control-stop)"
run_hook stop "$h" "$TMP/work" "$TMP/repo-a" ""
if grep -q '"decision":"block"' "$TMP/out" && grep -q 'FIXTURE-FEEDBACK-A' "$TMP/out" \
        && ! grep -q 'FIXTURE-FEEDBACK-B' "$TMP/out" \
        && ! cmp -s "$h/.claude/plan-canvas/sessions.json" "$TMP/fixture.json"; then
    pass "control: without the exclusion Stop blocks with this repo's feedback only"
else
    fail "control: without the exclusion Stop blocks with this repo's feedback only"
fi
h="$(fresh_home control-start)"
run_hook start "$h" "$TMP/work" "$TMP/repo-a" ""
if grep -q 'PlanCanvas' "$TMP/out" && grep -q 'repo-a/docs/plan.md' "$TMP/out" \
        && grep -q 'repo-b/docs/plan.md' "$TMP/out"; then
    pass "control: without the exclusion SessionStart enumerates every open session"
else
    fail "control: without the exclusion SessionStart enumerates every open session"
fi

# --- collateral: only the two Canvas ids are off under the template env ---
# check-hook-enabled exercises ECC's flag gate (the exclusion short-circuits
# before the profile check), not the hooks.json wiring.
enabled_is() {
    got="$(CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
        ECC_DISABLED_HOOKS="$DISABLED" node "$ECC_ROOT/scripts/hooks/check-hook-enabled.js" "$1" 2>/dev/null)"
    [ "$got" = "$2" ]
}
ok=1
for id in stop:plan-canvas-pending session-start:plan-canvas-sessions; do
    enabled_is "$id" no || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: both Plan Canvas ids answer no"; else fail "flag gate: both Plan Canvas ids answer no"; fi
ok=1
for id in stop:session-end pre:bash:dispatcher post:dispatcher:sync; do
    enabled_is "$id" yes || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: TDD and dispatcher hooks stay enabled"; else fail "flag gate: TDD and dispatcher hooks stay enabled"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
```

- [ ] **Step 2: Syntax-check and run**

Run:
```bash
sh -n claude/hooks/plan-canvas-isolation.test.sh && echo syntax-ok
PLAN_CANVAS_TEST_REQUIRE_ECC=1 sh claude/hooks/plan-canvas-isolation.test.sh
```
Expected: `syntax-ok`, nine PASS lines, `9 passed, 0 failed`, exit 0.

- [ ] **Step 3: Prove the suite is falsifiable against the template value**

Temporarily point it at a template copy without the key by using a scratch repo root:
```bash
d="$(mktemp -d)"; mkdir -p "$d/claude"
python3 -c 'import json; t=json.load(open("claude/settings.json.tmpl")); t["env"].pop("ECC_DISABLED_HOOKS", None); json.dump(t, open("'"$d"'/claude/settings.json.tmpl","w"), indent=2)'
(cd "$d" && PLAN_CANVAS_TEST_REQUIRE_ECC=1 sh "$OLDPWD/claude/hooks/plan-canvas-isolation.test.sh"); echo "exit=$?"
rm -rf "$d"
```
Expected: the four "inert" Stop/SessionStart cases and the flag-gate `no` case print FAIL, `exit=1`.

- [ ] **Step 4: Prove the SKIP and REQUIRE paths**

Run:
```bash
ECC_PLUGIN_ROOT=/nonexistent sh claude/hooks/plan-canvas-isolation.test.sh; echo "exit=$?"
ECC_PLUGIN_ROOT=/nonexistent PLAN_CANVAS_TEST_REQUIRE_ECC=1 sh claude/hooks/plan-canvas-isolation.test.sh; echo "exit=$?"
```
Expected: `SKIP: ECC plugin scripts not installed ...` with `exit=0`, then `FAIL: ECC plugin scripts not installed ...` with `exit=1`.

- [ ] **Step 5: Confirm nothing leaked outside the sandbox**

Run:
```bash
ls -d "$HOME/.claude/plan-canvas" "$HOME/.claude-work/plan-canvas" 2>&1
git -C "$HOME/.claude/plugins/marketplaces/ecc" status --porcelain | wc -l
```
Expected: both `No such file or directory` (no Canvas state exists on this machine and the suite must not create it), and `0` modified vendored files.

- [ ] **Step 6: Commit**

```bash
git add claude/hooks/plan-canvas-isolation.test.sh
git commit -m "claude: Add hermetic Plan Canvas hook isolation suite"
```

---

### Task 5: Register the suite in the runner

**Files:**
- Modify: `bin/dotfiles-tests:26-27` (the `SUITES` list; add after `sh claude/hooks/claude-hooks.test.sh`)

**Interfaces:**
- Consumes: Task 4's SKIP-when-absent behavior (CI has no ECC clone, so the suite prints SKIP and passes there).

- [ ] **Step 1: Add the line**

```
sh claude/hooks/plan-canvas-isolation.test.sh
```
directly after the `sh claude/hooks/claude-hooks.test.sh` line.

- [ ] **Step 2: Run the full runner**

Run: `bash bin/dotfiles-tests 2>&1 | tail -4`
Expected while the branch-only spec and plan are still tracked: `=== dotfiles-tests: 19 suites passed, 1 failed` with only `git/hooks/public-safety.test.sh` failing on `no tracked planning artifacts` (the baseline shows the same single failure for the same reason). Every other suite `[OK]`, including the new `claude/hooks/plan-canvas-isolation.test.sh`. After the branch-only docs are dropped before merge, `20 suites passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add bin/dotfiles-tests
git commit -m "bin: Register the Plan Canvas isolation suite"
```

---

### Task 6: Document the exclusion

**Files:**
- Modify: `CLAUDE.md` (add one bullet after the `claude/hooks/herdr_worktree_guard.py` bullet in "Symlink targets")

- [ ] **Step 1: Add the bullet**

```markdown
- `ECC_DISABLED_HOOKS` in `claude/settings.json.tmpl` `env` switches off ECC's two Plan Canvas hooks (`session-start:plan-canvas-sessions`, `stop:plan-canvas-pending`) for BOTH accounts. ECC 2.2.1 keys Canvas state on `~/.claude/plan-canvas` regardless of `CLAUDE_CONFIG_DIR`, so on a dual-account machine the work account would see personal Canvas sessions at SessionStart and receive personal browser feedback at Stop. The deliberate `plan-canvas await` CLI loop is unaffected. Proven inert by `claude/hooks/plan-canvas-isolation.test.sh` (SKIPs where ECC is not installed); the template value is drift-checked by `claude-hooks.test.sh`. Remove the exclusion once upstream ECC scopes the state dir and server port by config dir.
```

- [ ] **Step 2: Verify and run the docs guards**

Run:
```bash
grep -c 'ECC_DISABLED_HOOKS' CLAUDE.md
grep -c 'plan-canvas-isolation.test.sh' CLAUDE.md
```
Expected: `1` and `1`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: Explain the Plan Canvas hook exclusion"
```

---

### Task 7: Deliver to this machine and record the human check

This task mutates machine state (both live `settings.json` files) through the normal `update` path. It needs the user's go in interactive work; under the orchestrator it is the implement phase's final step and its output is pasted into the PR test plan.

- [ ] **Step 1: Reconcile both config dirs**

Run: `update` (or `./install/install.sh` link step) from the checkout that owns `~/.claude` symlinks, then:
```bash
jq -r .env.ECC_DISABLED_HOOKS ~/.claude/settings.json ~/.claude-work/settings.json
sh claude/hooks/claude-hooks.test.sh | grep 'excludes the Plan Canvas'
```
Expected: the exclusion value printed twice; two PASS lines, one per config dir.

- [ ] **Step 2: Human check AC9, one session per account**

In a fresh Claude session under each account, from the Bash tool:
```bash
node "$(ls -d ~/.claude*/plugins/marketplaces/ecc | head -1)/scripts/hooks/check-hook-enabled.js" stop:plan-canvas-pending; echo
```
Expected: `no` in both sessions. Paste both outputs into the PR test plan. Until this is recorded, the fix is confirmed at the file and hook-script level and inferred at the session level.

---

## Acceptance criteria to contract mapping

Contract: `claude/contracts/td-2026-09-05-isolate-ecc-plan-canvas-state-across-accounts-contract.json`. Commands run in the worktree via `sh -c`; none writes outside a `mktemp -d` sandbox, none touches network, live settings, or vendored files.

| Criterion | Contract command | Notes |
|---|---|---|
| AC1 exclusion set exact; existing env keys kept | `template-excludes-exactly-canvas-hooks`, `template-keeps-existing-env-keys` | static, python3 |
| AC2 reconcile delivers; second run byte-identical | `links-suite` | `install/claude-links.test.sh` (Task 3 cases) |
| AC3 drift test passes reconciled, fails when an id is missing | `hooks-suite-sandboxed`, `drift-fails-without-exclusion` | second command builds a scratch HOME whose settings lack the key and expects non-zero |
| AC4 hooks silent under both fake accounts, cwd/unrelated/concurrent, state unchanged | `canvas-isolation-suite` | `PLAN_CANVAS_TEST_REQUIRE_ECC=1`; needs an ECC clone under a Claude config dir on the verifying machine (this machine has both) |
| AC5 falsifiable control blocks and enumerates | `canvas-isolation-suite` | control cases inside the suite |
| AC6 non-Canvas ids stay enabled | `canvas-isolation-suite` | flag-gate cases inside the suite |
| AC7 vendored files untouched; no new suite failures | `changed-files-within-scope`, `hooks-suite-sandboxed`, `links-suite`, `canvas-isolation-suite` | scope check diffs the base SHA against HEAD, ignoring `docs/` and `claude/contracts/`; vendored caches are outside the repo and outside the allowed set, and the suite never writes them (Task 4 step 5 is the human spot check). The full runner is not a contract command because the branch-only spec and plan make `git/hooks/public-safety.test.sh` fail until they are dropped; the affected suites run individually instead, and Task 5 step 2 runs the full runner by hand. |
| R6 sandbox only; suite SKIPs where ECC is absent and fails when required | `canvas-isolation-suite-skips-without-ecc` | `ECC_PLUGIN_ROOT=/nonexistent` |
| AC4/AC5 suite is falsifiable against the template value | `canvas-isolation-suite-fails-without-template-value` | scratch repo root whose template lacks the key; expects the named FAIL line |
| R2 existing env keys kept; R8 parallel-branch files untouched | `template-keeps-existing-env-keys`, `no-zsh-or-links-edits` | invariants: pass on the base tree by design |
| AC8 CLAUDE.md documents the exclusion | `claude-md-documents-exclusion` | grep |
| AC9 live session exports env to hooks | human-verify (Task 7 step 2) | no automated command can start a real session |
| R8 file scope | `changed-files-within-scope` | allowed set is the six files |
| new suite registered | `runner-registers-suite` | grep `bin/dotfiles-tests` |
| shell syntax of the new suite | `new-suite-syntax` | `sh -n` |

## Verification gaps named up front

- The Codex second-model review of the spec and of this plan could not run: the Codex CLI returned a usage-limit error until 11:08 PM on 2026-09-06. A fresh-context Claude Opus reviewer ran the identical prompts instead; its findings were folded in. Re-run `codex-spec-review` and `codex-plan-review` before implementation if the limit has lifted.
- AC9 (platform exports settings `env` to hook processes) is human-verified only.
- `canvas-isolation-suite` depends on the ECC marketplace clone being installed on the verifying machine; in CI it SKIPs.

## Baseline (2026-09-06, this machine, before any implementation change)

Recorded from `bash bin/dotfiles-tests` on the branch at the spec commit (implementation base 41dd7a1 plus the branch-only spec). Result: 18 suites passed, 1 failed. The one failure is `git/hooks/public-safety.test.sh`, case `no tracked planning artifacts`, caused by the force-added branch-only spec under `docs/specs/`; it clears when the spec and plan commits are dropped before merge. Per-suite: `claude/hooks/claude-hooks.test.sh` 80 passed 0 failed; `install/claude-links.test.sh` 16 passed 0 failed; every other suite `[OK]`.

Contract dry run on the same tree (before implementation), expected exit codes: `template-keeps-existing-env-keys`, `hooks-suite-sandboxed`, `links-suite`, `no-zsh-or-links-edits` exit 0 (invariants and pre-existing suites); every other command exits non-zero. Observed exactly that, which is the contract's own falsifiability check.
