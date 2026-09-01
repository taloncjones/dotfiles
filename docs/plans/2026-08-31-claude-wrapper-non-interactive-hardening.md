# Claude Wrapper Non-Interactive Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude account routing (`claude()` wrapper) work in interactive, login, and non-interactive zsh alike, and guarantee the launched process never sees an empty `CLAUDE_CONFIG_DIR`.

**Architecture:** Move the accounts block from `zsh/functions.zsh` (interactive-only) into a new `zsh/claude-account.zsh`, sourced from a new tracked `zsh/.zshenv` (the one file every zsh reads). The wrapper becomes self-contained: inline routing with literal-default fallbacks, always injecting an explicit non-empty config dir. The installer migrates any machine-local `~/.zshenv` aside non-destructively.

**Tech Stack:** zsh, POSIX sh test scripts (repo `*.test.sh` pattern), bash installer scripts.

**Spec:** `docs/specs/2026-08-31-claude-wrapper-non-interactive-hardening.md`

## Global Constraints

- Routing precedence, highest first: `--personal` > non-empty `CLAUDE_CONFIG_DIR` > cwd under `~/Git/work` > `$HOME/.claude`.
- Empty-but-exported `CLAUDE_CONFIG_DIR` is treated as unset at every step and never propagated.
- Every launch injects an explicit non-empty absolute `CLAUDE_CONFIG_DIR` into the child.
- `zsh/.zshenv` and `zsh/claude-account.zsh` produce zero stdout/stderr on success and invoke no external commands (builtins and parameter expansion only).
- Migration is idempotent and never overwrites or deletes existing file content.
- No emojis; `#!/bin/zsh` or `#!/usr/bin/env bash` shebangs; test scripts follow the `PASS/FAIL ... N passed, N failed` convention run by `bin/dotfiles-tests`.
- Commit messages: `<scope>: <summary>`, imperative, <75 chars, and must not contain the word "claude" (the commit guard blocks it) -- say "account wrapper" / "account routing".

---

### Task 1: `zsh/claude-account.zsh` with self-contained wrapper + routing tests

**Files:**
- Create: `zsh/claude-account.zsh`
- Create: `zsh/claude-account.test.sh`
- Modify: `bin/dotfiles-tests` (SUITES list, after `sh zsh/functions.test.sh`)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `zsh/claude-account.zsh` defining `CLAUDE_WORK_CONFIG_DIR`, `CLAUDE_WORK_TREE`, `_claude_config_dir()`, `claude-account()`, `claude()`. Task 2's `.zshenv` sources this file by sibling path. Task 4 deletes the equivalent block from `zsh/functions.zsh`.
- Produces: `zsh/claude-account.test.sh` with `pass`/`fail`/`run_case` helpers Task 2 extends with shell-mode cases.

- [ ] **Step 1: Write the failing test suite**

Create `zsh/claude-account.test.sh`:

