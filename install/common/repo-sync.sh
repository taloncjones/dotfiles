#!/usr/bin/env bash
# repo-sync.sh - guarded fetch + fast-forward for a dotfiles checkout.
#
# Deterministic, config-independent sync: classify first (read-only), then
# fast-forward or do nothing. Never stashes, merges, rebases, resets, or
# force-pushes. Callers treat exit 30 as "stop: checkout state uncertain";
# every other non-zero means "sync skipped: continue from current checkout".
#
# Exit codes:
#    0 synced (fast-forwarded or already up to date)
#    2 usage error
#   20 not a git work tree          21 detached HEAD
#   22 wrong branch (--require-branch)  23 no upstream configured
#   24 fetch failed (offline/auth)  25 local ahead of upstream
#   26 diverged                     27 dirty tree (tracked/staged changes)
#   28 fast-forward refused, post-state VERIFIED intact
#   29 pre-merge inspection error (fail closed, merge never attempted)
#   30 state uncertain after a merge attempt (caller must stop)
set -u

usage() { echo "[X] usage: repo-sync.sh [--require-branch <name>] [<repo-dir>]" >&2; }

require_branch=""
repo=""
while [ $# -gt 0 ]; do
    case "$1" in
        --require-branch)
            [ $# -ge 2 ] || { usage; exit 2; }
            require_branch="$2"; shift 2 ;;
        --*) usage; exit 2 ;;
        *)
            [ -z "$repo" ] || { usage; exit 2; }
            repo="$1"; shift ;;
    esac
done

if [ -z "$repo" ]; then
    script_dir="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    repo="$( cd -P "$script_dir/../.." >/dev/null 2>&1 && pwd )"
fi

# Pre-merge inspection failures fail closed: expected "absent" probe codes
# are distinguished from probe errors (a symbolic-ref that dies with 128 is
# NOT a detached HEAD).
inspect_fail() { echo "[X] could not inspect repository state; not syncing"; exit 29; }

if [ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
    echo "[X] not a git work tree: $repo"
    exit 20
fi

branch="$(git -C "$repo" symbolic-ref -q --short HEAD)"; sr=$?
if [ "$sr" -eq 1 ]; then
    echo "[WARNING] detached HEAD; skipping sync"
    exit 21
elif [ "$sr" -ne 0 ]; then
    inspect_fail
fi

if [ -n "$require_branch" ] && [ "$branch" != "$require_branch" ]; then
    echo "[WARNING] on $branch, not $require_branch; skipping sync"
    exit 22
fi

# The branch's CONFIGURED remote, not a name parsed out of @{upstream}
# (that parse breaks for remote names containing "/" and for local "."
# upstreams). config exits 1 when the key is unset = no upstream.
remote="$(git -C "$repo" config "branch.$branch.remote")"; cr=$?
if [ "$cr" -eq 1 ]; then
    echo "[WARNING] no upstream configured for $branch; skipping sync"
    exit 23
elif [ "$cr" -ne 0 ]; then
    inspect_fail
fi

# A "." remote is a local upstream branch: nothing to fetch.
if [ "$remote" != "." ]; then
    if ! git -C "$repo" fetch --quiet "$remote"; then
        echo "[WARNING] fetch failed (offline or auth?); continuing from current checkout"
        exit 24
    fi
fi

# Single resolution point: classification and merge use these exact shas,
# so a concurrent ref move cannot make them target different commits.
head_commit="$(git -C "$repo" rev-parse HEAD)" || inspect_fail
upstream_commit="$(git -C "$repo" rev-parse '@{upstream}')" || inspect_fail
counts="$(git -C "$repo" rev-list --left-right --count "$head_commit...$upstream_commit")" || inspect_fail
set -- $counts
ahead="${1:-}"; behind="${2:-}"
case "$ahead$behind" in *[!0-9]*|"") inspect_fail ;; esac

if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    echo "[OK] already up to date"
    exit 0
fi
if [ "$behind" -eq 0 ]; then
    echo "[INFO] local branch is ahead of upstream by $ahead commit(s); nothing to pull"
    exit 25
