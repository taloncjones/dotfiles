#!/bin/sh
# ai-update.test.sh -- behavioral tests for install/common/ai-update.sh:
# the Claude/Codex-layer-only update path (`update --ai`). Verifies the
# scoped path creates and repairs the same Claude + Codex symlink surfaces
# as the full install, without sudo, brew, or the zsh/git/ssh layers.
set -u

AI_UPDATE=install/common/ai-update.sh
[ -f "$AI_UPDATE" ] || { echo "FAIL: $AI_UPDATE not found (run from repo root)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-update-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd)"
trap 'rm -rf "$TMP"' EXIT

DOTFILEDIR="$(pwd)"
export DOTFILEDIR

# Run the scoped update against a scratch HOME with a SANITIZED environment:
# CODEX_HOME pinned into the scratch (inheriting the real one would let the
# Codex reconcilers write to the live ~/.codex), CLAUDE_CONFIG_DIR cleared,
# and PATH reduced to a stub bin holding only the tools the script needs
# (bash, git, python3, coreutils via symlinks) with NO claude, codex, zsh,
# or uv -- so claude-plugins.sh takes its existing warn-and-skip branch and
# nothing clones or installs (no network).
SCRATCH_HOME="$TMP/home"
mkdir -p "$SCRATCH_HOME"
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
for tool in bash sh git python3 mkdir rm ln mv cp cat grep sed awk find dirname basename date chmod rmdir touch wc sort head tail tr printf env; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -s "$p" "$STUB_BIN/$tool" 2>/dev/null
done
run_ai_update() {
    env -i HOME="$SCRATCH_HOME" PATH="$STUB_BIN" TMPDIR="$TMP" \
        CODEX_HOME="$SCRATCH_HOME/.codex" DOTFILEDIR="$DOTFILEDIR" \
        bash "$AI_UPDATE"
}
if run_ai_update >"$TMP/out.log" 2>&1; then
    pass "ai-update exits 0 against scratch HOME"
else
    fail "ai-update exits 0 against scratch HOME (see $TMP/out.log)"
fi

# Claude layer: both config dirs linked and settings reconciled.
for cdir in .claude .claude-work; do
    [ -L "$SCRATCH_HOME/$cdir/hooks" ] \
        && pass "$cdir/hooks symlinked" || fail "$cdir/hooks symlinked"
    [ -f "$SCRATCH_HOME/$cdir/settings.json" ] \
        && pass "$cdir/settings.json reconciled" || fail "$cdir/settings.json reconciled"
done

# Codex layer: shared skills and hooks linked by link_codex_surfaces.
[ -L "$SCRATCH_HOME/.codex/skills/handoff" ] \
    && pass "codex shared skill handoff linked" || fail "codex shared skill handoff linked"
[ -L "$SCRATCH_HOME/.codex/hooks/rm_guard.py" ] \
    && pass "codex rm_guard hook linked" || fail "codex rm_guard hook linked"
grep -q 'hooks = true' "$SCRATCH_HOME/.codex/config.toml" 2>/dev/null \
    && pass "codex hooks feature enabled" || fail "codex hooks feature enabled"

# Repair: delete a Codex skill link and re-run; it must come back.
rm -f "$SCRATCH_HOME/.codex/skills/handoff"
run_ai_update >/dev/null 2>&1
[ -L "$SCRATCH_HOME/.codex/skills/handoff" ] \
    && pass "re-run repairs deleted codex skill link" || fail "re-run repairs deleted codex skill link"

# Scope: the zsh/git/ssh layers are untouched.
[ ! -e "$SCRATCH_HOME/.zshrc" ] && [ ! -e "$SCRATCH_HOME/.gitconfig" ] && [ ! -e "$SCRATCH_HOME/.ssh/config" ] \
    && pass "no zsh/git/ssh files created" || fail "no zsh/git/ssh files created"

# No sudo: no non-comment line may invoke sudo.
! grep -qE '^[^#]*\bsudo\b' "$AI_UPDATE" \
    && pass "ai-update.sh contains no sudo invocation" || fail "ai-update.sh contains no sudo invocation"

# Failure propagation: a reconcile failure must fail the run. Simulate by
# making python3 unavailable in the stub PATH (reconcile requires it in
# strict mode); ai-update must exit non-zero, not print Done.
NOPY_BIN="$TMP/nopy-bin"
mkdir -p "$NOPY_BIN"
for tool in bash sh git mkdir rm ln mv cp cat grep sed awk find dirname basename date chmod rmdir touch wc sort head tail tr printf env; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -s "$p" "$NOPY_BIN/$tool" 2>/dev/null
done
if env -i HOME="$TMP/home2" PATH="$NOPY_BIN" TMPDIR="$TMP" \
    CODEX_HOME="$TMP/home2/.codex" DOTFILEDIR="$DOTFILEDIR" \
    bash "$AI_UPDATE" >"$TMP/nopy.log" 2>&1; then
    fail "ai-update fails when reconcile cannot run (missing python3)"
else
    pass "ai-update fails when reconcile cannot run (missing python3)"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
