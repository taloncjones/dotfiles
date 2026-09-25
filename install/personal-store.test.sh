#!/bin/sh
# personal-store.test.sh -- behavioral tests for install/common/exocortex.sh:
# the personal-scope clone, link, import and seed step for the private todo
# store, and the proof that a work-scoped launch resolves no store path.
# Hermetic: temp HOME per case, pinned GIT_CONFIG_GLOBAL, local bare remotes.
set -u

EXO=install/common/exocortex.sh
TODOS=claude/skills/todos/scripts/todos.sh
[ -f "$EXO" ] || { echo "FAIL: $EXO not found (run from repo root)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

REPO="$(pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/personal-store-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

GCFG="$TMP/gitconfig"
printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n[core]\n\thooksPath = /dev/null\n[commit]\n\tgpgsign = false\n' >"$GCFG"
g() { GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_NOSYSTEM=1 git "$@"; }

# hx <home> <remote> <dotfiles> <command...>: run with a hermetic environment.
# Extra variables go through `env NAME=value` inside <command...>.
hx() {
    h="$1" r="$2" d="$3"; shift 3
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_PERSONAL_ONLY -u WORKFLOW_PERSONAL_ACCOUNT \
        -u CLAUDE_WORK_TREE -u CLAUDE_WORK_CONFIG_DIR -u CLAUDE_CODE_REMOTE \
        -u GIT_SSH_COMMAND -u GIT_DIR -u GIT_WORK_TREE -u XDG_STATE_HOME \
        -u TODOS_OFFLINE -u TODOS_SYNC_TIMEOUT -u TODOS_LOCK_WAIT -u TODOS_REGISTRY \
        -u HERDR_ENV -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID -u HERDR_TAB_ID \
        HOME="$h" GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_NOSYSTEM=1 \
        EXOCORTEX_REMOTE="$r" DOTFILEDIR="$d" "$@"
}
realpath_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# new_home <name>: an empty HOME with the personal and work repo roots.
new_home() { mkdir -p "$TMP/$1/Git/personal" "$TMP/$1/Git/work"; printf '%s' "$TMP/$1"; }
# seed_into <bare>: push one `exocortex: seed` commit with the store layout.
seed_into() {
    s="$1.seed"; g init -q "$s"
    mkdir -p "$s/repos/dotfiles/.todos/pending" "$s/repos/dotfiles/.todos/completed"
    : >"$s/repos/dotfiles/.todos/pending/.gitkeep"; : >"$s/repos/dotfiles/.todos/completed/.gitkeep"
    printf 'TODO.md\n*.tmp.*\n*.swp\n*~\n.DS_Store\n' >"$s/.gitignore"
    g -C "$s" add -A; g -C "$s" commit -qm "exocortex: seed"; g -C "$s" push -q "$1" main
    rm -rf "$s"
}
seeded_remote() { g init -q --bare "$1"; seed_into "$1"; }
# dotfiles_fixture <home>: primary checkout ~/Git/personal/dotfiles whose real
# .todos holds one pending todo.
dotfiles_fixture() {
    d="$1/Git/personal/dotfiles"
    g init -q "$d"; g -C "$d" commit -q --allow-empty -m base
    mkdir -p "$d/.todos/pending" "$d/.todos/completed"
    printf -- '---\ncreated: 2026-01-01\ntitle: Local item\n---\n' >"$d/.todos/pending/2026-01-01-local-item.md"
    printf '%s' "$d"
}

# --- resolve (R15) ---
H=$(new_home resolve); DF=$(dotfiles_fixture "$H"); W="$H/Git/work/acme"; g init -q "$W"
out=$(hx "$H" "" "$DF" bash "$EXO" resolve --cwd "$DF"); rc=$?
if [ "$rc|$out" = "0|$H/Git/personal/exocortex" ]; then pass "resolve: personal checkout prints the clone path"; else fail "resolve: personal checkout prints the clone path ($rc|$out)"; fi
out=$(hx "$H" "" "$DF" env CLAUDE_CONFIG_DIR="$H/.claude-work" bash "$EXO" resolve --cwd "$W"); rc=$?
if [ "$rc|$out" = "3|" ]; then pass "resolve: work repo under the work config exits 3"; else fail "resolve: work repo under the work config exits 3 ($rc|$out)"; fi
out=$(hx "$H" "" "$DF" env CLAUDE_CONFIG_DIR="$H/.claude-work" bash "$EXO" resolve --cwd "$DF"); rc=$?
if [ "$rc|$out" = "3|" ]; then pass "resolve: personal checkout under the work config exits 3"; else fail "resolve: personal checkout under the work config exits 3 ($rc|$out)"; fi

# --- skips (R15d, R16) ---
H=$(new_home workdf); W="$H/Git/work/acme"; g init -q "$W"; g -C "$W" commit -q --allow-empty -m base
mkdir -p "$W/.todos/pending"; R="$TMP/workdf.git"; seeded_remote "$R"
out=$(hx "$H" "$R" "$W" bash "$EXO" install); rc=$?
if [ "$rc" = 0 ] && [ ! -e "$H/Git/personal/exocortex" ] && [ -d "$W/.todos" ] && [ ! -L "$W/.todos" ]; then pass "install: a work DOTFILEDIR skips and clones nothing"; else fail "install: a work DOTFILEDIR skips and clones nothing ($out)"; fi

H=$(new_home cloud); DF=$(dotfiles_fixture "$H"); R="$TMP/cloud.git"; seeded_remote "$R"
out=$(hx "$H" "$R" "$DF" env CLAUDE_CODE_REMOTE=true bash "$EXO" install); rc=$?
case "$rc|$out" in "0|[exocortex] skip: cloud container") [ ! -L "$DF/.todos" ] && [ ! -e "$H/Git/personal/exocortex" ] && pass "install skip: cloud container" || fail "install skip: cloud container" ;; *) fail "install skip: cloud container ($rc|$out)" ;; esac