```sh
#!/bin/sh
# claude-account.test.sh -- behavioral tests for zsh/claude-account.zsh.
#
# Runs the real functions in zsh against a stub `claude` CLI that records the
# CLAUDE_CONFIG_DIR it received (distinguishing empty from unset) and its
# argv, in a sandbox HOME. Covers the spec's failure matrix: routing
# precedence, the never-empty invariant, and the snapshot case (wrapper
# defined, helper and vars stripped).

set -u

ACCT=zsh/claude-account.zsh
if [ ! -f "$ACCT" ]; then
    echo "FAIL: $ACCT not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# --- static assertions (always run) ---
# Extract the claude() body, strip comments (the implementation comments
# reference the helper by name), then look for a real invocation.
if awk '/^function claude\(\)/,/^}/' "$ACCT" | sed 's/#.*//' | grep -q '_claude_config_dir'; then
    fail "wrapper is self-contained (no helper call in claude())"
else
    pass "wrapper is self-contained (no helper call in claude())"
fi
if grep -q 'CLAUDE_CONFIG_DIR="\$cfg" command claude' "$ACCT"; then
    pass "wrapper always injects an explicit config dir"
else
    fail "wrapper always injects an explicit config dir"
fi

if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed; behavioral cases run in CI (which installs zsh)"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
    exit $?
fi

REPO="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-account-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Canonicalize: the wrapper normalizes with :A, so expectations must be
# symlink-free paths (macOS mktemp returns /var/..., which :A rewrites
# to /private/var/...).
TMP="$(cd "$TMP" && pwd -P)"
SBHOME="$TMP/home"
mkdir -p "$SBHOME/Git/work/proj" "$SBHOME/elsewhere" "$TMP/bin"

# Stub claude: records the env value (or UNSET) and each argv element on
# its own line (boundary-preserving), exits 0.
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
{
    printf 'cfg=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$RECORD"
exit 0
EOF
chmod +x "$TMP/bin/claude"

# run_case <label> <cwd> <zsh-body> <expected-cfg> [expected-argv]
# expected-argv is the space-joined argv (our expectations contain no
# spaces inside a single argument; per-arg lines remain in $RECORD).
# Sources claude-account.zsh directly (Task 2 adds .zshenv-driven modes).
run_case() {
    label="$1" cwd="$2" body="$3" want_cfg="$4" want_argv="${5-}"
    rec="$TMP/rec"
    : > "$rec"
    RECORD="$rec" HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
        zsh -c "cd '$cwd' && source '$REPO/$ACCT' && $body" >/dev/null 2>&1
    got_cfg="$(sed -n 's/^cfg=//p' "$rec")"
    got_argv="$(sed -n 's/^arg=//p' "$rec" | tr '\n' ' ')"
    got_argv="${got_argv% }"
    if [ "$got_cfg" = "$want_cfg" ] && { [ -z "$want_argv" ] || [ "$got_argv" = "$want_argv" ]; }; then
        pass "$label"
    else
        fail "$label (cfg='$got_cfg' argv='$got_argv')"
    fi
}

# 1. Personal cwd, env unset: explicit personal dir injected.
run_case "personal cwd routes to ~/.claude (always-inject)" \
    "$SBHOME/elsewhere" "claude -p hi" "$SBHOME/.claude" "-p hi"

# 2. Work cwd, env unset: work dir injected.
run_case "work cwd routes to ~/.claude-work" \
    "$SBHOME/Git/work/proj" "claude" "$SBHOME/.claude-work"

# 3. Symlinked path INTO the work tree: cwd is a symlink outside the tree
# whose target is inside it; ${PWD:A} resolves to the real work-tree
# location, so it routes to work.
mkdir -p "$SBHOME/Git/work/real-proj"
ln -s "$SBHOME/Git/work/real-proj" "$SBHOME/work-shortcut"
run_case "symlinked path into work tree routes to work" \
    "$SBHOME/work-shortcut" "claude" "$SBHOME/.claude-work"

# 4. Non-empty env wins over cwd, from both cwds.
run_case "non-empty env wins from personal cwd" \
    "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
run_case "non-empty env wins from work cwd" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
run_case "relative env value is normalized to absolute" \
    "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=relcfg claude" "$SBHOME/elsewhere/relcfg"

# 5. Exported-empty env is consumed, never propagated.
run_case "exported-empty env treated as unset (personal cwd)" \
    "$SBHOME/elsewhere" "export CLAUDE_CONFIG_DIR=; claude" "$SBHOME/.claude"
run_case "exported-empty env treated as unset (work cwd)" \
    "$SBHOME/Git/work/proj" "export CLAUDE_CONFIG_DIR=; claude" "$SBHOME/.claude-work"

# 6. --personal overrides everything incl. custom env; flag not forwarded.
run_case "--personal beats custom env, flag filtered" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude --personal -p hi" \
    "$SBHOME/.claude" "-p hi"
# Per spec, every argv element equal to --personal is the flag, even
# after -- (matches today's filter): it forces personal and is removed.
run_case "--personal after -- still forces personal and is filtered" \
    "$SBHOME/Git/work/proj" "claude -- --personal" "$SBHOME/.claude" "--"

# 7. Pre-set CLAUDE_WORK_* values are honored.
mkdir -p "$SBHOME/alt-tree/x"
run_case "pre-set CLAUDE_WORK_TREE/CONFIG_DIR are honored" \
    "$SBHOME/alt-tree/x" \
    "CLAUDE_WORK_TREE=$SBHOME/alt-tree CLAUDE_WORK_CONFIG_DIR=$SBHOME/.alt-work claude" \
    "$SBHOME/.alt-work"

# 8. Snapshot simulation: helper and vars stripped, wrapper still routes.
run_case "snapshot: helper+vars stripped, work cwd still routes" \
    "$SBHOME/Git/work/proj" \
    "unfunction _claude_config_dir; unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR; claude" \
    "$SBHOME/.claude-work"

# 9. Wrapper exit status passes through.
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
printf 'cfg=%s\nargv=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" "$*" > "$RECORD"
exit 7
EOF
chmod +x "$TMP/bin/claude"
RECORD="$TMP/rec" HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$SBHOME/elsewhere' && source '$REPO/$ACCT' && claude" >/dev/null 2>&1
rc=$?
if [ "$rc" = 7 ]; then
    pass "exit status passes through"
else
    fail "exit status passes through (got $rc, want 7)"
fi
# restore the recording stub
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
{
    printf 'cfg=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}"
    printf 'argv=%s\n' "$*"
} > "$RECORD"
exit 0
EOF
chmod +x "$TMP/bin/claude"

# 10. claude-account labels.
acct_case() {
    label="$1" cwd="$2" envp="$3" want="$4"
    out="$(HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
        zsh -c "cd '$cwd' && source '$REPO/$ACCT' && $envp claude-account" 2>/dev/null)"
    case "$out" in
        "$want"*) pass "$label" ;;
        *) fail "$label (got '$out')" ;;
    esac
}
acct_case "claude-account: personal label" "$SBHOME/elsewhere" "" "personal"
acct_case "claude-account: work label" "$SBHOME/Git/work/proj" "" "work"
acct_case "claude-account: custom label" "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=$SBHOME/custom" "custom"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh zsh/claude-account.test.sh`
Expected: exit 2, `FAIL: zsh/claude-account.zsh not found`.

