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

has_line "pristine install: clean summary" "$EVI/pristine.out" \
    "symlink-audit: all $N_ROWS entries OK, no orphan links."
has_line "cloud pristine: clean summary" "$EVI/cloud.out" \
    "symlink-audit: all $N_CLOUD entries OK, no orphan links."

# Scan coverage: a dangling probe beside every map link is found.
awk -F '\t' '$1 == "link" {sub(/\/[^\/]*$/, "", $2); print $2}' "$EVI/rows.tsv" |
    LC_ALL=C sort -u >"$EVI/parents.txt"
EXPECT_PROBES=""
while IFS= read -r d; do
    ln -s "$SRC/zz-missing-probe" "$d/zz-probe"
    EXPECT_PROBES="$EXPECT_PROBES[X]  ORPHAN-DANGLING $d/zz-probe -> $SRC/zz-missing-probe (missing inside checkout $SRC)
"
done <"$EVI/parents.txt"
audit_ro "$EVI/probes.out" "$H"
expect_same "a probe beside every map link is reported" \
    "$(printf '%s' "$EXPECT_PROBES" | LC_ALL=C sort)" \
    "$(grep '^\[X\]  ORPHAN-' "$EVI/probes.out" | LC_ALL=C sort)"
while IFS= read -r d; do rm -f "$d/zz-probe"; done <"$EVI/parents.txt"

ln -s "$SRC/zsh/aliases.zsh" "$H/custom-aliases"
audit_ro "$EVI/unowned.out" "$H"
expect_same "UNOWNED-LIVE alone: audit exits 0" 0 "$RC"
has_line "UNOWNED-LIVE reported as info" "$EVI/unowned.out" \
    "[INFO] UNOWNED-LIVE  $H/custom-aliases -> $SRC/zsh/aliases.zsh (inside checkout $SRC; shared dir, not judged)"

ln -s "$SRC/claude/CLAUDE.md" "$H/.claude/stale.md"
audit_ro "$EVI/one.out" "$H"
expect_same "one owned-dir orphan: audit exits 1" 1 "$RC"
has_line "one owned-dir orphan: summary" "$EVI/one.out" \
    "symlink-audit: 0 of $N_ROWS entries NOT OK, 1 orphan link(s), 0 scan error(s)."

mkdir -p "$CO/dotfiles-b/bin" "$CO/dotfiles-b/claude/skills/present" \
    "$CO/dotfiles-b-old/bin" "$H/.local/bin" "$H/.config/oldtool" \
    "$H/.codex/skills/real-dir" "$FIX/elsewhere" "$FIX/private" "$FIX/real"
ln -s real "$FIX/alias"
touch "$CO/dotfiles-b/bin/present" "$CO/dotfiles-b-old/bin/tool" "$FIX/elsewhere/uv" \
    "$FIX/private/config" "$H/bin/real-script" "$H/.ssh/id_ed25519_work.pub" "$H/.ssh/config_local"
ln -s "$SRC/bin/retired-abs" "$H/bin/retired-abs"
ln -s ../co/dotfiles-b/bin/gone "$H/bin/retired-rel"
ln -s "$SRC/oldtool/conf" "$H/.config/oldtool/conf"
ln -s "$CO/dotfiles-gone/bin/old" "$H/.local/bin/old"
ln -s "$FIX/real/gone-a/bin/x" "$H/bin/alias-a"
ln -s "$FIX/alias/gone-b/bin/x" "$H/bin/alias-b"
ln -s bin "$CO/dotfiles-b/okdir"
ln -s "$CO/dotfiles-b/okdir/gone" "$H/bin/via-ok"
ln -s "$SRC/claude/skills/todos" "$H/.codex/skills/stale-abs"
ln -s ../../co/dotfiles-b/claude/skills/present "$H/.codex/skills/stale-rel"
ln -s "$SRC/bin/token-burn" "$H/bin/token-burn"
ln -s "$CO/dotfiles-b-old/bin/gone" "$H/bin/sib-gone"
ln -s "$CO/dotfiles-b-old/bin/tool" "$H/bin/sib-live"
ln -s "$FIX/elsewhere/uv" "$H/bin/foreign-live"
ln -s "$FIX/elsewhere/gone" "$H/bin/foreign-gone"
ln -s "$SRC" "$H/dotfiles-alias"
ln -s "$FIX/private/config" "$H/.ssh/config_private"
ln -s "$SRC/claude/skills/todos" "$FIX/foreign-alias"
ln -s "$FIX/foreign-alias" "$H/.codex/skills/custom"

