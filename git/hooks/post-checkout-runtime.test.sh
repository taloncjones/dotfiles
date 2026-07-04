#!/bin/sh
# post-checkout-runtime.test.sh -- RUNTIME tests for the post-checkout
# worktree-hydration hook. The sibling post-checkout.test.sh greps the hook
# source (static shape); this suite runs the real hook -- both via a real
# `git worktree add` with core.hooksPath pointed at this repo's git/hooks,
# and directly for re-invocation flows -- against throwaway repos, and
# asserts the on-disk symlink/copy partition it promises.

set -u

REPO="$(pwd)"
HOOK_DIR="$REPO/git/hooks"
if [ ! -f "$HOOK_DIR/post-checkout" ]; then
    echo "FAIL: $HOOK_DIR/post-checkout not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/post-checkout-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Canonicalize TMP so its path matches what the hook writes into symlink
# targets. On macOS $TMPDIR lives under /var, a symlink to /private/var; the
# hook resolves main to its real path, so an unresolved $TMP would mismatch
# every readlink comparison below. pwd -P is a no-op where /tmp is already
# canonical (Linux/CI).
TMP="$(cd "$TMP" && pwd -P)"

MAIN="$TMP/main"
WT="$TMP/wt"

git init -q "$MAIN"
git -C "$MAIN" config user.email test@example.invalid
git -C "$MAIN" config user.name "Test"
printf 'x\n' >"$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -qm init

# GSD-shaped untracked state in main: the symlink-vs-copy partition inputs.
mkdir -p "$MAIN/.todos/pending" \
         "$MAIN/.planning/codebase" "$MAIN/.planning/quick" "$MAIN/.planning/todos"
printf 'todo\n' >"$MAIN/.todos/pending/one.md"
printf 'roadmap\n' >"$MAIN/.planning/ROADMAP.md"
printf 'index\n' >"$MAIN/.planning/TODO.md"
printf 'state\n' >"$MAIN/.planning/STATE.md"
printf '{"mode": "maintenance"}\n' >"$MAIN/.planning/config.json"

# Route this repo's hooks into the fixture repo, then trigger the real thing.
git -C "$MAIN" config core.hooksPath "$HOOK_DIR"
git -C "$MAIN" worktree add -q "$WT" -b hydrate-test >"$TMP/out" 2>&1

# 1. Maintenance partition: project-wide entries are symlinks to main.
for rel in codebase quick todos ROADMAP.md TODO.md; do
    if [ -L "$WT/.planning/$rel" ] \
        && [ "$(readlink "$WT/.planning/$rel")" = "$MAIN/.planning/$rel" ]; then
        pass ".planning/$rel is a symlink to main"
    else
        fail ".planning/$rel is a symlink to main"
    fi
done

# 2. Per-worktree state is a COPY, never a symlink.
for rel in STATE.md config.json; do
    if [ -f "$WT/.planning/$rel" ] && [ ! -L "$WT/.planning/$rel" ]; then
        pass ".planning/$rel is a per-worktree copy"
    else
        fail ".planning/$rel is a per-worktree copy"
    fi
done

# 3. .todos/ is hydrated as a whole-directory symlink to main.
if [ -L "$WT/.todos" ] && [ "$(readlink "$WT/.todos")" = "$MAIN/.todos" ]; then
    pass ".todos symlinks to main"
else
    fail ".todos symlinks to main"
fi

# 4. Copies do not clobber on re-run: diverge STATE.md, re-invoke the hook.
printf 'diverged\n' >"$WT/.planning/STATE.md"
(cd "$WT" && "$HOOK_DIR/post-checkout" 0 0 1) >"$TMP/out" 2>&1
if [ "$(cat "$WT/.planning/STATE.md")" = "diverged" ]; then
    pass "re-run never clobbers diverged STATE.md"
else
    fail "re-run never clobbers diverged STATE.md"
fi

