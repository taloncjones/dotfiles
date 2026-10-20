#!/bin/sh
# omz-update.test.sh -- the dotfiles .zshrc must keep oh-my-zsh's update
# check from stopping at a [Y/n] prompt during shell start (a fresh herdr
# pane types its readiness probe into that prompt).
#
# Case 1 runs everywhere: a stub oh-my-zsh.sh records the update mode the
# dotfiles .zshrc set before sourcing it. Cases 2-4 run the real upstream
# checker (tools/check_for_upgrade.sh from OMZ_UPSTREAM, default
# ~/.oh-my-zsh) under a pty with a stale stamp; they are skipped when no
# upstream checker is installed (CI).

set -u

ZSHRC=zsh/.zshrc
if [ ! -f "$ZSHRC" ]; then
    echo "FAIL: $ZSHRC not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; }

ZSH_BIN=$(command -v zsh || true)
if [ -z "$ZSH_BIN" ]; then
    echo "SKIP  zsh not installed; omz-update cases not run"
    printf '\n0 passed, 0 failed\n'
    exit 0
fi

REPO=$(pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/omz-update-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

# new_home <name>: sandbox HOME whose .zshrc is a symlink to the repo file,
# so the .zshrc resolves DOTFILEDIR to this checkout.
new_home() {
    mkdir -p "$TMP/$1/.oh-my-zsh"
    ln -s "$REPO/$ZSHRC" "$TMP/$1/.zshrc"
}

# --- case 1: mode seen at the source boundary ---
new_home stub
cat >"$TMP/stub/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
zstyle -s ':omz:update' mode _seen_mode || _seen_mode=UNSET
print -r -- "$_seen_mode" >"$HOME/seen-mode"
EOF
env -i HOME="$TMP/stub" PATH=/usr/bin:/bin TERM=dumb "$ZSH_BIN" -i -c : >/dev/null 2>&1 </dev/null
if [ "$(cat "$TMP/stub/seen-mode" 2>/dev/null)" = "reminder" ]; then
    pass "zshrc sets the oh-my-zsh update mode to reminder at the source boundary"
else
    fail "zshrc sets the oh-my-zsh update mode to reminder at the source boundary"
fi

# --- cases 2-4: real upstream checker under a pty ---
UPSTREAM="${OMZ_UPSTREAM:-$HOME/.oh-my-zsh}"
CHECKER="$UPSTREAM/tools/check_for_upgrade.sh"
if [ ! -f "$CHECKER" ] || ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip "stale stamp: oh-my-zsh update check ran and printed its reminder (no upstream checker, python3 or git)"
    skip "stale stamp: login shell shows no oh-my-zsh [Y/n] prompt (no upstream checker, python3 or git)"
    skip "stale stamp: login shell reaches the command after .zshrc (no upstream checker, python3 or git)"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
    exit
fi

new_home real
OMZ="$TMP/real/.oh-my-zsh"
mkdir -p "$OMZ/tools" "$OMZ/log" "$TMP/real/.cache/oh-my-zsh"
cp "$CHECKER" "$OMZ/tools/check_for_upgrade.sh"
# Minimal stand-in for oh-my-zsh.sh: just the cache dir and the checker.
cat >"$OMZ/oh-my-zsh.sh" <<'EOF'
ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"
source "$ZSH/tools/check_for_upgrade.sh"
EOF
# A git work tree whose origin is not on GitHub: upstream assumes "update available".
git -C "$OMZ" init -q
git -C "$OMZ" remote add origin "$TMP/no-such-origin"
printf 'LAST_EPOCH=0\n' >"$TMP/real/.cache/oh-my-zsh/.zsh-update"

cat >"$TMP/drive.py" <<'EOF'
import os, pty, select, sys, time

zsh, home, out_path = sys.argv[1:4]
env = {"HOME": home, "PATH": "/usr/bin:/bin", "TERM": "dumb"}
pid, fd = pty.fork()
if pid == 0:
    os.execve(zsh, [zsh, "-il"], env)

buf = b""

def read_until(deadline, stop):
    global buf
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                return False
            if not chunk:
                return False
            buf += chunk
        if stop(buf):
            return True
    return False

def settled(b):
    return b"It's time to update!" in b or b"Would you like to update? [Y/n]" in b

# Type nothing until the checker has spoken: early input would make upstream
# print the reminder even in prompt mode and hide the defect.
if read_until(time.time() + 30, settled) and b"Would you like to update? [Y/n]" not in buf:
    time.sleep(1)
    os.write(fd, b"print -r -- OMZ_REAL_REACHED\nexit\n")
    read_until(time.time() + 30, lambda b: False)
else:
    os.kill(pid, 9)
with open(out_path, "wb") as f:
    f.write(buf)
EOF
python3 -I "$TMP/drive.py" "$ZSH_BIN" "$TMP/real" "$TMP/real-out" </dev/null >/dev/null 2>&1

if grep -qF "It's time to update!" "$TMP/real-out" 2>/dev/null; then
    pass "stale stamp: oh-my-zsh update check ran and printed its reminder"
else
    fail "stale stamp: oh-my-zsh update check ran and printed its reminder"
fi
if [ -f "$TMP/real-out" ] && ! grep -qF '[Y/n]' "$TMP/real-out"; then
    pass "stale stamp: login shell shows no oh-my-zsh [Y/n] prompt"
else
    fail "stale stamp: login shell shows no oh-my-zsh [Y/n] prompt"
fi
if grep -q '^OMZ_REAL_REACHED' "$TMP/real-out" 2>/dev/null; then
    pass "stale stamp: login shell reaches the command after .zshrc"
else
    fail "stale stamp: login shell reaches the command after .zshrc"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
