#!/bin/sh
# symlink-audit.test.sh -- behavioral tests for symlink-audit.sh: map parity
# with the real installer, orphan classification, scan errors, and read-only
# runs. The installer runs from a disposable copy of this checkout because
# link_codex_surfaces deletes legacy files inside its own DOTFILEDIR.
set -u

AUDIT_REL=.claude/skills/dotfiles-diagnostics-and-tooling/scripts/symlink-audit.sh
[ -f "$AUDIT_REL" ] || { echo "FAIL: $AUDIT_REL not found (run from repo root)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }
REPO="$(pwd -P)"
AUDIT="$REPO/$AUDIT_REL"

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
# expect_same <label> <expected> <actual>
expect_same() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1"
        printf -- '--- expected\n%s\n--- actual\n%s\n' "$2" "$3" >&2
    fi
}
# has_line <label> <file> <exact line>
has_line() {
    if grep -qxF -- "$3" "$2"; then pass "$1"; else fail "$1"; fi
}
# snapshot <dir>: one line per entry (path, type, mode, size, mtime_ns, link
# target, sha256); links are never followed and unlistable dirs are marked.
snapshot() {
    python3 - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
out = []
def record(path):
    st = os.lstat(path)
    kind = "l" if stat.S_ISLNK(st.st_mode) else "d" if stat.S_ISDIR(st.st_mode) else "f"
    target = os.readlink(path) if kind == "l" else ""
    digest = ""
    if kind == "f" and os.access(path, os.R_OK):
        with open(path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
    out.append("%s|%s|%o|%d|%d|%s|%s" % (os.path.relpath(path, root), kind, st.st_mode,
                                           st.st_size, st.st_mtime_ns, target, digest))
    return kind
def walk(d):
    try:
        names = sorted(os.listdir(d))
    except OSError:
        out.append(os.path.relpath(d, root) + "|unreadable")
        return
    for name in names:
        path = os.path.join(d, name)
        if record(path) == "d":
            walk(path)
record(root)
walk(root)
print("\n".join(out))
PY
}
# audit_ro <out-file> <home> [audit args...]: run the audit (DOTFILES=$SRC, and
# PATH=$AUDIT_PATH when set) between two complete snapshots of fixtures/. RC
# gets the audit's exit status; a changed or incomplete snapshot is a failure.
RO_RUNS=0
RO_BAD=0
audit_ro() {
    ro_out="$1"
    ro_home="$2"
    shift 2
    snapshot "$FIX" >"$EVI/ro-before.txt"
    ro_before=$?
    HOME="$ro_home" DOTFILES="$SRC" PATH="${AUDIT_PATH:-$PATH}" /bin/bash "$AUDIT" "$@" >"$ro_out" 2>&1
    RC=$?
    snapshot "$FIX" >"$EVI/ro-after.txt"
    ro_after=$?
    RO_RUNS=$((RO_RUNS + 1))
    if [ "$ro_before" -ne 0 ] || [ "$ro_after" -ne 0 ] || [ ! -s "$EVI/ro-before.txt" ] ||
        ! cmp -s "$EVI/ro-before.txt" "$EVI/ro-after.txt"; then
        RO_BAD=$((RO_BAD + 1))
        fail "audit left fixtures/ unchanged: $ro_out"
    fi
}

# Validate the scratch dir before the EXIT trap exists: an empty TMP would turn
# every fixture path into an absolute path under /.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/symlink-audit-test.XXXXXX")" \
    || { echo "FAIL: cannot create temp dir" >&2; exit 2; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: bad temp dir" >&2; exit 2; }
TMP="$(cd -P "$TMP" && pwd)" || { echo "FAIL: cannot resolve temp dir" >&2; exit 2; }
case "$TMP" in /?*) ;; *) echo "FAIL: temp dir not absolute" >&2; exit 2 ;; esac
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM
FIX="$TMP/fixtures"
EVI="$TMP/evidence"
SRC="$FIX/src/dotfiles"
H="$FIX/home"
HC="$FIX/cloud-home"
CO="$H/co"
mkdir -p "$FIX" "$EVI" "$SRC"
# --no-optional-locks: status must not refresh the real index while observing it.
STATUS_BEFORE="$(git -C "$REPO" --no-optional-locks status --porcelain)"