# 5. Wrong-shape .todos: warn by default, repair only under GSD_HOOK_REPAIR=1.
rm "$WT/.todos"
mkdir "$WT/.todos"
(cd "$WT" && "$HOOK_DIR/post-checkout" 0 0 1) >"$TMP/out" 2>&1
if grep -q "WARN: .todos has wrong shape" "$TMP/out" && [ -d "$WT/.todos" ] && [ ! -L "$WT/.todos" ]; then
    pass "wrong-shape .todos warns without touching it"
else
    fail "wrong-shape .todos warns without touching it"
fi
(cd "$WT" && GSD_HOOK_REPAIR=1 "$HOOK_DIR/post-checkout" 0 0 1) >"$TMP/out" 2>&1
if [ -L "$WT/.todos" ] && [ "$(readlink "$WT/.todos")" = "$MAIN/.todos" ]; then
    pass "GSD_HOOK_REPAIR=1 restores the .todos symlink"
else
    fail "GSD_HOOK_REPAIR=1 restores the .todos symlink"
fi

# 6. Workspace mode: hard skip plus symlink leak warning; GSD_HOOK_ISOLATE=1
#    converts leftover maintenance symlinks into per-worktree copies.
printf '{"mode": "workspace"}\n' >"$WT/.planning/config.json"
(cd "$WT" && "$HOOK_DIR/post-checkout" 0 0 1) >"$TMP/out" 2>&1
if grep -q "workspace mode detected" "$TMP/out" && grep -q "writes will leak to main" "$TMP/out"; then
    pass "workspace mode skips hydration and warns on leaky symlinks"
else
    fail "workspace mode skips hydration and warns on leaky symlinks"
fi
(cd "$WT" && GSD_HOOK_ISOLATE=1 "$HOOK_DIR/post-checkout" 0 0 1) >"$TMP/out" 2>&1
if [ -d "$WT/.planning/codebase" ] && [ ! -L "$WT/.planning/codebase" ] \
    && [ -f "$WT/.planning/ROADMAP.md" ] && [ ! -L "$WT/.planning/ROADMAP.md" ]; then
    pass "GSD_HOOK_ISOLATE=1 converts symlinks to copies"
else
    fail "GSD_HOOK_ISOLATE=1 converts symlinks to copies"
fi
if [ ! -L "$WT/.todos" ] && [ -d "$WT/.todos" ]; then
    pass "workspace isolation covers top-level .todos"
else
    fail "workspace isolation covers top-level .todos"
fi

# 7. Non-branch checkout ($3=0) is a hard no-op.
(cd "$WT" && "$HOOK_DIR/post-checkout" 0 0 0) >"$TMP/out" 2>&1
if [ ! -s "$TMP/out" ]; then
    pass "file checkout invocation is silent no-op"
else
    fail "file checkout invocation is silent no-op"
fi

# 8. Post-GSD repo (no .planning in main): .todos still hydrates, .planning
#    is never created.
MAIN2="$TMP/main2"
WT2="$TMP/wt2"
git init -q "$MAIN2"
git -C "$MAIN2" config user.email test@example.invalid
git -C "$MAIN2" config user.name "Test"
printf 'y\n' >"$MAIN2/f.txt"
git -C "$MAIN2" add f.txt
git -C "$MAIN2" commit -qm init
mkdir -p "$MAIN2/.todos/pending"
printf 'todo\n' >"$MAIN2/.todos/pending/one.md"
git -C "$MAIN2" config core.hooksPath "$HOOK_DIR"
git -C "$MAIN2" worktree add -q "$WT2" -b hydrate-test2 >"$TMP/out" 2>&1
if [ -L "$WT2/.todos" ] && [ "$(readlink "$WT2/.todos")" = "$MAIN2/.todos" ]; then
    pass "post-GSD repo still hydrates .todos"
else
    fail "post-GSD repo still hydrates .todos"
fi
if [ ! -e "$WT2/.planning" ]; then
    pass "post-GSD repo gets no .planning"
else
    fail "post-GSD repo gets no .planning"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
