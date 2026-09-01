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