- [ ] **Step 3: Write `zsh/claude-account.zsh`**

```zsh
#!/bin/zsh
##############################
###### Claude Code Accounts
##############################
# Sourced from zsh/.zshenv so account routing exists in interactive, login,
# AND non-interactive shells (zsh -lc / zsh -c read .zshenv but never .zshrc;
# headless probes, hooks, and orchestrator dispatches run there). Zero output
# on success; builtins and parameter expansion only -- every zsh on the
# machine pays this file's cost.
#
# Fable requires OAuth login (no API token), so work and personal need two
# separate logins. CLAUDE_CONFIG_DIR is the supported isolation mechanism:
# ~/.claude holds the personal login (the default -- the desktop app lands
# there); ~/.claude-work holds the work login. Routing precedence, highest
# first:
#   --personal > non-empty CLAUDE_CONFIG_DIR > cwd under $CLAUDE_WORK_TREE
#   > $HOME/.claude
# An exported-empty CLAUDE_CONFIG_DIR is treated as unset and is never
# propagated: the wrapper always injects an explicit non-empty dir. If
# ~/.claude-work does not exist yet, claude creates it and prompts a fresh
# OAuth login for the work account.
CLAUDE_WORK_CONFIG_DIR="${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"
CLAUDE_WORK_TREE="${CLAUDE_WORK_TREE:-$HOME/Git/work}"

# helper: resolve which config dir a claude launch would use from $PWD.
# :A resolves symlinks on both sides so a symlinked path into ~/Git/work
# still routes to the work account. Used by claude-account only: claude()
# deliberately inlines the same logic instead of calling this -- Claude
# Code's shell snapshot strips _-prefixed functions, and a wrapper that
# survived while this helper did not once exported an empty
# CLAUDE_CONFIG_DIR and dumped a config tree into the cwd (2026-08-30).
function _claude_config_dir() {
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        echo "$CLAUDE_CONFIG_DIR"
    elif [[ "${PWD:A}/" == "${CLAUDE_WORK_TREE:A}/"* ]]; then
        echo "$CLAUDE_WORK_CONFIG_DIR"
    else
        echo "$HOME/.claude"
    fi
}

function claude-account() {    # claude-account() prints which Claude account/config dir a launch from this directory would use. ex: $ claude-account
    local cfg
    cfg="$(_claude_config_dir)"
    case "$cfg" in
        "$CLAUDE_WORK_CONFIG_DIR") echo "work ($cfg)" ;;
        "$HOME/.claude")           echo "personal ($cfg)" ;;
        *)                         echo "custom ($cfg)" ;;
    esac
}

function claude() {    # claude() will launch Claude Code with the work account inside ~/Git/work, personal elsewhere. Pass --personal to force the personal account. ex: $ claude --personal
    local use_personal=0 arg cfg work_tree
    local -a forwarded=()
    for arg in "$@"; do
        case "$arg" in
            --personal) use_personal=1 ;;
            *) forwarded+=("$arg") ;;
        esac
    done
    # Routing is inlined (see _claude_config_dir comment) with
    # literal-default fallbacks so a partially restored environment --
    # helper gone, CLAUDE_WORK_* unset -- still routes correctly.
    if (( use_personal )); then
        cfg="$HOME/.claude"
    elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        cfg="$CLAUDE_CONFIG_DIR"
    else
        work_tree="${CLAUDE_WORK_TREE:-$HOME/Git/work}"
        if [[ "${PWD:A}/" == "${work_tree:A}/"* ]]; then
            cfg="${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"
        else
            cfg="$HOME/.claude"
        fi
    fi
    # Hard floor: never launch with an empty config dir (an empty
    # CLAUDE_CONFIG_DIR makes claude treat the cwd as its config root),
    # and always hand the child an absolute path (:A also anchors a
    # relative inherited value to the current cwd instead of letting
    # claude re-anchor it to whatever cwd it sees).
    cfg="${cfg:-$HOME/.claude}"
    cfg="${cfg:A}"
    CLAUDE_CONFIG_DIR="$cfg" command claude "${forwarded[@]}"
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `sh zsh/claude-account.test.sh`
Expected: all PASS, `0 failed`.

- [ ] **Step 5: Register the suite**

In `bin/dotfiles-tests`, add to the `SUITES` list directly after `sh zsh/functions.test.sh`:

```
sh zsh/claude-account.test.sh
```

Run: `bin/dotfiles-tests --list` and confirm the new line appears.

- [ ] **Step 6: Commit**

```bash
git add zsh/claude-account.zsh zsh/claude-account.test.sh bin/dotfiles-tests
git commit -m "zsh: Add self-contained account routing file with tests"
```

---

### Task 2: Tracked `zsh/.zshenv` + shell-mode matrix tests

**Files:**
- Create: `zsh/.zshenv`
- Modify: `zsh/claude-account.test.sh` (append shell-mode cases before the final summary lines)
- Modify: `zsh/functions.zsh:225-281` (delete the "Claude Code Accounts" section -- in this task, not later: once `.zshenv` provides the hardened definitions, leaving the old block in `.zshrc`'s chain would re-define the vulnerable wrapper in every interactive shell, since `.zshrc` sources after `.zshenv`)
- Modify: `.github/workflows/tests.yml` (zsh syntax-check file list)

**Interfaces:**
- Consumes: `zsh/claude-account.zsh` (Task 1), sourced by sibling path.
- Produces: `zsh/.zshenv` -- the file Task 3 symlinks to `~/.zshenv`.

- [ ] **Step 1: Write the failing tests**

In `zsh/claude-account.test.sh`, insert before the final `printf '\n%d passed...'` line:

```sh
# --- shell-mode matrix: wrapper defined via .zshenv in -lc / -c / -ic ---
# ZDOTDIR sandbox mirrors the installed layout: $ZDOTDIR/.zshenv is a
# symlink to the repo file, so the sibling-path resolution is exercised.
ZDIR="$TMP/zdot"
mkdir -p "$ZDIR"
ln -s "$REPO/zsh/.zshenv" "$ZDIR/.zshenv"