H=$(new_home linked); DF=$(dotfiles_fixture "$H"); R="$TMP/linked.git"; seeded_remote "$R"
g -C "$DF" worktree add -q "$H/Git/personal/dotfiles-wt" -b wt
out=$(hx "$H" "$R" "$H/Git/personal/dotfiles-wt" bash "$EXO" install); rc=$?
case "$rc|$out" in "0|[exocortex] skip:"*"not the primary checkout"*) pass "install skip: not the primary checkout" ;; *) fail "install skip: not the primary checkout ($rc|$out)" ;; esac

H=$(new_home unreachable); DF=$(dotfiles_fixture "$H"); mkdir -p "$TMP/notgit"
out=$(hx "$H" "$TMP/notgit" "$DF" bash "$EXO" install); rc=$?
case "$rc|$out" in "0|[exocortex] skip: remote unreachable") [ ! -e "$H/Git/personal/exocortex" ] && [ ! -L "$DF/.todos" ] && pass "install skip: remote unreachable" || fail "install skip: remote unreachable" ;; *) fail "install skip: remote unreachable ($rc|$out)" ;; esac

H=$(new_home mismatch); DF=$(dotfiles_fixture "$H"); R="$TMP/mismatch.git"; seeded_remote "$R"; seeded_remote "$TMP/other.git"
g clone -q "$TMP/other.git" "$H/Git/personal/exocortex"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install); rc=$?
case "$rc|$out" in "0|[exocortex] skip:"*"origin"*) [ ! -L "$DF/.todos" ] && pass "install skip: origin mismatch" || fail "install skip: origin mismatch" ;; *) fail "install skip: origin mismatch ($rc|$out)" ;; esac

