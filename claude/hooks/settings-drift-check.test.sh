#!/bin/sh
# settings-drift-check.test.sh -- behavioral tests for settings_drift_check.py
# (SessionStart). The hook compares the reconcile-time template stamp with the
# current template and recommends `update --ai` on mismatch. Advisory only:
# every failure path is silent exit 0.
set -u

HOOK=claude/hooks/settings_drift_check.py
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found (run from repo root)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drift-check-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd)"
trap 'rm -rf "$TMP"' EXIT

# Fixture: fake dotfiles repo with a template, and a config dir whose hooks/
# symlink points into it (that is how the hook finds the repo).
REPO="$TMP/dotfiles"
mkdir -p "$REPO/claude/hooks"
printf '{"hooks": {}}\n' > "$REPO/claude/settings.json.tmpl"
CDIR="$TMP/config"
mkdir -p "$CDIR"
ln -s "$REPO/claude/hooks" "$CDIR/hooks"

sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

run_hook() {
    # stdout -> $TMP/hook.out, stderr -> $TMP/hook.err
    CLAUDE_CONFIG_DIR="$CDIR" python3 "$HOOK" </dev/null >"$TMP/hook.out" 2>"$TMP/hook.err"
}

# 1. Matching stamp: silent on both streams.
sha_of "$REPO/claude/settings.json.tmpl" > "$CDIR/.settings-template-sha256"
run_hook; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/hook.out" ] && [ ! -s "$TMP/hook.err" ] \
    && pass "matching stamp is silent" || fail "matching stamp is silent (rc=$rc)"

# 2. Stale stamp: warns on stdout JSON and stderr line.
echo "0000000000000000000000000000000000000000000000000000000000000000" > "$CDIR/.settings-template-sha256"
run_hook; rc=$?
grep -q "update --ai" "$TMP/hook.out" \
    && pass "stale stamp warns to run update --ai (stdout)" || fail "stale stamp warns to run update --ai (stdout)"
grep -q "\[WARNING\].*update --ai" "$TMP/hook.err" \
    && pass "stale stamp warns on stderr" || fail "stale stamp warns on stderr"
[ "$rc" -eq 0 ] && pass "stale stamp still exits 0" || fail "stale stamp still exits 0"

# 3. Missing stamp: warns (never reconciled since feature landed).
rm -f "$CDIR/.settings-template-sha256"
run_hook
grep -q "update --ai" "$TMP/hook.out" \
    && pass "missing stamp warns" || fail "missing stamp warns"

# 4. Corrupt (non-UTF-8) stamp: warns, never tracebacks.
printf '\377\376garbage' > "$CDIR/.settings-template-sha256"
run_hook; rc=$?
[ "$rc" -eq 0 ] && grep -q "update --ai" "$TMP/hook.out" && ! grep -q "Traceback" "$TMP/hook.err" \
    && pass "corrupt stamp warns without traceback" || fail "corrupt stamp warns without traceback (rc=$rc)"

# 5. Unresolvable template (hooks symlink broken): silent exit 0.
rm -f "$CDIR/hooks"
ln -s "$TMP/nowhere" "$CDIR/hooks"
run_hook; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/hook.out" ] && [ ! -s "$TMP/hook.err" ] \
    && pass "unresolvable template is silent" || fail "unresolvable template is silent (rc=$rc)"

# 6. Warning stdout is valid hook JSON with additionalContext.
rm -f "$CDIR/hooks"; ln -s "$REPO/claude/hooks" "$CDIR/hooks"
echo "0000000000000000000000000000000000000000000000000000000000000000" > "$CDIR/.settings-template-sha256"
run_hook
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "additionalContext" in d["hookSpecificOutput"]' "$TMP/hook.out" \
    && pass "warning is valid SessionStart JSON" || fail "warning is valid SessionStart JSON"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
