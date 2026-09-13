#!/bin/sh
# repo-sync.test.sh -- behavioral tests for install/common/repo-sync.sh:
# the shared guarded fetch + fast-forward helper behind `update` and
# bin/dotfiles-repair. Hermetic: disposable git fixtures under mktemp,
# env -i with a stub PATH and a pinned GIT_CONFIG_GLOBAL, path remotes
# only (no network). Every case asserts exit code, output marker, HEAD,
# and preservation of index/working files where relevant.
set -u

SYNC=install/common/repo-sync.sh
REPAIR=bin/dotfiles-repair
[ -f "$SYNC" ] || { echo "FAIL: $SYNC not found (run from repo root)" >&2; exit 2; }

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/repo-sync-test.XXXXXX")" \
    || { echo "FAIL: cannot create temp dir" >&2; exit 2; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: bad temp dir" >&2; exit 2; }
TMP="$(cd "$TMP" && pwd)" || { echo "FAIL: cannot resolve temp dir" >&2; exit 2; }
case "$TMP" in /*) ;; *) echo "FAIL: temp dir not absolute" >&2; exit 2 ;; esac
trap 'rm -rf "$TMP"' EXIT
REPO="$(pwd)"

# Stub PATH: only the tools the helper and fixtures need.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
for tool in bash sh git mkdir rm ln mv cp cat grep sed awk dirname basename \
        chmod touch printf env ls mktemp readlink; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -s "$p" "$STUB_BIN/$tool" 2>/dev/null
done
REAL_GIT="$(command -v git)"

# Hermetic git config: identity, no signing, fixed default branch. The
# global config file is pinned so nothing from the developer machine leaks.
GITCFG="$TMP/gitconfig"
cat >"$GITCFG" <<EOF
[user]
	name = Fixture
	email = fixture@example.invalid
[commit]
	gpgsign = false
[tag]
	gpgsign = false
[init]
	defaultBranch = main
EOF

# hrun <path> <cmd...>: run under env -i; output in $TMP/out, exit in $RC.
hrun() {
    hpath="$1"; shift
    env -i HOME="$TMP/home" PATH="$hpath" TMPDIR="$TMP" \
        GIT_CONFIG_GLOBAL="$GITCFG" GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        "$@" >"$TMP/out" 2>&1
    RC=$?
}
mkdir -p "$TMP/home"

git_fix() { hrun "$STUB_BIN" git "$@"; }
run_sync() { hrun "$STUB_BIN" bash "$REPO/$SYNC" "$@"; }

head_of() { env -i PATH="$STUB_BIN" GIT_CONFIG_GLOBAL="$GITCFG" GIT_CONFIG_NOSYSTEM=1 git -C "$1" rev-parse "${2:-HEAD}" 2>/dev/null; }

# new_fixture <name>: origin bare repo + clone with one commit on main.
# Layout: $TMP/<name>/origin.git, $TMP/<name>/clone, $TMP/<name>/work
# (work is a second clone used to advance origin).
new_fixture() {
    fx="$TMP/$1"
    mkdir -p "$fx"
    git_fix init -q -b main "$fx/seed"
    printf 'base v1\n' >"$fx/seed/base.txt"
    printf 'secret.conf\n' >"$fx/seed/.gitignore"
    git_fix -C "$fx/seed" add base.txt .gitignore
    git_fix -C "$fx/seed" commit -q -m c1
    git_fix clone -q --bare "$fx/seed" "$fx/origin.git"
    git_fix clone -q "$fx/origin.git" "$fx/clone"
    git_fix clone -q "$fx/origin.git" "$fx/work"
}

# advance_origin <name> [<file> <content> [forceadd]]: push one commit.
advance_origin() {
    fx="$TMP/$1"; f="${2:-base.txt}"; c="${3:-base v2}"
    printf '%s\n' "$c" >"$fx/work/$f"
    if [ "${4:-}" = forceadd ]; then
        git_fix -C "$fx/work" add -f "$f"
    else
        git_fix -C "$fx/work" add "$f"
    fi
    git_fix -C "$fx/work" commit -q -m advance
    git_fix -C "$fx/work" push -q origin main
}

# --- 1. clean fast-forward ---
new_fixture ff
advance_origin ff
tip="$(head_of "$TMP/ff/work")"
run_sync "$TMP/ff/clone"
if [ "$RC" -eq 0 ] && grep -q '\[OK\] fast-forwarded' "$TMP/out" \
    && [ "$(head_of "$TMP/ff/clone")" = "$tip" ]; then
    pass "clean fast-forward reaches fetched commit"
else
    fail "clean fast-forward reaches fetched commit (rc=$RC)"
fi

# --- 2. already current ---
new_fixture current
old="$(head_of "$TMP/current/clone")"
run_sync "$TMP/current/clone"
if [ "$RC" -eq 0 ] && grep -q '\[OK\] already up to date' "$TMP/out" \
    && [ "$(head_of "$TMP/current/clone")" = "$old" ]; then
    pass "already current exits 0 without changes"
else
    fail "already current exits 0 without changes (rc=$RC)"
fi

# --- 3. fetch failure (offline/auth) ---
new_fixture offline
git_fix -C "$TMP/offline/clone" remote set-url origin "$TMP/nonexistent-remote"
old="$(head_of "$TMP/offline/clone")"
run_sync "$TMP/offline/clone"
if [ "$RC" -eq 24 ] && grep -q 'continuing from current checkout' "$TMP/out" \
    && [ "$(head_of "$TMP/offline/clone")" = "$old" ]; then
    pass "fetch failure exits 24 and preserves HEAD"
else
    fail "fetch failure exits 24 and preserves HEAD (rc=$RC)"
fi

# --- 4. dirty tracked file while behind ---
new_fixture dirty
advance_origin dirty
printf 'my local edit\n' >"$TMP/dirty/clone/base.txt"
old="$(head_of "$TMP/dirty/clone")"
run_sync "$TMP/dirty/clone"
if [ "$RC" -eq 27 ] && grep -q 'local changes present' "$TMP/out" \
    && [ "$(head_of "$TMP/dirty/clone")" = "$old" ] \
    && [ "$(cat "$TMP/dirty/clone/base.txt")" = "my local edit" ]; then
    pass "dirty tracked file exits 27 and preserves content"
else
    fail "dirty tracked file exits 27 and preserves content (rc=$RC)"
fi

# --- 5. staged change while behind ---
new_fixture staged
advance_origin staged
printf 'staged edit\n' >"$TMP/staged/clone/base.txt"
git_fix -C "$TMP/staged/clone" add base.txt
old="$(head_of "$TMP/staged/clone")"
run_sync "$TMP/staged/clone"
env -i PATH="$STUB_BIN" GIT_CONFIG_GLOBAL="$GITCFG" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$TMP/staged/clone" diff --cached --name-only >"$TMP/staged-idx" 2>/dev/null
if [ "$RC" -eq 27 ] && [ "$(head_of "$TMP/staged/clone")" = "$old" ] \
    && grep -qx 'base.txt' "$TMP/staged-idx"; then
    pass "staged change exits 27 and preserves index"
else
    fail "staged change exits 27 and preserves index (rc=$RC)"
fi

# --- 8. detached HEAD ---
new_fixture detached
git_fix -C "$TMP/detached/clone" checkout -q --detach
old="$(head_of "$TMP/detached/clone")"
run_sync "$TMP/detached/clone"
if [ "$RC" -eq 21 ] && grep -q 'detached HEAD' "$TMP/out" \
    && [ "$(head_of "$TMP/detached/clone")" = "$old" ]; then
    pass "detached HEAD exits 21"
else
    fail "detached HEAD exits 21 (rc=$RC)"
fi

# --- 9. missing upstream ---
new_fixture noup
git_fix -C "$TMP/noup/clone" checkout -q -b nostream
run_sync "$TMP/noup/clone"
if [ "$RC" -eq 23 ] && grep -q 'no upstream configured' "$TMP/out"; then
    pass "missing upstream exits 23"
else
    fail "missing upstream exits 23 (rc=$RC)"
fi

# --- 10. local ahead ---
new_fixture ahead
printf 'local work\n' >"$TMP/ahead/clone/local.txt"
git_fix -C "$TMP/ahead/clone" add local.txt
git_fix -C "$TMP/ahead/clone" commit -q -m local
old="$(head_of "$TMP/ahead/clone")"
run_sync "$TMP/ahead/clone"
if [ "$RC" -eq 25 ] && grep -q 'ahead of upstream' "$TMP/out" \
    && [ "$(head_of "$TMP/ahead/clone")" = "$old" ]; then
    pass "local ahead exits 25 and keeps local commit"
else
    fail "local ahead exits 25 and keeps local commit (rc=$RC)"
fi

# --- 11. diverged ---
new_fixture diverged
advance_origin diverged
printf 'local fork\n' >"$TMP/diverged/clone/local.txt"
git_fix -C "$TMP/diverged/clone" add local.txt
git_fix -C "$TMP/diverged/clone" commit -q -m fork
old="$(head_of "$TMP/diverged/clone")"
run_sync "$TMP/diverged/clone"
merges="$(env -i PATH="$STUB_BIN" GIT_CONFIG_GLOBAL="$GITCFG" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$TMP/diverged/clone" rev-list --merges HEAD 2>/dev/null)"
if [ "$RC" -eq 26 ] && grep -q 'diverged' "$TMP/out" \
    && [ "$(head_of "$TMP/diverged/clone")" = "$old" ] && [ -z "$merges" ]; then
    pass "diverged exits 26 with no merge commit"
else
    fail "diverged exits 26 with no merge commit (rc=$RC)"
fi

# --- 12. --require-branch on wrong branch: no fetch attempted ---
new_fixture wrongbr
git_fix -C "$TMP/wrongbr/clone" checkout -q -b feature
git_fix -C "$TMP/wrongbr/clone" remote set-url origin "$TMP/would-fail"
run_sync --require-branch main "$TMP/wrongbr/clone"
if [ "$RC" -eq 22 ] && grep -q 'not main; skipping sync' "$TMP/out"; then
    pass "wrong branch exits 22 before any fetch"
else
    fail "wrong branch exits 22 before any fetch (rc=$RC)"
fi

# --- 13. not a work tree ---
mkdir -p "$TMP/notrepo"
run_sync "$TMP/notrepo"
if [ "$RC" -eq 20 ] && grep -q 'not a git work tree' "$TMP/out"; then
    pass "non-repo dir exits 20"
else
    fail "non-repo dir exits 20 (rc=$RC)"
fi

# --- 14. dirty but NOT behind: already up to date wins ---
new_fixture dirtycur
printf 'local edit\n' >"$TMP/dirtycur/clone/base.txt"
run_sync "$TMP/dirtycur/clone"
if [ "$RC" -eq 0 ] && grep -q '\[OK\] already up to date' "$TMP/out"; then
    pass "dirty but current reports already up to date"
else
    fail "dirty but current reports already up to date (rc=$RC)"
fi

# --- 6. untracked collision ---
new_fixture untracked
advance_origin untracked newfile.txt "upstream content"
printf 'my private note\n' >"$TMP/untracked/clone/newfile.txt"
old="$(head_of "$TMP/untracked/clone")"
run_sync "$TMP/untracked/clone"
if [ "$RC" -eq 28 ] && grep -q 'working tree verified unchanged' "$TMP/out" \
    && [ "$(head_of "$TMP/untracked/clone")" = "$old" ] \
    && [ "$(cat "$TMP/untracked/clone/newfile.txt")" = "my private note" ]; then
    pass "untracked collision exits 28 and preserves local file"
else
    fail "untracked collision exits 28 and preserves local file (rc=$RC)"
fi

# --- 7. plain untracked file (no collision) fast-forwards over it ---
new_fixture bystander
advance_origin bystander
printf 'scratch\n' >"$TMP/bystander/clone/scratch.txt"
tip="$(head_of "$TMP/bystander/work")"
run_sync "$TMP/bystander/clone"
if [ "$RC" -eq 0 ] && [ "$(head_of "$TMP/bystander/clone")" = "$tip" ] \
    && [ "$(cat "$TMP/bystander/clone/scratch.txt")" = "scratch" ]; then
    pass "non-colliding untracked file survives fast-forward"
else
    fail "non-colliding untracked file survives fast-forward (rc=$RC)"
fi

# --- 15. ignored-file collision: --no-overwrite-ignore protects it ---
new_fixture ignored
printf 'PRIVATE local value\n' >"$TMP/ignored/clone/secret.conf"
advance_origin ignored secret.conf "upstream tracked version" forceadd
old="$(head_of "$TMP/ignored/clone")"
run_sync "$TMP/ignored/clone"
if [ "$RC" -eq 28 ] && [ "$(head_of "$TMP/ignored/clone")" = "$old" ] \
    && [ "$(cat "$TMP/ignored/clone/secret.conf")" = "PRIVATE local value" ]; then
    pass "ignored-file collision refused; local content preserved"
else
    fail "ignored-file collision refused; local content preserved (rc=$RC)"
fi

# --- 16. hostile config cannot subvert the guarded merge ---
new_fixture hostile
advance_origin hostile
git_fix -C "$TMP/hostile/clone" config branch.main.mergeoptions --squash
git_fix -C "$TMP/hostile/clone" config merge.autostash true
tip="$(head_of "$TMP/hostile/work")"
run_sync "$TMP/hostile/clone"
stashes="$(env -i PATH="$STUB_BIN" GIT_CONFIG_GLOBAL="$GITCFG" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$TMP/hostile/clone" stash list 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$(head_of "$TMP/hostile/clone")" = "$tip" ] && [ -z "$stashes" ]; then
    pass "hostile mergeoptions/autostash still lands exactly on upstream"
else
    fail "hostile mergeoptions/autostash still lands exactly on upstream (rc=$RC)"
fi
new_fixture hostiledirty
advance_origin hostiledirty
git_fix -C "$TMP/hostiledirty/clone" config merge.autostash true
printf 'uncommitted\n' >"$TMP/hostiledirty/clone/base.txt"
run_sync "$TMP/hostiledirty/clone"
if [ "$RC" -eq 27 ] && [ "$(cat "$TMP/hostiledirty/clone/base.txt")" = "uncommitted" ]; then
    pass "autostash config never stashes a dirty tree"
else
    fail "autostash config never stashes a dirty tree (rc=$RC)"
fi

# make_wrapper <dir> <script-body>: a fake `git` first on PATH; the body
# runs with $REAL_GIT available and "$@" being the git args.
make_wrapper() {
    wdir="$1"; body="$2"
    mkdir -p "$wdir"
    {
        printf '#!/bin/sh\n'
        printf 'REAL_GIT=%s\n' "$REAL_GIT"
        printf '%s\n' "$body"
        printf 'exec "$REAL_GIT" "$@"\n'
    } >"$wdir/git"
    chmod +x "$wdir/git"
}
run_sync_wrapped() { wdir="$1"; shift; hrun "$wdir:$STUB_BIN" bash "$REPO/$SYNC" "$@"; }

# --- 17. pre-merge inspection error fails closed (exit 29, no merge) ---
new_fixture inspfail
advance_origin inspfail
old="$(head_of "$TMP/inspfail/clone")"
make_wrapper "$TMP/w-revlist" '
case "$*" in *" rev-list "*) exit 128 ;; esac'
run_sync_wrapped "$TMP/w-revlist" "$TMP/inspfail/clone"
if [ "$RC" -eq 29 ] && grep -q 'could not inspect' "$TMP/out" \
    && [ "$(head_of "$TMP/inspfail/clone")" = "$old" ]; then
    pass "rev-list failure exits 29 without merging"
else
    fail "rev-list failure exits 29 without merging (rc=$RC)"
fi

# --- 18. merge fails after moving HEAD -> exit 30, no rollback ---
new_fixture headmoved
advance_origin headmoved
tip="$(head_of "$TMP/headmoved/work")"
make_wrapper "$TMP/w-headmove" '
case "$*" in *" merge "*)
    repo=""; [ "$1" = "-C" ] && repo="$2"
    "$REAL_GIT" -C "$repo" update-ref HEAD '"$tip"'
    exit 1 ;;
esac'
run_sync_wrapped "$TMP/w-headmove" "$TMP/headmoved/clone"
if [ "$RC" -eq 30 ] && grep -q 'uncertain state' "$TMP/out" \
    && [ "$(head_of "$TMP/headmoved/clone")" = "$tip" ]; then
    pass "moved HEAD on failed merge exits 30, evidence preserved"
else
    fail "moved HEAD on failed merge exits 30, evidence preserved (rc=$RC)"
fi

# --- 19. merge fails after touching a working file -> exit 30 ---
new_fixture filetouched
advance_origin filetouched
make_wrapper "$TMP/w-filetouch" '
case "$*" in *" merge "*)
    repo=""; [ "$1" = "-C" ] && repo="$2"
    printf "mutated\n" >>"$repo/base.txt"
    exit 1 ;;
esac'
run_sync_wrapped "$TMP/w-filetouch" "$TMP/filetouched/clone"
if [ "$RC" -eq 30 ] && grep -q 'uncertain state' "$TMP/out"; then
    pass "mutated working file on failed merge exits 30, not 28"
else
    fail "mutated working file on failed merge exits 30, not 28 (rc=$RC)"
fi

# --- 20. post-merge verification failure -> exit 30, never 28/29 ---
new_fixture postinsp
advance_origin postinsp
make_wrapper "$TMP/w-postinsp" '
MARKER="'"$TMP"'/postinsp-merged"
case "$*" in
  *" merge "*) "$REAL_GIT" "$@"; rc=$?; touch "$MARKER"; exit $rc ;;
  *" rev-parse HEAD") [ -f "$MARKER" ] && exit 128 ;;
esac'
run_sync_wrapped "$TMP/w-postinsp" "$TMP/postinsp/clone"
if [ "$RC" -eq 30 ] && grep -q 'uncertain state' "$TMP/out"; then
    pass "post-merge inspection failure exits 30"
else
    fail "post-merge inspection failure exits 30 (rc=$RC)"
fi

# --- 21. MERGE_HEAD probe error after failed merge -> 30, not 28 ---
new_fixture mhprobe
advance_origin mhprobe newfile.txt "upstream content"
printf 'collide\n' >"$TMP/mhprobe/clone/newfile.txt"
make_wrapper "$TMP/w-mhprobe" '
case "$*" in *"--verify MERGE_HEAD"*) exit 128 ;; esac'
run_sync_wrapped "$TMP/w-mhprobe" "$TMP/mhprobe/clone"
if [ "$RC" -eq 30 ]; then
    pass "MERGE_HEAD probe error exits 30, not 28"
else
    fail "MERGE_HEAD probe error exits 30, not 28 (rc=$RC)"
fi

# --- 22. untracked content mutated on failed merge -> 30, not 28 ---
new_fixture untrmut
advance_origin untrmut
printf 'original note\n' >"$TMP/untrmut/clone/note.txt"
make_wrapper "$TMP/w-untrmut" '
case "$*" in *" merge "*)
    repo=""; [ "$1" = "-C" ] && repo="$2"
    printf "tampered\n" >"$repo/note.txt"
    exit 1 ;;
esac'
run_sync_wrapped "$TMP/w-untrmut" "$TMP/untrmut/clone"
if [ "$RC" -eq 30 ]; then
    pass "mutated untracked content on failed merge exits 30"
else
    fail "mutated untracked content on failed merge exits 30 (rc=$RC)"
fi

# --- 23. symbolic-ref probe error -> 29, not misclassified detached ---
new_fixture srprobe
make_wrapper "$TMP/w-srprobe" '
case "$*" in *" symbolic-ref "*) exit 128 ;; esac'
run_sync_wrapped "$TMP/w-srprobe" "$TMP/srprobe/clone"
if [ "$RC" -eq 29 ] && grep -q 'could not inspect' "$TMP/out"; then
    pass "symbolic-ref probe error exits 29, not 21"
else
    fail "symbolic-ref probe error exits 29, not 21 (rc=$RC)"
fi

# --- 24. local "." upstream syncs without fetching ---
new_fixture localup
git_fix -C "$TMP/localup/clone" remote set-url origin "$TMP/would-fail"
git_fix -C "$TMP/localup/clone" checkout -q -b behind "HEAD~0"
git_fix -C "$TMP/localup/clone" branch -q --set-upstream-to=main behind
git_fix -C "$TMP/localup/clone" checkout -q main
printf 'main moves on\n' >"$TMP/localup/clone/base.txt"
git_fix -C "$TMP/localup/clone" commit -q -am mainadvance
maintip="$(head_of "$TMP/localup/clone")"
git_fix -C "$TMP/localup/clone" checkout -q behind
run_sync "$TMP/localup/clone"
if [ "$RC" -eq 0 ] && [ "$(head_of "$TMP/localup/clone")" = "$maintip" ]; then
    pass "local dot upstream fast-forwards without fetch"
else
    fail "local dot upstream fast-forwards without fetch (rc=$RC)"
fi

# --- 25. untracked symlink + non-ASCII filename do not block a safe ff ---
new_fixture nastynames
advance_origin nastynames
ln -s /nonexistent-target "$TMP/nastynames/clone/dangling-link"
nastyfile="$TMP/nastynames/clone/re\xcc\x81sume\xcc\x81.txt"
printf 'notes\n' >"$(printf '%b' "$nastyfile")"
tip="$(head_of "$TMP/nastynames/work")"
run_sync "$TMP/nastynames/clone"
if [ "$RC" -eq 0 ] && [ "$(head_of "$TMP/nastynames/clone")" = "$tip" ] \
    && [ -L "$TMP/nastynames/clone/dangling-link" ] \
    && [ "$(readlink "$TMP/nastynames/clone/dangling-link")" = "/nonexistent-target" ] \
    && [ "$(cat "$(printf '%b' "$nastyfile")")" = "notes" ]; then
    pass "untracked symlink and non-ASCII filename survive fast-forward"
else
    fail "untracked symlink and non-ASCII filename survive fast-forward (rc=$RC)"
fi

# --- 26. retargeted untracked symlink on a failed merge is caught as 30 ---
new_fixture linkmut
advance_origin linkmut
ln -s target-a "$TMP/linkmut/clone/link"
make_wrapper "$TMP/w-linkmut" '
case "$*" in *" merge "*)
    repo=""; [ "$1" = "-C" ] && repo="$2"
    rm -f "$repo/link"
    ln -s target-b "$repo/link"
    exit 1 ;;
esac'
run_sync_wrapped "$TMP/w-linkmut" "$TMP/linkmut/clone"
if [ "$RC" -eq 30 ] && grep -q 'uncertain state' "$TMP/out"; then
    pass "retargeted untracked symlink on failed merge exits 30, not 28"
else
    fail "retargeted untracked symlink on failed merge exits 30, not 28 (rc=$RC)"
fi

# --- 27. raw line-ending mutation under core.autocrlf is not filtered away ---
new_fixture crlfmut
advance_origin crlfmut
git_fix -C "$TMP/crlfmut/clone" config core.autocrlf true
printf 'line one\nline two\n' >"$TMP/crlfmut/clone/note.txt"
make_wrapper "$TMP/w-crlfmut" '
case "$*" in *" merge "*)
    repo=""; [ "$1" = "-C" ] && repo="$2"
    printf "line one\r\nline two\r\n" >"$repo/note.txt"
    exit 1 ;;
esac'
run_sync_wrapped "$TMP/w-crlfmut" "$TMP/crlfmut/clone"
if [ "$RC" -eq 30 ] && grep -q 'uncertain state' "$TMP/out"; then
    pass "raw CRLF rewrite under core.autocrlf exits 30, not 28"
else
    fail "raw CRLF rewrite under core.autocrlf exits 30, not 28 (rc=$RC)"
fi

# --- 28. branch switch during the fetch window is caught, not fast-forwarded ---
new_fixture sneakybranch
advance_origin sneakybranch
origintip="$(head_of "$TMP/sneakybranch/work")"
make_wrapper "$TMP/w-sneakybranch" '
case "$*" in *" fetch "*)
    repo=""; [ "$1" = "-C" ] && repo="$2"
    "$REAL_GIT" "$@"; rc=$?
    "$REAL_GIT" -C "$repo" checkout -q -b sneaky
    exit $rc ;;
esac'
run_sync_wrapped "$TMP/w-sneakybranch" "$TMP/sneakybranch/clone"
if [ "$RC" -eq 29 ] && [ "$(head_of "$TMP/sneakybranch/clone")" != "$origintip" ]; then
    pass "branch switch during fetch window exits 29, not fast-forwarded"
else
    fail "branch switch during fetch window exits 29, not fast-forwarded (rc=$RC)"
fi

# --- usage errors ---
run_sync --bogus-flag
[ "$RC" -eq 2 ] && pass "unknown flag exits 2" || fail "unknown flag exits 2 (rc=$RC)"
run_sync --require-branch
[ "$RC" -eq 2 ] && pass "missing flag value exits 2" || fail "missing flag value exits 2 (rc=$RC)"

# --- call-site wiring (static) ---
# NB: the old code was `git -C "$DOTFILES" pull --ff-only`, which does NOT
# contain the literal "git pull" -- match the pull verb itself.
grep -q 'install/common/repo-sync.sh" --require-branch main' "$REPAIR" \
    && pass "repair delegates step 1 to repo-sync with main policy" \
    || fail "repair delegates step 1 to repo-sync with main policy"
! grep -qE '(^|[^[:alnum:]_-])pull([^[:alnum:]_-]|$)' "$REPAIR" \
    && pass "repair no longer pulls directly" \
    || fail "repair no longer pulls directly"
grep -qF '|| sync_status=$?' "$REPAIR" \
    && pass "repair captures sync status set -e safely" \
    || fail "repair captures sync status set -e safely"
grep -q -- '-ge 20' "$REPAIR" && grep -q 'exit "\$sync_status"' "$REPAIR" \
    && pass "repair stops on unverified sync state" \
    || fail "repair stops on unverified sync state"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
