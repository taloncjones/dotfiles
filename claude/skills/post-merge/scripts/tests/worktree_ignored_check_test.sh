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
        __pycache__/ /claude/contracts/ .DS_Store /.superpowers/ /.todos target/ .venv/ > "$ROOT/$1/m/.gitignore"
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
mkdir -p "$ROOT/c2/w/node_modules/x" "$ROOT/c2/w/pkg/__pycache__" "$ROOT/c2/w/claude/contracts" \
    "$ROOT/c2/w/docs/superpowers"
echo m > "$ROOT/c2/w/node_modules/x/i.js"
echo p > "$ROOT/c2/w/pkg/__pycache__/a.pyc"
echo c > "$ROOT/c2/w/claude/contracts/t-contract.json"
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
for b in keep drop miss; do
    git -C "$A/clone" worktree add -q "$A/wt-$b" -b "$b"
    git -C "$A/wt-$b" push -q -u origin "$b" 2>/dev/null
done
mkdir -p "$A/wt-keep/docs/superpowers/specs" "$A/wt-drop/node_modules/x"
echo spec > "$A/wt-keep/docs/superpowers/specs/s.md"
echo m > "$A/wt-drop/node_modules/x/i.js"
rm -rf "$A/wt-miss"
git -C "$A/clone" push -q origin --delete keep drop miss
out=$(cd "$A/clone" && HOME="$A/home" GIT_CONFIG_GLOBAL="$A/gitconfig" git worktree-prune 2>&1)
case "$out" in *"Skipping worktree: "*"/wt-keep "*) s=yes ;; *) s=no ;; esac
expect "alias prints skip line for spec worktree" "$s" yes
expect "alias keeps spec worktree" "$([ -d "$A/wt-keep" ] && echo kept || echo gone)" kept
expect "alias removes regenerable worktree" "$([ -d "$A/wt-drop" ] && echo kept || echo gone)" gone
case "$(git -C "$A/clone" worktree list --porcelain)" in *"/wt-miss"*) s=registered ;; *) s=pruned ;; esac
expect "alias prunes worktree whose directory is gone" "$s" pruned

# Build $ROOT/<name>/m (main with submodule "sub") and $ROOT/<name>/w (worktree, submodule initialized).
sub_fixture() {
    mkdir -p "$ROOT/$1"
    git init -q -b main "$ROOT/$1/s"
    printf '%s\n' /notes/ node_modules/ > "$ROOT/$1/s/.gitignore"
    git -C "$ROOT/$1/s" add .gitignore
    git -C "$ROOT/$1/s" commit -qm init
    git init -q -b main "$ROOT/$1/m"
    git -C "$ROOT/$1/m" -c protocol.file.allow=always submodule add -q "$ROOT/$1/s" sub
    git -C "$ROOT/$1/m" commit -qm sub
    git -C "$ROOT/$1/m" worktree add -q "$ROOT/$1/w" -b feat
}

# 12. Ignored file inside an initialized submodule
sub_fixture c12
git -C "$ROOT/c12/w" -c protocol.file.allow=always submodule update -q --init
mkdir -p "$ROOT/c12/w/sub/notes"
echo n > "$ROOT/c12/w/sub/notes/spec.md"
out=$("$CHECK" "$ROOT/c12/w" 2>/dev/null); rc=$?
expect "submodule ignored file: exit 1" "$rc" 1
expect "submodule ignored file: stdout" "$out" "sub/notes/spec.md"

# 13. Submodule with only regenerable ignored files
sub_fixture c13
git -C "$ROOT/c13/w" -c protocol.file.allow=always submodule update -q --init
mkdir -p "$ROOT/c13/w/sub/node_modules/x"
echo m > "$ROOT/c13/w/sub/node_modules/x/i.js"
out=$("$CHECK" "$ROOT/c13/w" 2>/dev/null); rc=$?
expect "submodule regenerable only: exit 0" "$rc" 0
expect "submodule regenerable only: stdout empty" "$out" ""

# 14. Uninitialized submodule: empty passes, content fails closed
sub_fixture c14
out=$("$CHECK" "$ROOT/c14/w" 2>/dev/null); rc=$?
expect "uninitialized empty submodule: exit 0" "$rc" 0
echo stray > "$ROOT/c14/w/sub/stray.txt"
out=$("$CHECK" "$ROOT/c14/w" 2>/dev/null); rc=$?
expect "uninitialized submodule with content: exit 2" "$rc" 2
expect "uninitialized submodule with content: stdout empty" "$out" ""

# 15. Unexpected errors exit 2, not 1
out=$(PATH=/nonexistent /usr/bin/python3 "$CHECK" "$ROOT/c1/w" 2>/dev/null); rc=$?
expect "missing git binary: exit 2" "$rc" 2
expect "missing git binary: stdout empty" "$out" ""

# 16. A differing main copy is labelled on stderr
err=$("$CHECK" "$ROOT/c4/w" 2>&1 >/dev/null)
case "$err" in *"differ from the main copy"*"docs/superpowers/specs/b.md"*) s=labelled ;; *) s=unlabelled ;; esac
expect "differing main copy: stderr label" "$s" labelled
err=$("$CHECK" "$ROOT/c1/w" 2>&1 >/dev/null)
case "$err" in *"differ from the main copy"*) s=labelled ;; *) s=plain ;; esac
expect "worktree-only file: no differing label" "$s" plain

