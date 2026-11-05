#!/bin/sh
# worktree_ignored_check_test.sh - fixture tests for worktree_ignored_check.py
# and the worktree-prune alias. Local repos only; no network, no real ~/.gitconfig.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SKILL=$(cd "$HERE/../.." && pwd)
REPO=$(cd "$SKILL/../../.." && pwd)
CHECK="$SKILL/scripts/worktree_ignored_check.py"

PASS=0
FAIL=0
ROOT=$(mktemp -d)
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[core]\n\thooksPath = /dev/null\n\texcludesfile = /dev/null\n' > "$GIT_CONFIG_GLOBAL"

# Compare an actual value with an expected one.
expect() {
    if [ "$2" = "$3" ]; then
        printf 'PASS  %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n    want: %s\n    got:  %s\n' "$1" "$3" "$2" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Build $ROOT/<name>/m (main checkout) and $ROOT/<name>/w (linked worktree).
fixture() {
    mkdir -p "$ROOT/$1"
    git init -q -b main "$ROOT/$1/m"
    printf '%s\n' /docs/superpowers/ /docs/plans/ /.worktrees/ /locked/ node_modules/ \
        __pycache__/ /claude/contracts/ .DS_Store /.superpowers/ /.todos target/ > "$ROOT/$1/m/.gitignore"
    git -C "$ROOT/$1/m" add .gitignore
    git -C "$ROOT/$1/m" commit -qm init
    git -C "$ROOT/$1/m" worktree add -q "$ROOT/$1/w" -b feat
}

# 1. Ignored spec only in the worktree
fixture c1
mkdir -p "$ROOT/c1/w/docs/superpowers/specs"
echo spec > "$ROOT/c1/w/docs/superpowers/specs/a.md"
out=$("$CHECK" "$ROOT/c1/w" 2>/dev/null); rc=$?
expect "spec only in worktree: exit 1" "$rc" 1
expect "spec only in worktree: stdout" "$out" "docs/superpowers/specs/a.md"

# 2. Only regenerable files
fixture c2
mkdir -p "$ROOT/c2/w/sub/node_modules/x" "$ROOT/c2/w/pkg/__pycache__" "$ROOT/c2/w/claude/contracts" \
    "$ROOT/c2/w/.superpowers/sdd" "$ROOT/c2/w/docs/superpowers"
echo m > "$ROOT/c2/w/sub/node_modules/x/i.js"
echo p > "$ROOT/c2/w/pkg/__pycache__/a.pyc"
echo c > "$ROOT/c2/w/claude/contracts/t-contract.json"
echo s > "$ROOT/c2/w/.superpowers/sdd/n.md"
touch "$ROOT/c2/w/.DS_Store"
ln -s "$ROOT/c2/m" "$ROOT/c2/w/.todos"
ln -s /etc "$ROOT/c2/w/docs/superpowers/link"
out=$("$CHECK" "$ROOT/c2/w" 2>/dev/null); rc=$?
expect "regenerable only: exit 0" "$rc" 0
expect "regenerable only: stdout empty" "$out" ""

# 3. Identical main copy
fixture c3
mkdir -p "$ROOT/c3/w/docs/superpowers/specs" "$ROOT/c3/m/docs/superpowers/specs"
echo same > "$ROOT/c3/w/docs/superpowers/specs/a.md"
echo same > "$ROOT/c3/m/docs/superpowers/specs/a.md"
out=$("$CHECK" "$ROOT/c3/w" 2>/dev/null); rc=$?
expect "identical main copy: exit 0" "$rc" 0
expect "identical main copy: stdout empty" "$out" ""

# 4. Differing main copy
fixture c4
mkdir -p "$ROOT/c4/w/docs/superpowers/specs" "$ROOT/c4/m/docs/superpowers/specs"
echo new > "$ROOT/c4/w/docs/superpowers/specs/b.md"
echo old > "$ROOT/c4/m/docs/superpowers/specs/b.md"
out=$("$CHECK" "$ROOT/c4/w" 2>/dev/null); rc=$?
expect "differing main copy: exit 1" "$rc" 1
expect "differing main copy: stdout" "$out" "docs/superpowers/specs/b.md"

# 5. Main path resolves through a symlink into the worktree
fixture c5
mkdir -p "$ROOT/c5/w/docs/plans" "$ROOT/c5/m/docs"
echo plan > "$ROOT/c5/w/docs/plans/p.md"
ln -s "$ROOT/c5/w/docs/plans" "$ROOT/c5/m/docs/plans"
out=$("$CHECK" "$ROOT/c5/w" 2>/dev/null); rc=$?
expect "main symlink into worktree: exit 1" "$rc" 1
expect "main symlink into worktree: stdout" "$out" "docs/plans/p.md"

# 6. Nested repository inside an ignored directory
fixture c6
mkdir -p "$ROOT/c6/w/.worktrees"
git init -q "$ROOT/c6/w/.worktrees/nested"
echo n > "$ROOT/c6/w/.worktrees/nested/f.txt"
out=$("$CHECK" "$ROOT/c6/w" 2>/dev/null); rc=$?
expect "nested repository: exit 1" "$rc" 1
expect "nested repository: stdout" "$out" ".worktrees/nested/"

# 7. Unreadable directory inside an ignored directory
fixture c7
if [ "$(id -u)" -eq 0 ]; then
    printf 'SKIP  unreadable directory (running as root)\n'
else
    mkdir -p "$ROOT/c7/w/locked/inner"
    echo x > "$ROOT/c7/w/locked/inner/f"
    chmod 000 "$ROOT/c7/w/locked/inner"
    out=$("$CHECK" "$ROOT/c7/w" 2>/dev/null); rc=$?
    chmod 755 "$ROOT/c7/w/locked/inner"
    expect "unreadable directory: exit 2" "$rc" 2
    expect "unreadable directory: stdout empty" "$out" ""
fi

# 8. Cargo target/ beside Cargo.toml
fixture c8
mkdir -p "$ROOT/c8/w/crate/target/debug"
echo '[package]' > "$ROOT/c8/w/crate/Cargo.toml"
echo b > "$ROOT/c8/w/crate/target/debug/bin"
out=$("$CHECK" "$ROOT/c8/w" 2>/dev/null); rc=$?
expect "cargo target: exit 0" "$rc" 0

# 9. target/ without Cargo.toml
fixture c9
mkdir -p "$ROOT/c9/w/tool/target"
echo b > "$ROOT/c9/w/tool/target/out"
out=$("$CHECK" "$ROOT/c9/w" 2>/dev/null); rc=$?
expect "target without Cargo.toml: exit 1" "$rc" 1
expect "target without Cargo.toml: stdout" "$out" "tool/target/out"

# 10. Not a linked worktree
fixture c10
mkdir "$ROOT/c10/plain"
"$CHECK" "$ROOT/c10/m" >/dev/null 2>&1; rc=$?
expect "main worktree: exit 2" "$rc" 2
"$CHECK" "$ROOT/c10/plain" >/dev/null 2>&1; rc=$?
expect "plain directory: exit 2" "$rc" 2
"$CHECK" "$ROOT/c10/missing" >/dev/null 2>&1; rc=$?
expect "missing path: exit 2" "$rc" 2

# 11. worktree-prune alias keeps the spec worktree, removes the regenerable one
A="$ROOT/c11"
mkdir -p "$A/home/.claude/skills"
ln -s "$SKILL" "$A/home/.claude/skills/post-merge"
printf '[include]\n\tpath = %s/git/.gitconfig\n[commit]\n\tgpgsign = false\n[core]\n\thooksPath = /dev/null\n\texcludesfile = /dev/null\n' "$REPO" > "$A/gitconfig"
git init -q --bare -b main "$A/origin.git"
git clone -q "$A/origin.git" "$A/clone" 2>/dev/null
printf '%s\n' /docs/superpowers/ node_modules/ > "$A/clone/.gitignore"
git -C "$A/clone" add .gitignore
git -C "$A/clone" commit -qm init
git -C "$A/clone" push -q origin main
for b in keep drop; do
    git -C "$A/clone" worktree add -q "$A/wt-$b" -b "$b"
    git -C "$A/wt-$b" push -q -u origin "$b" 2>/dev/null
done
mkdir -p "$A/wt-keep/docs/superpowers/specs" "$A/wt-drop/node_modules/x"
echo spec > "$A/wt-keep/docs/superpowers/specs/s.md"
echo m > "$A/wt-drop/node_modules/x/i.js"
git -C "$A/clone" push -q origin --delete keep drop
out=$(cd "$A/clone" && HOME="$A/home" GIT_CONFIG_GLOBAL="$A/gitconfig" git worktree-prune 2>&1)
case "$out" in *"Skipping worktree: "*"/wt-keep "*) s=yes ;; *) s=no ;; esac
expect "alias prints skip line for spec worktree" "$s" yes
expect "alias keeps spec worktree" "$([ -d "$A/wt-keep" ] && echo kept || echo gone)" kept
expect "alias removes regenerable worktree" "$([ -d "$A/wt-drop" ] && echo kept || echo gone)" gone

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