# Disposable source: tracked files as they are on disk now. Untracked paths are
# left out so an ignored-but-present symlink cannot carry installer writes out.
if git -C "$REPO" ls-files -z --cached >"$EVI/files.lst" &&
    python3 - "$REPO" "$SRC" "$EVI/files.lst" <<'PY'
import os, shutil, sys
repo, dst, listing = sys.argv[1:]
for raw in open(listing, "rb").read().split(b"\0"):
    if not raw:
        continue
    rel = os.fsdecode(raw)
    src = os.path.join(repo, rel)
    if not os.path.lexists(src):
        continue
    out = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.islink(src):
        os.symlink(os.readlink(src), out)
    else:
        shutil.copy2(src, out)
PY
then
    pass "source checkout copied"
else
    fail "source checkout copied"
    printf '%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
# Physical resolution follows chained links and "..", so two links that each
# look contained cannot compose into an escape. A walk error or a crash fails
# closed: the check passes only when python exits 0 and names no escape.
ESCAPES="$(python3 - "$SRC" <<'PY'
import os, sys
root = os.path.realpath(sys.argv[1])
def boom(err):
    raise err
for d, dirs, files in os.walk(root, onerror=boom):
    for name in dirs + files:
        path = os.path.join(d, name)
        if os.path.islink(path):
            target = os.path.realpath(path)
            if target != root and not target.startswith(root + os.sep):
                print(path)
PY
)"
ESCAPE_RC=$?
if [ "$ESCAPE_RC" -eq 0 ] && [ -z "$ESCAPES" ]; then
    pass "no symlink in the source copy points outside it"
else
    fail "no symlink in the source copy points outside it (rc=$ESCAPE_RC): $ESCAPES"
    printf '%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi

# Stub PATH: only these tools, so no claude, codex, uv or zsh can run.
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
for tool in bash sh python3 git id env uname cat ln rm rmdir mkdir mv cp chmod touch \
    dirname basename readlink find grep sed awk tr wc date sort head tail; do
    p="$(command -v "$tool" 2>/dev/null)" || continue
    case "$p" in /*) ln -s "$p" "$STUB/$tool" ;; esac
done
PLATFORM=linux
[ "$(uname)" = Darwin ] && PLATFORM=macos

env -i HOME="$H" PATH="$STUB" TMPDIR="$TMP" CODEX_HOME="$H/.codex" \
    bash "$SRC/install/$PLATFORM/link.sh" >"$EVI/install.log" 2>&1
expect_same "installer exits 0 against scratch HOME" 0 "$?"
if grep -q 'command not found' "$EVI/install.log"; then
    fail "installer log has no 'command not found'"
else
    pass "installer log has no 'command not found'"
fi

audit_ro "$EVI/rows.tsv" "$H" --list-expected
expect_same "--list-expected exits 0" 0 "$RC"
N_ROWS="$(wc -l <"$EVI/rows.tsv" | tr -d ' ')"
expect_same "installer symlinks equal the audit's link rows (full)" \
    "$(awk -F '\t' '$1 == "link" {print $2}' "$EVI/rows.tsv" | LC_ALL=C sort)" \
    "$(find -P "$H" -type l | LC_ALL=C sort)"
OUTSIDE="$(find -P "$H" -type l -exec readlink {} \; | grep -v -- "^$SRC/")"
expect_same "every installed link targets the source copy" "" "$OUTSIDE"
LOCAL_BAD=""
for p in $(awk -F '\t' '$1 == "machine-local" {print $2}' "$EVI/rows.tsv"); do
    if [ ! -f "$p" ] || [ -L "$p" ]; then LOCAL_BAD="$LOCAL_BAD $p"; fi
done
expect_same "machine-local rows are regular files" "" "$LOCAL_BAD"
expect_same "five machine-local rows" 5 "$(grep -c '^machine-local' "$EVI/rows.tsv")"
audit_ro "$EVI/pristine.out" "$H"
expect_same "pristine install: audit exits 0" 0 "$RC"

mkdir -p "$HC"
env -i HOME="$HC" PATH="$STUB" TMPDIR="$TMP" CODEX_HOME="$HC/.codex" DOTFILEDIR="$SRC" \
    bash -c '. "$DOTFILEDIR/install/common/claude-links.sh" && link_claude_config_dir "$HOME/.claude"' \
    >"$EVI/cloud-install.log" 2>&1
expect_same "cloud link layer exits 0" 0 "$?"
audit_ro "$EVI/cloud-rows.tsv" "$HC" --cloud --list-expected
expect_same "installer symlinks equal the audit's link rows (cloud)" \
    "$(awk -F '\t' '$1 == "link" {print $2}' "$EVI/cloud-rows.tsv" | LC_ALL=C sort)" \
    "$(find -P "$HC" -type l | LC_ALL=C sort)"
N_CLOUD="$(wc -l <"$EVI/cloud-rows.tsv" | tr -d ' ')"
audit_ro "$EVI/cloud.out" "$HC" --cloud
expect_same "cloud pristine: audit exits 0" 0 "$RC"

cp -R -P "$HC" "$FIX/states-home"
HS="$FIX/states-home"
ln -sfn "$SRC/claude/agents" "$HS/.claude/commands"
rm -f "$HS/.claude/hooks" && ln -s "$FIX/nowhere" "$HS/.claude/hooks"
rm -f "$HS/.claude/statusline.js" && touch "$HS/.claude/statusline.js"
rm -f "$HS/.claude/agents"
mv "$HS/.claude/settings.json" "$HS/.claude/settings.real" &&
    ln -s settings.real "$HS/.claude/settings.json"
audit_ro "$EVI/states.out" "$HS" --cloud
expect_same "broken cloud layout: audit exits 1" 1 "$RC"
has_line "state OK" "$EVI/states.out" "[OK] OK            $HS/.claude/CLAUDE.md"
has_line "state WRONG-TARGET" "$EVI/states.out" \
    "[X]  WRONG-TARGET  $HS/.claude/commands -> $SRC/claude/agents (expected $SRC/claude/commands)"
has_line "state DANGLING" "$EVI/states.out" "[X]  DANGLING      $HS/.claude/hooks -> $FIX/nowhere"
has_line "state NOT-A-LINK" "$EVI/states.out" \
    "[X]  NOT-A-LINK    $HS/.claude/statusline.js (real file/dir; expected symlink -> $SRC/claude/statusline.js)"
has_line "state MISSING" "$EVI/states.out" \
    "[X]  MISSING       $HS/.claude/agents (expected symlink -> $SRC/claude/agents)"
has_line "state IS-A-LINK" "$EVI/states.out" \
    "[X]  IS-A-LINK     $HS/.claude/settings.json -> settings.real (must be machine-local; installers write through symlinks into the repo)"

audit_ro "$EVI/nohome.out" /nonexistent-symlink-audit-home --list-expected
expect_same "--list-expected with a nonexistent HOME exits 0" 0 "$RC"
audit_ro "$EVI/bogus.out" "$H" --bogus
expect_same "unknown argument exits 2" 2 "$RC"

if [ "$RO_RUNS" -gt 0 ] && [ "$RO_BAD" -eq 0 ]; then
    pass "every audit run left fixtures/ unchanged ($RO_RUNS runs)"
else
    fail "every audit run left fixtures/ unchanged ($RO_BAD of $RO_RUNS changed or unreadable)"
fi
expect_same "real checkout unchanged by the suite" "$STATUS_BEFORE" "$(git -C "$REPO" --no-optional-locks status --porcelain)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