H=$(new_home notclone); DF=$(dotfiles_fixture "$H"); R="$TMP/notclone.git"; seeded_remote "$R"
mkdir -p "$H/Git/personal/exocortex"; : >"$H/Git/personal/exocortex/stray"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install); rc=$?
case "$rc|$out" in "0|[exocortex] skip:"*"not a git clone"*) [ ! -L "$DF/.todos" ] && pass "install skip: clone path is not a clone" || fail "install skip: clone path is not a clone" ;; *) fail "install skip: clone path is not a clone ($rc|$out)" ;; esac

H=$(new_home empty); DF=$(dotfiles_fixture "$H"); R="$TMP/empty.git"; g init -q --bare "$R"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>/dev/null); rc=$?
case "$rc|$out" in *"[exocortex] skip: store has no commits; run seed"*) [ -d "$H/Git/personal/exocortex/.git" ] && [ ! -L "$DF/.todos" ] && pass "install skip: empty store says to run seed" || fail "install skip: empty store says to run seed" ;; *) fail "install skip: empty store says to run seed ($rc|$out)" ;; esac
# R17b: once the remote is seeded elsewhere, the empty clone picks it up.
seed_into "$R"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -L "$DF/.todos" ]; then pass "install: empty clone picks up a later seed"; else fail "install: empty clone picks up a later seed ($out)"; fi

H=$(new_home blocked); DF=$(dotfiles_fixture "$H"); R="$TMP/blocked.git"; g init -q --bare "$R"
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
printf 'leftover\n' >"$H/Git/personal/exocortex/.gitignore"; seed_into "$R"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>/dev/null); rc=$?
case "$rc|$out" in *"[exocortex] skip:"*"untracked files"*) [ ! -L "$DF/.todos" ] && pass "install skip: untracked files block the checkout" || fail "install skip: untracked files block the checkout" ;; *) fail "install skip: untracked files block the checkout ($rc|$out)" ;; esac

# --- clone, move, link, import (R17, R18, R19) ---
H=$(new_home main); DF=$(dotfiles_fixture "$H"); R="$TMP/main.git"; seeded_remote "$R"
CLONE="$H/Git/personal/exocortex"; STATE="$H/.local/state/dotfiles/todos-import"
mkdir -p "$H/Git/personal/.exocortex.clone.99999999"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>&1); rc=$?
if [ "$(g -C "$CLONE" remote get-url origin)" = "$R" ] && [ "$(g -C "$CLONE" config --bool todos.store)" = true ] \
    && [ -z "$(ls -d "$H/Git/personal"/.exocortex.clone.* 2>/dev/null)" ]; then
    pass "install: clones an opted-in store"; else fail "install: clones an opted-in store ($out)"; fi
if [ ! -e "$H/Git/personal/.exocortex.clone.99999999" ]; then pass "install: removes a dead temp clone"; else fail "install: removes a dead temp clone"; fi
f="$CLONE/repos/dotfiles/.todos/pending/2026-01-01-local-item.md"
if [ -L "$DF/.todos" ] && [ -f "$f" ] && ls -d "$STATE"/*.imported >/dev/null 2>&1 \
    && [ "$(g -C "$CLONE" log -1 --format=%s -- repos/dotfiles/.todos/pending/2026-01-01-local-item.md)" = "todos: import pending/2026-01-01-local-item.md" ] \
    && [ "$(g -C "$R" rev-parse main)" = "$(g -C "$CLONE" rev-parse HEAD)" ]; then
    pass "install: first run moves, links, imports and pushes"; else fail "install: first run moves, links, imports and pushes ($out)"; fi
case "$(realpath_of "$DF/.todos")" in */repos/dotfiles/.todos) pass "install: link realpath keeps a .todos component" ;; *) fail "install: link realpath keeps a .todos component" ;; esac
head=$(g -C "$CLONE" rev-parse HEAD); n=$(ls "$STATE" | wc -l)
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
if [ "$(g -C "$CLONE" rev-parse HEAD)" = "$head" ] && [ "$(ls "$STATE" | wc -l)" = "$n" ]; then pass "install: a second run changes nothing"; else fail "install: a second run changes nothing"; fi
mkdir -p "$STATE/20260101T000000Z-99999999/todos/pending"
printf -- '---\ncreated: 2026-01-02\ntitle: Late item\n---\n' >"$STATE/20260101T000000Z-99999999/todos/pending/2026-01-02-late-item.md"
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
if [ -f "$CLONE/repos/dotfiles/.todos/pending/2026-01-02-late-item.md" ] && [ -d "$STATE/20260101T000000Z-99999999.imported" ]; then
    pass "install: an interrupted import resumes"; else fail "install: an interrupted import resumes"; fi