# run_mode <label> <zsh-flags> <cwd> <zsh-body> <expected-cfg>
run_mode() {
    label="$1" flags="$2" cwd="$3" body="$4" want_cfg="$5"
    rec="$TMP/rec"
    : > "$rec"
    RECORD="$rec" HOME="$SBHOME" ZDOTDIR="$ZDIR" PATH="$TMP/bin:$PATH" \
        zsh "$flags" "cd '$cwd' && $body" >/dev/null 2>&1
    got_cfg="$(sed -n 's/^cfg=//p' "$rec")"
    if [ "$got_cfg" = "$want_cfg" ]; then
        pass "$label"
    else
        fail "$label (cfg='$got_cfg')"
    fi
}

# The full precedence ladder per startup mode (spec: matrix rows apply to
# every shell mode). Reuses the sandbox dirs and work-shortcut symlink
# created by the Task 1 cases.
for mode in "-lc" "-c" "-ic"; do
    run_mode "zsh $mode: personal cwd routes to ~/.claude" \
        "$mode" "$SBHOME/elsewhere" "claude" "$SBHOME/.claude"
    run_mode "zsh $mode: work cwd routes to ~/.claude-work" \
        "$mode" "$SBHOME/Git/work/proj" "claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: symlinked work path routes to work" \
        "$mode" "$SBHOME/work-shortcut" "claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: non-empty env wins" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
    run_mode "zsh $mode: exported-empty env consumed (work cwd)" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR= claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: exported-empty env consumed (personal cwd)" \
        "$mode" "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR= claude" "$SBHOME/.claude"
    run_mode "zsh $mode: --personal beats custom env" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude --personal" "$SBHOME/.claude"
done

# .zshenv contract: silent on success, no external commands.
out="$(HOME="$SBHOME" ZDOTDIR="$ZDIR" zsh -c 'true' 2>&1)"
if [ -z "$out" ]; then
    pass ".zshenv is silent on startup"
else
    fail ".zshenv is silent on startup (got: $out)"
fi
if grep -vE '^[[:space:]]*#|^[[:space:]]*$' zsh/.zshenv | grep -qE '\$\(|`'; then
    fail ".zshenv runs no external commands (no command substitution)"
else
    pass ".zshenv runs no external commands (no command substitution)"
fi

# Degraded state 1: dangling ~/.zshenv symlink is a silent no-op.
ZBROKEN="$TMP/zdot-broken"
mkdir -p "$ZBROKEN"
ln -s "$TMP/nonexistent/.zshenv" "$ZBROKEN/.zshenv"
out="$(HOME="$SBHOME" ZDOTDIR="$ZBROKEN" zsh -c 'true' 2>&1)"
if [ -z "$out" ]; then
    pass "broken .zshenv link degrades to silent no-op"
else
    fail "broken .zshenv link degrades to silent no-op (got: $out)"
fi

# Degraded state 2: the tracked .zshenv runs but its sibling
# claude-account.zsh is missing -> silent, and claude falls through to
# the bare binary (stub sees no injected value).
ZDEG="$TMP/zdot-degraded"
mkdir -p "$ZDEG/zsh-copy"
cp "$REPO/zsh/.zshenv" "$ZDEG/zsh-copy/.zshenv"
ln -s "$ZDEG/zsh-copy/.zshenv" "$ZDEG/.zshenv"
: > "$TMP/rec"
out="$(RECORD="$TMP/rec" HOME="$SBHOME" ZDOTDIR="$ZDEG" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$SBHOME/Git/work/proj' && claude" 2>&1)"
got_cfg="$(sed -n 's/^cfg=//p' "$TMP/rec")"
if [ -z "$out" ] && [ "$got_cfg" = "UNSET" ]; then
    pass "missing sibling: silent no-op, bare binary runs"
else
    fail "missing sibling: silent no-op, bare binary runs (out='$out' cfg='$got_cfg')"
fi

