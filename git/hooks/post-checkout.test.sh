#!/bin/sh
# post-checkout.test.sh — static assertions over the hook source.
# Each `assert` greps the hook file for a fact about its structure or
# documentation. Exits non-zero on first failure.
#
# Run manually:  sh git/hooks/post-checkout.test.sh
# Add an assertion:  call assert with a label and a grep-style pattern.

set -e

HOOK=git/hooks/post-checkout

if [ ! -f "$HOOK" ]; then
    echo "FAIL: $HOOK not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0

assert() {
    label="$1"
    shift
    if "$@" "$HOOK" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

# --- baseline (PR #12) assertions ---
assert "shebang is /bin/sh"                  grep -q '^#!/bin/sh$'
assert "header documents partition table"    grep -q 'symlink-vs-copy partition'
assert "header documents GSD_HOOK_REPAIR=1"  grep -q 'GSD_HOOK_REPAIR=1'
assert "header documents canonical-main"     grep -q 'canonical main'
assert "branch-checkout guard present"       grep -q '\[ "\$3" = "1" \] || exit 0'
assert "linked-worktree guard present"       grep -q '\[ -f \.git \] || exit 0'
assert "main_wt resolved via porcelain"      grep -q 'git worktree list --porcelain'
assert "exits when main lacks .planning"     grep -q 'if \[ ! -d "\$main_wt/\.planning" \]; then'
assert "mkdir -p .planning"                  grep -q 'mkdir -p \.planning'
assert "defines ensure_symlink"              grep -q '^ensure_symlink() {'
assert "defines ensure_copy"                 grep -q '^ensure_copy() {'
assert "ensure_symlink uses ln -sfn"         grep -q 'ln -sfn "\$src" "\$dst"'
assert "ensure_symlink REPAIR gate"          grep -q 'GSD_HOOK_REPAIR:-0'
assert "ensure_copy never clobbers"          grep -E -q '\[ -e "\$dst" \] \|\| \[ -L "\$dst" \]'
assert "5 ensure_symlink call sites"         awk '/^ensure_symlink [^(]/{n++} END{exit !(n==5)}'
assert "2 ensure_copy call sites"            awk '/^ensure_copy [^(]/{n++} END{exit !(n==2)}'


# --- mode detection (Section 1) ---
assert "gsd_mode initial assignment"         grep -q '^gsd_mode=maintenance'
assert "config.json branch uses tr strip"    grep -E -q "tr -d '\[:space:\]' < \.planning/config\.json"
assert "config detection matches workspace"  grep -q '"mode":"workspace"'
assert "fallback rejects phases symlink"     grep -E -q '\[ -d \.planning/phases \] && \[ ! -L \.planning/phases \]'
assert "fallback rejects PROJECT.md symlink" grep -E -q '\[ -f \.planning/PROJECT\.md \] && \[ ! -L \.planning/PROJECT\.md \]'


# --- .todos/ hydration (post-GSD) ---
assert "header documents .todos hydration"   grep -q 'post-GSD \.todos/ hydration'
assert ".todos guard maintenance + exists"   grep -q '\[ "\$gsd_mode" = maintenance \] && \[ -d "\$main_wt/\.todos" \]'
assert ".todos symlinks whole dir to main"   grep -q 'ln -sfn "\$todos_src" \.todos'
assert ".todos honors GSD_HOOK_REPAIR"        grep -q 'rm -rf \.todos'
assert ".todos runs before .planning exit"   awk '/post-GSD \.todos\/ hydration/{t=NR} /if \[ ! -d "\$main_wt\/\.planning" \]/{p=NR} END{exit !(t && p && t < p)}'


# --- dispatch (Section 2) ---
assert "workspace branch present"            grep -q 'if \[ "\$gsd_mode" = workspace \]; then'
assert "workspace WARN string"               grep -q 'writes will leak to main'
assert "workspace GSD_HOOK_ISOLATE present"  grep -q 'GSD_HOOK_ISOLATE:-0'
assert "workspace isolated notice"           grep -q 'isolated \.planning/'
assert "workspace dangling-source guard"     grep -q 'cannot be isolated'
assert "workspace isolates top-level .todos"  grep -q 'isolated \.todos (was symlink, now copy)'

# --- docstring (Section 5) ---
assert "header documents GSD_HOOK_ISOLATE=1" grep -q 'GSD_HOOK_ISOLATE=1'
assert "header documents mode detection"     grep -q 'mode detection'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