# 17. Wiring: in every caller, the check line must gate what follows it
# (&& chain or if/then); a bare check line followed by a removal is the bug.
wiring_bad() {
    awk -v md="${1##*.}" '
        md == "md" && /^```/ { fence = !fence; next }
        md == "md" && !fence { next }
        /^[ \t]*#/ { next }
        /worktree_ignored_check/ && !/&&/ && !/then/ { print FILENAME ":" FNR ": " $0 }
    ' "$1"
}
bad=""
for f in claude/commands/done.md claude/commands/worktree.md claude/skills/post-merge/SKILL.md git/.gitconfig; do
    bad="$bad$(wiring_bad "$REPO/$f")"
done
expect "callers gate removal on the check" "$bad" ""
printf '```bash\n~/x/worktree_ignored_check.py "$P"\ngit worktree remove "$P"\n```\n' > "$ROOT/bad.md"
expect "wiring assertion catches a bare check line" "$([ -n "$(wiring_bad "$ROOT/bad.md")" ] && echo caught || echo missed)" caught

# 18. V1: cache names count only as the leading path segment, never under docs/
at_risk_case() {
    # $1 label, $2 fixture, $3 relative path to create in the worktree
    fixture "$2"
    mkdir -p "$ROOT/$2/w/$(dirname "$3")"
    echo x > "$ROOT/$2/w/$3"
    out=$("$CHECK" "$ROOT/$2/w" 2>/dev/null); rc=$?
    expect "$1: exit 1" "$rc" 1
    expect "$1: stdout" "$out" "$3"
}
at_risk_case "mid-path node_modules under docs" v1a docs/superpowers/node_modules/design.md
at_risk_case "mid-path .venv under docs" v1b docs/superpowers/specs/.venv/x.md
at_risk_case ".superpowers file" v1c .superpowers/plan.md
at_risk_case "mid-path node_modules outside docs" v1d notes/node_modules/design.md
at_risk_case "mid-path .venv outside docs" v1e tools/.venv/x.md

# 19. V2: a worktree path ending in a space is not confused with its sibling
fixture v2
git -C "$ROOT/v2/m" worktree add -q "$ROOT/v2/w " -b feat2
mkdir -p "$ROOT/v2/w /docs/superpowers"
echo spec > "$ROOT/v2/w /docs/superpowers/spec.md"
out=$("$CHECK" "$ROOT/v2/w " 2>/dev/null); rc=$?
expect "trailing-space worktree beside its sibling: exit 1" "$rc" 1
expect "trailing-space worktree beside its sibling: stdout" "$out" "docs/superpowers/spec.md"

# 20. V3: a submodule whose core.worktree names the main copy is read at its gitlink path
sub_fixture v3
git -C "$ROOT/v3/w" -c protocol.file.allow=always submodule update -q --init
mkdir -p "$ROOT/v3/w/sub/notes"
echo n > "$ROOT/v3/w/sub/notes/unique.md"
git config --file "$(git -C "$ROOT/v3/w/sub" rev-parse --absolute-git-dir)/config" core.worktree "$ROOT/v3/m/sub"
out=$("$CHECK" "$ROOT/v3/w" 2>/dev/null); rc=$?
expect "submodule core.worktree aimed at main copy: exit 1" "$rc" 1
expect "submodule core.worktree aimed at main copy: stdout" "$out" "sub/notes/unique.md"

# 21. Callers run the block that starts at "if [ ! -d" on a missing directory.
# macOS mktemp returns /var/..., git prints /private/var/...
CROOT=$(cd "$ROOT" && pwd -P)
for caller in "Step 3|claude/skills/post-merge/SKILL.md" "/done|claude/commands/done.md" "/worktree|claude/commands/worktree.md"; do
    label=${caller%%|*}
    src=${caller#*|}
    tag=$(basename "$src" .md | tr 'A-Z' 'a-z')
    fixture "pb-$tag"
    D="$CROOT/pb-$tag"
    mkdir -p "$D/home/.claude/skills"
    ln -s "$SKILL" "$D/home/.claude/skills/post-merge"
    awk '/^if \[ ! -d /{on=1} on{print} on&&/^fi$/{exit}' "$REPO/$src" > "$D/block.tmpl"

    run_block() {
        sed "s|<wt>|$1|g; s|<path>|$1|g; s|<skill dir>|$SKILL|g" "$D/block.tmpl" > "$D/block.sh"
        (cd "$D/m" && HOME="$D/home" WORKTREE_PATH="$1" sh "$D/block.sh" >/dev/null 2>&1)
    }

    git -C "$D/m" worktree add -q "$D/gone" -b gone
    rm -rf "$D/gone"
    if [ "$label" != "Step 3" ]; then
        git -C "$D/m" worktree add -q "$D/lk" -b lk
        git -C "$D/m" worktree lock "$D/lk"
        rm -rf "$D/lk"
    fi
    run_block "$D/gone"
    list=$(git -C "$D/m" worktree list --porcelain)
    case "$list" in *"worktree $D/gone"*) s=registered ;; *) s=pruned ;; esac
    expect "$label: missing directory prunes the registration" "$s" pruned
    if [ "$label" != "Step 3" ]; then
        case "$list" in *"worktree $D/lk"*) s=listed ;; *) s=dropped ;; esac
        expect "$label: locked missing registration is kept" "$s" listed
    fi

    mkdir -p "$D/w/docs/superpowers"
    echo spec > "$D/w/docs/superpowers/spec.md"
    run_block "$D/w"
    expect "$label: at-risk worktree is kept" "$([ -f "$D/w/docs/superpowers/spec.md" ] && echo kept || echo gone)" kept
done

# 22. Summary line on stderr names the count and the worktree
err=$("$CHECK" "$ROOT/c1/w" 2>&1 >/dev/null)
expect "summary line on stderr names count and worktree" "$err" \
    "worktree_ignored_check: 1 ignored path(s) exist only in, or differ from, the main checkout: $ROOT/c1/w"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