audit_ro "$EVI/fixtures.out" "$H" --root "$CO/dotfiles-b" --root "$CO/dotfiles-gone" \
    --root "$FIX/alias/gone-a" --root "$FIX/real/gone-b"
expect_same "fixtures: audit exits 1" 1 "$RC"

EXPECT_ORPHANS="[X]  ORPHAN-DANGLING $H/.config/oldtool/conf -> $SRC/oldtool/conf (missing inside checkout $SRC)
[X]  ORPHAN-DANGLING $H/.local/bin/old -> $CO/dotfiles-gone/bin/old (missing inside checkout $CO/dotfiles-gone)
[X]  ORPHAN-DANGLING $H/bin/alias-a -> $FIX/real/gone-a/bin/x (missing inside checkout $FIX/alias/gone-a)
[X]  ORPHAN-DANGLING $H/bin/alias-b -> $FIX/alias/gone-b/bin/x (missing inside checkout $FIX/real/gone-b)
[X]  ORPHAN-DANGLING $H/bin/retired-abs -> $SRC/bin/retired-abs (missing inside checkout $SRC)
[X]  ORPHAN-DANGLING $H/bin/via-ok -> $CO/dotfiles-b/okdir/gone (missing inside checkout $CO/dotfiles-b)
[X]  ORPHAN-DANGLING $H/bin/retired-rel -> ../co/dotfiles-b/bin/gone (missing inside checkout $CO/dotfiles-b)
[X]  ORPHAN-LIVE     $H/.claude/stale.md -> $SRC/claude/CLAUDE.md (inside checkout $SRC; not in the installer map)
[X]  ORPHAN-LIVE     $H/.codex/skills/stale-abs -> $SRC/claude/skills/todos (inside checkout $SRC; not in the installer map)
[X]  ORPHAN-LIVE     $H/.codex/skills/stale-rel -> ../../co/dotfiles-b/claude/skills/present (inside checkout $CO/dotfiles-b; not in the installer map)"
expect_same "fixtures: exact orphan findings" \
    "$(printf '%s\n' "$EXPECT_ORPHANS" | LC_ALL=C sort)" \
    "$(grep '^\[X\]  ORPHAN-' "$EVI/fixtures.out" | LC_ALL=C sort)"
EXPECT_UNOWNED="[INFO] UNOWNED-LIVE  $H/bin/token-burn -> $SRC/bin/token-burn (inside checkout $SRC; shared dir, not judged)
[INFO] UNOWNED-LIVE  $H/custom-aliases -> $SRC/zsh/aliases.zsh (inside checkout $SRC; shared dir, not judged)"
expect_same "fixtures: exact UNOWNED-LIVE lines" \
    "$(printf '%s\n' "$EXPECT_UNOWNED" | LC_ALL=C sort)" \
    "$(grep '^\[INFO\] UNOWNED-LIVE' "$EVI/fixtures.out" | LC_ALL=C sort)"
has_line "fixtures: foreign, sibling, alias and foreign-chain links ignored" "$EVI/fixtures.out" \
    "[INFO] 7 symlink(s) outside dotfiles checkouts ignored"
has_line "fixtures: summary" "$EVI/fixtures.out" \
    "symlink-audit: 0 of $N_ROWS entries NOT OK, 10 orphan link(s), 0 scan error(s)."