mkdir -p "$H/.claude-work/projects/x"; ln -s "$CLONE/repos" "$H/.claude-work/projects/x/memory"
out=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>&1)
case "$out" in *"WARNING: $H/.claude-work/projects/x/memory links into"*) pass "install: audit warns about a link into the store" ;; *) fail "install: audit warns about a link into the store ($out)" ;; esac
rm -f "$H/.claude-work/projects/x/memory"
g -C "$CLONE" commit -q --allow-empty -m "todos: new unpushed"; g -C "$CLONE" checkout -q --detach
out=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>/dev/null)
case "$out" in
    *"store HEAD has no upstream"*) case "$out" in *"run seed"*|*delete*) fail "install: detached store HEAD gets no seed advice ($out)" ;; *) pass "install: detached store HEAD gets no seed advice" ;; esac ;;
    *) fail "install: detached store HEAD gets no seed advice ($out)" ;;
esac
g -C "$CLONE" checkout -q main

# --- seed (R20) ---
ADR="$TMP/adr.md"
cat >"$ADR" <<'EOF'
## Decision records

### ADR-0001: First decision

Context: one.
Decision: two.

### ADR-0002: Second, with detail

Body line.

#### Detail

Kept in the body.

## Other section

Not part of any record.
EOF

H=$(new_home seed); DF=$(dotfiles_fixture "$H"); R="$TMP/seed.git"; g init -q --bare "$R"
CLONE="$H/Git/personal/exocortex"
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
out=$(hx "$H" "$R" "$DF" bash "$EXO" seed --decisions-from "$ADR" --date 2026-09-24 2>&1); rc=$?
first="$(head -4 "$CLONE/decisions/0001-first-decision.md" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$first" = "$(printf '# ADR-0001: First decision\n\nStatus: Accepted\nDate: 2026-09-24')" ] \
    && grep -q '^#### Detail$' "$CLONE/decisions/0002-second-with-detail.md" \
    && ! grep -q 'Not part of any record' "$CLONE/decisions/0002-second-with-detail.md" \
    && [ "$(g -C "$CLONE" rev-list --count HEAD)" = 1 ] \
    && [ "$(g -C "$R" rev-parse main)" = "$(g -C "$CLONE" rev-parse HEAD)" ]; then
    pass "seed: writes two ADR records and pushes one commit"; else fail "seed: writes two ADR records and pushes one commit ($out)"; fi

H=$(new_home seeded); DF=$(dotfiles_fixture "$H"); R="$TMP/seeded.git"; g init -q --bare "$R"
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
seed_into "$R"
out=$(hx "$H" "$R" "$DF" bash "$EXO" seed --decisions-from "$ADR" --date 2026-09-24 2>&1); rc=$?
if [ "$rc" = 1 ] && [ ! -e "$H/Git/personal/exocortex/decisions" ] && case "$out" in *"remote already has commits"*) true ;; *) false ;; esac; then pass "seed: refuses a remote that already has commits"; else fail "seed: refuses a remote that already has commits ($rc|$out)"; fi