# Degraded state 3: unreadable sibling -> same silent no-op (-r guard).
cp "$REPO/zsh/claude-account.zsh" "$ZDEG/zsh-copy/claude-account.zsh"
chmod 000 "$ZDEG/zsh-copy/claude-account.zsh"
: > "$TMP/rec"
out="$(RECORD="$TMP/rec" HOME="$SBHOME" ZDOTDIR="$ZDEG" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$SBHOME/Git/work/proj' && claude" 2>&1)"
got_cfg="$(sed -n 's/^cfg=//p' "$TMP/rec")"
chmod 644 "$ZDEG/zsh-copy/claude-account.zsh"
if [ -z "$out" ] && [ "$got_cfg" = "UNSET" ]; then
    pass "unreadable sibling: silent no-op, bare binary runs"
else
    fail "unreadable sibling: silent no-op, bare binary runs (out='$out' cfg='$got_cfg')"
fi

# ~/.zshenv.local is sourced when present.
echo 'export ZSHENV_LOCAL_MARK=1' > "$SBHOME/.zshenv.local"
val="$(HOME="$SBHOME" ZDOTDIR="$ZDIR" zsh -c 'echo "${ZSHENV_LOCAL_MARK:-missing}"' 2>/dev/null)"
rm -f "$SBHOME/.zshenv.local"
if [ "$val" = "1" ]; then
    pass ".zshenv sources ~/.zshenv.local"
else
    fail ".zshenv sources ~/.zshenv.local (got '$val')"
fi
```

Note: when `ZDOTDIR` is set, zsh reads `$ZDOTDIR/.zshenv` instead of
`~/.zshenv` -- which is exactly why the tracked file must reference
`$HOME/.zshenv.local` (not `$ZDOTDIR/...`) for the local include; the
last case pins that.

- [ ] **Step 2: Run to verify the new cases fail**

Run: `sh zsh/claude-account.test.sh`
Expected: the `zsh -lc/-c/-ic` and `.zshenv` cases FAIL (file absent); Task 1 cases still PASS.

- [ ] **Step 3: Write `zsh/.zshenv`**

```zsh
#!/bin/zsh
# .zshenv -- read by EVERY zsh: interactive, login, and non-interactive.
# Keep this file tiny and silent (zero output on success, no external
# commands); heavier setup belongs in .zprofile / .zshrc.

# Machine-local additions. The installer migrates a pre-existing
# hand-managed ~/.zshenv here (install/common/zshenv-migrate.sh).
[[ -f "$HOME/.zshenv.local" && -r "$HOME/.zshenv.local" ]] && \
    source "$HOME/.zshenv.local"

# Claude account routing must exist in all shell modes: zsh -lc / zsh -c
# never read .zshrc, and headless probes and orchestrator dispatches run
# there (unrouted launches have hit login screens and dumped config trees
# into the cwd). Resolve the repo through this file's own symlink; a
# missing or unreadable target degrades to a silent no-op
# (symlink-audit.sh flags it).
_dotfiles_zshenv="${${(%):-%N}:A}"
[[ -f "${_dotfiles_zshenv:h}/claude-account.zsh" && -r "${_dotfiles_zshenv:h}/claude-account.zsh" ]] && \
    source "${_dotfiles_zshenv:h}/claude-account.zsh"
unset _dotfiles_zshenv
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `sh zsh/claude-account.test.sh`
Expected: all PASS, `0 failed`.

- [ ] **Step 5: Delete the accounts block from `zsh/functions.zsh`**

Remove lines 225-281: the `###### Claude Code Accounts` header comment
block, the `CLAUDE_WORK_CONFIG_DIR`/`CLAUDE_WORK_TREE` assignments,
`_claude_config_dir()`, `claude-account()`, and `claude()` -- everything
up to (not including) the `##############################` header of
`###### Claude Code Plugins`. Leave a one-line pointer in their place:

```zsh
# Claude account routing (claude(), claude-account) lives in
# zsh/claude-account.zsh, sourced from zsh/.zshenv so it exists in
# non-interactive shells too.
```

Verify:

Run: `grep -c "^function claude()" zsh/functions.zsh zsh/claude-account.zsh`
Expected: `0` in functions.zsh, `1` in claude-account.zsh.

Run: `sh zsh/functions.test.sh`
Expected: `0 failed` (its assertions only touch the plugin helpers).

- [ ] **Step 6: Add the new files to the CI zsh syntax gate**

In `.github/workflows/tests.yml`, the "zsh syntax check" step iterates a
hard-coded list. Add the two new files:

```yaml
          for f in zsh/.zshenv zsh/.zshrc zsh/.zprofile zsh/aliases.zsh zsh/claude-account.zsh zsh/functions.zsh zsh/theme.zsh zsh/scripts/*.zsh; do
```

Run locally: `zsh -n zsh/.zshenv && zsh -n zsh/claude-account.zsh && echo OK`
Expected: `OK`.

- [ ] **Step 7: Commit**

```bash
git add zsh/.zshenv zsh/claude-account.test.sh zsh/functions.zsh .github/workflows/tests.yml
git commit -m "zsh: Define account routing via .zshenv for all shell modes"
```