for p in .gitconfig-personal .ssh/config_personal .ssh/config_work .ssh/id_ed25519_personal.pub; do
    has_line "identity link $p stays OK" "$EVI/fixtures.out" "[OK] OK            $H/$p"
done
has_line "identity file .gitconfig-work stays OK" "$EVI/fixtures.out" \
    "[OK] OK            $H/.gitconfig-work (machine-local file)"

audit_ro "$EVI/noroot.out" "$H" --root "$CO/dotfiles-b"
if grep -qF -- "$H/.local/bin/old" "$EVI/noroot.out"; then
    fail "deleted checkout without --root is not reported"
else
    pass "deleted checkout without --root is not reported"
fi

mkdir -p "$HC/bin"
ln -s "$SRC/bin/retired-abs" "$HC/bin/retired-abs"
ln -s "$SRC/claude/CLAUDE.md" "$HC/.claude/stale.md"
audit_ro "$EVI/cloud-orphans.out" "$HC" --cloud
expect_same "cloud orphan: audit exits 1" 1 "$RC"
has_line "cloud: owned-dir orphan reported" "$EVI/cloud-orphans.out" \
    "[X]  ORPHAN-LIVE     $HC/.claude/stale.md -> $SRC/claude/CLAUDE.md (inside checkout $SRC; not in the installer map)"
if grep -qF -- "$HC/bin/retired-abs" "$EVI/cloud-orphans.out"; then
    fail "cloud: ~/bin is outside the cloud scan"
else
    pass "cloud: ~/bin is outside the cloud scan"
fi

if grep -v '^[[:space:]]*#' "$AUDIT" | grep -qF '<<'; then
    fail "audit script uses no here-document (bash 3.2 backs them with temp files)"
else
    pass "audit script uses no here-document (bash 3.2 backs them with temp files)"
fi
if grep -v '^[[:space:]]*#' "$AUDIT" |
    grep -qE '(^|[;&|(`[:space:]])(rm|rmdir|unlink|ln|mv|cp|mkdir|touch|chmod|git)[[:space:]]'; then
    fail "audit script runs no writing command"