H=$(new_home repush); DF=$(dotfiles_fixture "$H"); R="$TMP/repush.git"; g init -q --bare "$R"
# GCFG disables hooks globally, so the bare remote gets its own hooksPath.
mkdir -p "$R/hooks"; printf '#!/bin/sh\nexit 1\n' >"$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"; g -C "$R" config core.hooksPath "$R/hooks"
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
hx "$H" "$R" "$DF" bash "$EXO" seed --decisions-from "$ADR" --date 2026-09-24 >/dev/null 2>&1; rc1=$?
out1=$(hx "$H" "$R" "$DF" bash "$EXO" install 2>/dev/null)
rm -f "$R/hooks/pre-receive"
hx "$H" "$R" "$DF" bash "$EXO" seed --decisions-from "$ADR" --date 2026-09-24 >/dev/null 2>&1; rc2=$?
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
case "$out1" in
    *"seed was not pushed"*)
        if [ "$rc1|$rc2" = "0|0" ] && [ "$(g -C "$R" rev-parse main 2>/dev/null)" = "$(g -C "$H/Git/personal/exocortex" rev-parse HEAD)" ] && [ -L "$DF/.todos" ]; then
            pass "seed: a rejected push is retried by the next seed"; else fail "seed: a rejected push is retried by the next seed ($rc1|$rc2)"; fi ;;
    *) fail "seed: a rejected push is retried by the next seed ($out1)" ;;
esac

# --- isolation (R23): a work-scoped launch resolves no store path ---
H=$(new_home iso); DF=$(dotfiles_fixture "$H"); R="$TMP/iso.git"; seeded_remote "$R"
CLONE="$H/Git/personal/exocortex"; W="$H/Git/work/acme"
( HOME="$H"; DOTFILEDIR="$REPO"; export HOME DOTFILEDIR
  . "$REPO/install/common/claude-links.sh"
  link_claude_config_dir "$H/.claude"; link_claude_config_dir "$H/.claude-work" ) >/dev/null 2>&1
hx "$H" "$R" "$DF" bash "$EXO" install >/dev/null 2>&1
g init -q "$W"; g -C "$W" commit -q --allow-empty -m base; mkdir -p "$W/.todos/pending"
real=$(realpath_of "$CLONE")
links=$(find -P "$H/.claude-work" -type l | wc -l | tr -d ' ')
link_into_store() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac; }
bad=$(find -P "$H/.claude-work" -type l | while IFS= read -r l; do
    link_into_store "$(realpath_of "$l")" "$real" && printf '%s\n' "$l"
done)
if [ "$links" -gt 0 ] && [ -z "$bad" ]; then pass "isolation: no link under the work config resolves into the store"; else fail "isolation: no link under the work config resolves into the store ($links|$bad)"; fi
out=$(hx "$H" "$R" "$DF" env CLAUDE_CONFIG_DIR="$H/.claude-work" bash "$EXO" resolve --cwd "$W"); rc=$?
if [ "$rc|$out" = "3|" ]; then pass "isolation: resolve for the work repo under the work config exits 3"; else fail "isolation: resolve for the work repo under the work config exits 3 ($rc|$out)"; fi
p=$(cd "$W" && hx "$H" "" "$W" env CLAUDE_CONFIG_DIR="$H/.claude-work" bash "$REPO/$TODOS" path)
case "$(realpath_of "$p")" in "$real"|"$real"/*) fail "isolation: the work repo's todos path is outside the store" ;; *) pass "isolation: the work repo's todos path is outside the store" ;; esac
out=$(cd "$DF" && hx "$H" "" "$DF" env CLAUDE_CONFIG_DIR="$H/.claude-work" bash "$REPO/$TODOS" list 2>&1); rc=$?
case "$rc|$out" in "1|todos: .todos is not available under this account") pass "isolation: list under the work config reads nothing from the store" ;; *) fail "isolation: list under the work config reads nothing from the store ($rc|$out)" ;; esac
leaks=$(git -C "$REPO" grep --untracked -il exocortex -- claude codex zsh bin git ssh templates vscode zed ghostty)
own=$(git -C "$REPO" grep --untracked -il exocortex -- install/common/exocortex.sh)
if [ -z "$leaks" ] && [ -n "$own" ]; then pass "isolation: no shared surface names the store"; else fail "isolation: no shared surface names the store ($leaks)"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