---

### Task 3: Installer migration + `~/.zshenv` symlink + audit entry

**Files:**
- Create: `install/common/zshenv-migrate.sh`
- Create: `install/zshenv-migrate.test.sh`
- Modify: `install/common/link.sh` (ZSH section, after the `.zshrc` line)
- Modify: `.claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh` (zsh section)
- Modify: `bin/dotfiles-tests` (SUITES list)

**Interfaces:**
- Consumes: `zsh/.zshenv` (Task 2).
- Produces: `migrate_home_zshenv <home> <repo_zshenv_path>` -- returns 0 when the caller may create the symlink, 1 when it must skip. Sourced by `link.sh`.

- [ ] **Step 1: Write the failing test suite**

Create `install/zshenv-migrate.test.sh`:

```sh
#!/bin/sh
# zshenv-migrate.test.sh -- migration state table for migrate_home_zshenv
# (install/common/zshenv-migrate.sh). One case per spec table row plus
# idempotence. Runs against a sandbox HOME; never touches the real one.

set -u

MIG=install/common/zshenv-migrate.sh
if [ ! -f "$MIG" ]; then
    echo "FAIL: $MIG not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zshenv-migrate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO_ZSHENV="$(pwd)/zsh/.zshenv"

fresh_home() {
    rm -rf "$TMP/home"
    mkdir -p "$TMP/home"
    echo "$TMP/home"
}

# run_migrate <home>; captures stdout+stderr in $OUT, exit code in $RC
run_migrate() {
    OUT="$(bash -c ". '$MIG' && migrate_home_zshenv '$1' '$REPO_ZSHENV'" 2>&1)"
    RC=$?
}

# Row 1: absent -> proceed, nothing created.
H="$(fresh_home)"
run_migrate "$H"
if [ "$RC" = 0 ] && [ ! -e "$H/.zshenv" ] && [ ! -e "$H/.zshenv.local" ]; then
    pass "absent: proceed, no side effects"
else
    fail "absent: proceed, no side effects (rc=$RC)"
fi

# Row 2: symlink to repo file -> proceed silently.
H="$(fresh_home)"
ln -s "$REPO_ZSHENV" "$H/.zshenv"
run_migrate "$H"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
    pass "managed symlink: silent no-op"
else
    fail "managed symlink: silent no-op (rc=$RC out='$OUT')"
fi

# Row 3: symlink elsewhere -> proceed with notice naming old target.
H="$(fresh_home)"
ln -s /somewhere/else "$H/.zshenv"
run_migrate "$H"
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "/somewhere/else"; then
    pass "foreign symlink: proceed, notice names old target"
else
    fail "foreign symlink: proceed, notice names old target (rc=$RC out='$OUT')"
fi

# Row 4: regular file, no .zshenv.local -> moved to .zshenv.local.
H="$(fresh_home)"
echo 'echo local-stuff' > "$H/.zshenv"
run_migrate "$H"
if [ "$RC" = 0 ] && [ ! -e "$H/.zshenv" ] \
    && [ "$(cat "$H/.zshenv.local")" = "echo local-stuff" ]; then
    pass "regular file: migrated to .zshenv.local"
else
    fail "regular file: migrated to .zshenv.local (rc=$RC)"
fi

# Row 5: regular file AND .zshenv.local -> timestamped backup, loud notice.
H="$(fresh_home)"
echo 'old zshenv' > "$H/.zshenv"
echo 'existing local' > "$H/.zshenv.local"
run_migrate "$H"
bak="$(ls "$H"/.zshenv.dotfiles-bak.* 2>/dev/null | head -1)"
if [ "$RC" = 0 ] && [ -n "$bak" ] && [ "$(cat "$bak")" = "old zshenv" ] \
    && [ "$(cat "$H/.zshenv.local")" = "existing local" ] && [ -n "$OUT" ]; then
    pass "collision: backup created, local untouched, notice printed"
else
    fail "collision: backup created, local untouched, notice printed (rc=$RC)"
fi

# Row 6: directory -> skip with error, nothing moved.
H="$(fresh_home)"
mkdir "$H/.zshenv"
run_migrate "$H"
if [ "$RC" != 0 ] && [ -d "$H/.zshenv" ]; then
    pass "directory: skip link, error, untouched"
else
    fail "directory: skip link, error, untouched (rc=$RC)"
fi

# Row 5b: dangling .zshenv.local symlink counts as occupied (never
# overwritten): old file goes to a backup instead.
H="$(fresh_home)"
echo 'old zshenv' > "$H/.zshenv"
ln -s "$H/nonexistent" "$H/.zshenv.local"
run_migrate "$H"
bak="$(ls "$H"/.zshenv.dotfiles-bak.* 2>/dev/null | head -1)"
if [ "$RC" = 0 ] && [ -n "$bak" ] && [ -L "$H/.zshenv.local" ]; then
    pass "dangling local symlink: preserved, backup used"
else
    fail "dangling local symlink: preserved, backup used (rc=$RC)"
fi

# Backup collision: a second migration in the same epoch second must not
# overwrite the first backup (collision-free suffix loop).
H="$(fresh_home)"
echo 'first' > "$H/.zshenv"
echo 'local' > "$H/.zshenv.local"
run_migrate "$H"
echo 'second' > "$H/.zshenv"
run_migrate "$H"
count="$(ls "$H"/.zshenv.dotfiles-bak.* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RC" = 0 ] && [ "$count" = 2 ]; then
    pass "backup collision: both backups kept"
else
    fail "backup collision: both backups kept (rc=$RC count=$count)"
fi

# Foreign symlink to a DIRECTORY + the link.sh replacement command:
# ln -sfn must replace the symlink itself, not plant a link inside the
# directory it points to.
H="$(fresh_home)"
mkdir -p "$H/somedir"
ln -s "$H/somedir" "$H/.zshenv"
run_migrate "$H"
ln -sfn "$REPO_ZSHENV" "$H/.zshenv"
if [ "$RC" = 0 ] && [ "$(readlink "$H/.zshenv")" = "$REPO_ZSHENV" ] \
    && [ ! -e "$H/somedir/.zshenv" ]; then
    pass "symlink-to-directory: replaced in place, target dir untouched"
else
    fail "symlink-to-directory: replaced in place, target dir untouched (rc=$RC)"
fi

# Idempotence: migrate, link, migrate again -> silent no-op.
H="$(fresh_home)"
echo 'once' > "$H/.zshenv"
run_migrate "$H"
ln -sf "$REPO_ZSHENV" "$H/.zshenv"
run_migrate "$H"
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(cat "$H/.zshenv.local")" = "once" ]; then
    pass "repeat run: idempotent no-op"
else
    fail "repeat run: idempotent no-op (rc=$RC out='$OUT')"
fi

# link.sh integration: sources the helper and links ~/.zshenv.
if grep -q 'zshenv-migrate.sh' install/common/link.sh; then
    pass "link.sh sources zshenv-migrate.sh"
else
    fail "link.sh sources zshenv-migrate.sh"
fi
if grep -q 'zsh/.zshenv "\$HOME"/.zshenv' install/common/link.sh; then
    pass "link.sh links ~/.zshenv"
else
    fail "link.sh links ~/.zshenv"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `sh install/zshenv-migrate.test.sh`
Expected: exit 2, `FAIL: install/common/zshenv-migrate.sh not found`.

- [ ] **Step 3: Write `install/common/zshenv-migrate.sh`**

```bash
#!/usr/bin/env bash
# zshenv-migrate.sh - move a machine-local ~/.zshenv aside before link.sh
# replaces it with the tracked symlink. Kept as a function in its own file so
# the test suite can exercise it against a sandbox HOME. Non-destructive and
# idempotent: existing content is moved, never overwritten or deleted.