else
    pass "audit script runs no writing command"
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP  permission cases (root ignores mode bits)"
else
    mkdir -p "$H/.config/locked/inner"
    chmod 000 "$H/.config/locked"
    audit_ro "$EVI/locked.out" "$H"
    expect_same "unreadable scan subdir: audit exits 1" 1 "$RC"
    has_line "unreadable scan subdir: INCOMPLETE" "$EVI/locked.out" \
        "[X]  INCOMPLETE      $H/.config (find exited 1)"
    if grep -q 'no orphan links\.$' "$EVI/locked.out"; then
        fail "unreadable scan subdir: no clean summary"
    else
        pass "unreadable scan subdir: no clean summary"
    fi
    chmod 755 "$H/.config/locked"
    rm -rf "$H/.config/locked"

    chmod 000 "$H/.local"
    audit_ro "$EVI/local.out" "$H"
    expect_same "unreachable scan dir: audit exits 1" 1 "$RC"
    has_line "unreachable scan dir: INCOMPLETE" "$EVI/local.out" \
        "[X]  INCOMPLETE      $H/.local/bin (cannot confirm the scan dir is absent: $H/.local)"
    chmod 755 "$H/.local"

    mkdir -p "$CO/dotfiles-b/locked/sub"
    touch "$CO/dotfiles-b/locked/sub/tool"
    ln -s "$CO/dotfiles-b/locked/sub/tool" "$H/bin/hidden"
    ln -s "$CO/dotfiles-b/locked/sub/tool" "$CO/dotfiles-b/bin/chain"
    ln -s "$CO/dotfiles-b/bin/chain" "$H/bin/chain"
    ln -s locked/sub "$CO/dotfiles-b/linkdir"
    ln -s "$CO/dotfiles-b/linkdir/tool" "$H/bin/via-locked"
    ln -s "$CO/dotfiles-b/locked/../bin/present" "$H/bin/dotdot"
    chmod 000 "$CO/dotfiles-b/locked"
    audit_ro "$EVI/hidden.out" "$H" --root "$CO/dotfiles-b"
    expect_same "unreachable targets: audit exits 1" 1 "$RC"
    has_line "unsearchable target dir: INCOMPLETE" "$EVI/hidden.out" \
        "[X]  INCOMPLETE      $H/bin/hidden (cannot confirm the target is missing: $CO/dotfiles-b/locked)"
    has_line "leaf symlink into an unsearchable dir: INCOMPLETE" "$EVI/hidden.out" \
        "[X]  INCOMPLETE      $H/bin/chain (cannot confirm the target is missing: $CO/dotfiles-b/bin/chain)"
    has_line "dir symlink into an unsearchable dir: INCOMPLETE" "$EVI/hidden.out" \
        "[X]  INCOMPLETE      $H/bin/via-locked (cannot confirm the target is missing: $CO/dotfiles-b/linkdir)"
    has_line "'..' after an unsearchable dir: INCOMPLETE" "$EVI/hidden.out" \
        "[X]  INCOMPLETE      $H/bin/dotdot (cannot confirm the target is missing: $CO/dotfiles-b/locked)"
    if grep -qE -- "ORPHAN-DANGLING $H/bin/(hidden|chain|via-locked|dotdot) " "$EVI/hidden.out"; then
        fail "unreachable targets: none called missing"
    else
        pass "unreachable targets: none called missing"
    fi
    chmod 755 "$CO/dotfiles-b/locked"
    rm -f "$H/bin/hidden" "$H/bin/chain" "$H/bin/via-locked" "$H/bin/dotdot"
fi

KILL="$TMP/kill-bin"
mkdir -p "$KILL"
cat >"$KILL/find" <<'EOF'
#!/bin/sh
# Emits one candidate, then kills the enumeration subshell before its record.
printf '%s\0' "$HOME/.zshrc"
kill -9 "$PPID"
EOF
chmod +x "$KILL/find"
AUDIT_PATH="$KILL:$PATH"
audit_ro "$EVI/killed.out" "$H"
unset AUDIT_PATH
expect_same "killed enumeration: audit exits 1" 1 "$RC"
has_line "killed enumeration: INCOMPLETE" "$EVI/killed.out" \
    "[X]  INCOMPLETE      $H/bin (enumeration ended without a completion record)"

# A scan root itself relocated behind a symlink (e.g. ~/.ssh moved aside) must
# withhold the clean verdict, not silently skip with only an [INFO] line.
mv "$H/.ssh" "$H/.ssh.real"
ln -s .ssh.real "$H/.ssh"
audit_ro "$EVI/symlinked-scandir.out" "$H"
expect_same "symlinked scan dir: audit exits 1" 1 "$RC"
has_line "symlinked scan dir: INCOMPLETE" "$EVI/symlinked-scandir.out" \
    "[X]  INCOMPLETE      $H/.ssh (scan dir is a symlink, not followed)"
if grep -q 'no orphan links\.$' "$EVI/symlinked-scandir.out"; then
    fail "symlinked scan dir: no clean summary"
else
    pass "symlinked scan dir: no clean summary"
fi
rm -f "$H/.ssh"
mv "$H/.ssh.real" "$H/.ssh"

if [ "$RO_RUNS" -gt 0 ] && [ "$RO_BAD" -eq 0 ]; then
    pass "every audit run left fixtures/ unchanged ($RO_RUNS runs)"
else
    fail "every audit run left fixtures/ unchanged ($RO_BAD of $RO_RUNS changed or unreadable)"
fi
expect_same "real checkout unchanged by the suite" "$STATUS_BEFORE" "$(git -C "$REPO" --no-optional-locks status --porcelain)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