fi
if [ "$ahead" -gt 0 ]; then
    echo "[WARNING] local and upstream have diverged ($ahead ahead, $behind behind); not merging"
    exit 26
fi

# behind > 0, ahead == 0: candidate for fast-forward. Dirty tracked/staged
# state skips it (diff exit 1 = changes; anything above 1 = inspection error).
git -C "$repo" diff --quiet; ds=$?
if [ "$ds" -eq 1 ]; then
    echo "[WARNING] local changes present; skipping fast-forward"
    exit 27
elif [ "$ds" -gt 1 ]; then
    inspect_fail
fi
git -C "$repo" diff --cached --quiet; ds=$?
if [ "$ds" -eq 1 ]; then
    echo "[WARNING] local changes present; skipping fast-forward"
    exit 27
elif [ "$ds" -gt 1 ]; then
    inspect_fail
fi

pre_status="$(git -C "$repo" status --porcelain)" || inspect_fail

# Untracked-content digest: status equality alone cannot see a content
# change inside a file that stays "??". Ignored files are deliberately
# outside this contract (unbounded set; protected by --no-overwrite-ignore
# refusing before mutation).
#
# NUL-delimited listing (git -z) avoids core.quotePath mangling non-ASCII
# names; a temp file (not a pipe) preserves the git command's exit status
# and lets the loop set variables in the current shell. Entries are
# characterized without dereferencing, so untracked symlinks (dangling,
# retargeted, or pointing at directories) are inspected safely instead of
# failing or aliasing on hash-object's dereferenced content. hash-object
# uses --no-filters so a raw-content mutation (e.g. line-ending rewrite
# under core.autocrlf=true) cannot hash identically to the original.
untracked_digest() {
    local f h out="" tmp rc
    tmp="$(mktemp)" || return 1
    git -C "$repo" ls-files --others --exclude-standard -z >"$tmp"; rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        return 1
    fi
    while IFS= read -r -d '' f; do
        [ -n "$f" ] || continue
        if [ -L "$repo/$f" ]; then
            h="link:$(readlink -- "$repo/$f")" || { rm -f "$tmp"; return 1; }
        elif [ -f "$repo/$f" ]; then
            h="$(git -C "$repo" hash-object --no-filters -- "$f")" || { rm -f "$tmp"; return 1; }
        else
            h="special"
        fi
        out="$out$f:$h"$'\n'
    done <"$tmp"
    rm -f "$tmp"
    printf '%s' "$out"
}
pre_untracked="$(untracked_digest)" || inspect_fail

# Guarded merge: ff-only pinned to the resolved sha; autoStash forced off,
# per-branch mergeoptions neutralized, ignored files never overwritten.
# From here on, any verification problem is exit 30 (never 28 or 29): an
# inspection error after mutation was possible cannot be called safe.
uncertain() {
    echo "[X] sync left the checkout in an uncertain state; inspect before continuing"
    exit 30
}
if git -C "$repo" -c merge.autoStash=false -c "branch.$branch.mergeoptions=" \
        merge --ff-only --no-overwrite-ignore "$upstream_commit"; then
    new_head="$(git -C "$repo" rev-parse HEAD)" || uncertain
    [ "$new_head" = "$upstream_commit" ] || uncertain
    echo "[OK] fast-forwarded $head_commit..$new_head"
    exit 0
else
    post_head="$(git -C "$repo" rev-parse HEAD)" || uncertain
    [ "$post_head" = "$head_commit" ] || uncertain
    # MERGE_HEAD probe: exit 1 is CONFIRMED absence; 0 means a merge is in
    # progress and anything else is a probe error -- both are uncertain.
    git -C "$repo" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; mh=$?
    [ "$mh" -eq 1 ] || uncertain
    post_status="$(git -C "$repo" status --porcelain)" || uncertain
    [ "$post_status" = "$pre_status" ] || uncertain
    post_untracked="$(untracked_digest)" || uncertain
    [ "$post_untracked" = "$pre_untracked" ] || uncertain
    echo "[WARNING] fast-forward refused (untracked or ignored files in the way?); working tree verified unchanged"
    exit 28
fi