# migrate_home_zshenv <home> <repo_zshenv_path>
# Returns 0 when the caller may create the ~/.zshenv symlink, 1 to skip.
migrate_home_zshenv() {
  local home="$1" repo_zshenv="$2"
  local target="$home/.zshenv"
  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" != "$repo_zshenv" ]; then
      echo "NOTICE: replacing ~/.zshenv symlink (old target: $(readlink "$target"))"
    fi
    return 0
  fi
  if [ ! -e "$target" ]; then
    return 0
  fi
  if [ -f "$target" ]; then
    # -e misses a dangling ~/.zshenv.local symlink; treat any existing
    # entry (including broken links) as occupied -- never overwrite.
    if [ ! -e "$home/.zshenv.local" ] && [ ! -L "$home/.zshenv.local" ]; then
      mv "$target" "$home/.zshenv.local"
      echo "NOTICE: moved machine-local ~/.zshenv to ~/.zshenv.local (sourced by the tracked .zshenv)"
    else
      local bak="$home/.zshenv.dotfiles-bak.$(date +%s)" n=0
      while [ -e "$bak" ] || [ -L "$bak" ]; do
        n=$((n + 1))
        bak="$home/.zshenv.dotfiles-bak.$(date +%s).$n"
      done
      mv "$target" "$bak"
      echo "NOTICE: ~/.zshenv.local already exists; moved old ~/.zshenv to $bak -- its content no longer executes, merge it into ~/.zshenv.local manually"
    fi
    return 0
  fi
  echo "ERROR: ~/.zshenv is neither a regular file nor a symlink; skipping the .zshenv link (fix manually; symlink-audit will flag it)" >&2
  return 1
}
```

- [ ] **Step 4: Wire into `install/common/link.sh`**

In the ZSH section, after `ln -sf "$DOTFILEDIR"/zsh/.zshrc "$HOME"/.zshrc`, add:

```bash
# ~/.zshenv is tracked (account routing must exist in non-interactive
# shells); a pre-existing machine-local file is migrated to ~/.zshenv.local.
# ln -sfn, not -sf: a foreign symlink pointing at a directory would
# otherwise be followed, planting the new link INSIDE that directory.
source "$DOTFILEDIR"/install/common/zshenv-migrate.sh
if migrate_home_zshenv "$HOME" "$DOTFILEDIR/zsh/.zshenv"; then
  ln -sfn "$DOTFILEDIR"/zsh/.zshenv "$HOME"/.zshenv
fi
```

(`link.sh` runs under `set -e`; the `if` guard keeps a return of 1 from aborting the install.)

- [ ] **Step 5: Add the audit entry**

In `symlink-audit.sh`, in the `--- zsh ---` block after the `.zshrc` line, add:

```sh
  check_link "$HOME/.zshenv"                  "$DOTFILES/zsh/.zshenv"
```

- [ ] **Step 6: Register the suite and run**

Add to `bin/dotfiles-tests` SUITES after `sh install/install.test.sh`:

```
sh install/zshenv-migrate.test.sh
```

Run: `sh install/zshenv-migrate.test.sh`
Expected: all PASS, `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add install/common/zshenv-migrate.sh install/zshenv-migrate.test.sh install/common/link.sh .claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh bin/dotfiles-tests
git commit -m "install: Link tracked .zshenv with non-destructive migration"
```

---

### Task 4: Docs + full-suite verification

**Files:**
- Modify: `CLAUDE.md` (symlink-targets bullet for `zsh/`, and the `claude/` bullet's wrapper reference)
- Modify: `README.md:150` and `README.md:239`

**Interfaces:**
- Consumes: `zsh/claude-account.zsh` + `zsh/.zshenv` (Tasks 1-2) provide all definitions; interactive shells read `.zshenv` before `.zshrc`, so nothing else changes.

- [ ] **Step 1: Update docs**

`README.md:150`: change

```
│   ├── functions.zsh # Shell functions (includes claude() account wrapper)
```

to

```
│   ├── claude-account.zsh # claude() account wrapper (sourced by .zshenv)
│   ├── functions.zsh # Shell functions
```

`README.md:239`: change the bullet to

```
- The `claude()` ZSH wrapper selects `~/.claude-work` when launching under `~/Git/work`, `~/.claude` otherwise. `claude-account` shows the active routing. Defined in `zsh/claude-account.zsh`, sourced from `~/.zshenv`, so routing works in non-interactive and login shells (headless probes, orchestrator dispatches) -- the launched process always gets an explicit non-empty `CLAUDE_CONFIG_DIR`.
```

`CLAUDE.md` symlink-targets list: change the `zsh/` bullet to

```
- `zsh/` -> `~/.zshrc`, `~/.zprofile`, `~/.zshenv` (`.zshenv` sources `zsh/claude-account.zsh` so the `claude()` wrapper exists in non-interactive shells; machine-local additions live in `~/.zshenv.local`, migrated there from a pre-existing `~/.zshenv` by `install/common/zshenv-migrate.sh`)
```

and in the `claude/` bullet replace `the claude() wrapper in zsh/functions.zsh` with `the claude() wrapper in zsh/claude-account.zsh`.

- [ ] **Step 2: Full suite + live smoke check**

Run: `bin/dotfiles-tests`
Expected: every suite green (record the pass/fail counts and compare with the pre-Task-1 baseline run).

Live smoke (simulates an installed machine without touching the real `~/.zshenv`):

```bash
ZD="$(mktemp -d)" && ln -s "$PWD/zsh/.zshenv" "$ZD/.zshenv" && ZDOTDIR="$ZD" zsh -lc 'whence -w claude'
```

Expected output: `claude: function`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: Point account-wrapper references at the .zshenv layout"
```

---

## Self-review notes

- Spec coverage: matrix rows -> Task 1 cases 1-8 and Task 2 full per-mode loop (-lc/-c/-ic); migration table -> Task 3 rows 1-6 plus dangling-local, backup-collision, symlink-to-directory, and idempotence; docs -> Task 4; audit entry -> Task 3 step 5; compatibility contract -> Task 1 cases (labels, filtering, precedence, exit status).
- Intentional behavior changes (spec) are all encoded as test expectations: always-inject (case 1), empty-consumed (case 5), `--personal` beats custom env (case 6), `CLAUDE_WORK_*` survive (case 7), relative env normalized (case 4b).
- Baseline discipline: run `bin/dotfiles-tests` once before Task 1 and record counts; Task 4 step 2 compares against it.
- Out of scope honored: no herdr changes, no bash shim, no cloud changes.

## Review notes

Codex plan review (2026-08-31, verdict needs-rework) produced 11
findings. Folded in: comment-safe static assert; corrected
symlink-into-work-tree test direction; `:A` normalization for the
absolute-path invariant; full precedence ladder per shell mode;
`-f && -r` guards plus missing/unreadable-sibling degraded tests;
`ln -sfn` with a symlink-to-directory case; collision-free timestamped
backups and dangling-`.zshenv.local` handling; the `functions.zsh`
block removal moved into Task 2 so no interactive window runs the old
wrapper; per-arg stub recording; CI zsh syntax list gains both new
files. Declined as disproportionate to a two-file shell change:
exhaustive argv quoting/stream pass-through matrices, and runtime
instrumentation proving "no external commands" (the silent-startup
behavioral case plus the substitution grep cover the practical risk).
