#!/bin/sh
# remote-access-doctor.test.sh - drive bin/remote-access-doctor through a
# temporary HOME and a stub cloudflared. No network, no real HOME reads.
set -e

PASS=0
FAIL=0

assert() {
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/remote-access-doctor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fresh_home <name>: a HOME with a stub cloudflared, the tracked ssh config,
# and the seeded template. Prints the path.
fresh_home() {
    h="$WORK/$1"
    mkdir -p "$h/.ssh" "$h/bin"
    printf '#!/bin/sh\nexit 0\n' > "$h/bin/cloudflared"
    chmod +x "$h/bin/cloudflared"
    cp "$REPO/ssh/configs/config" "$h/.ssh/config"
    cp "$REPO/ssh/configs/config_cloudflared.tmpl" "$h/.ssh/config_cloudflared"
    printf '%s\n' "$h"
}

# run_doctor <home> <outfile>: runs the doctor with only the stub PATH.
run_doctor() {
    HOME="$1" PATH="$1/bin:/usr/bin:/bin" bash "$DOCTOR" > "$2" 2>&1
}

# 1. seeded client with an edited zone passes
h="$(fresh_home ok)"
sed 's/\.ssh\.example\.com/.ssh.example.com.test/' "$REPO/ssh/configs/config_cloudflared.tmpl" > "$h/.ssh/config_cloudflared"
assert "doctor: seeded client with edited zone exits 0" run_doctor "$h" "$h/out"
assert "doctor: seeded client reports the Include as OK" grep -q '^\[OK\] .*config_cloudflared' "$h/out"
assert "doctor: seeded client prints no [X] line" sh -c "! grep -q '^\[X\]' '$h/out'"

# 2. placeholder zone warns but passes
h="$(fresh_home placeholder)"
assert "doctor: placeholder zone exits 0" run_doctor "$h" "$h/out"
assert "doctor: placeholder zone prints a not-configured warning" \
    sh -c "grep '^\[WARNING\]' '$h/out' | grep -q 'not configured'"

# 3. missing Include fails
h="$(fresh_home noinclude)"
grep -v 'config_cloudflared' "$REPO/ssh/configs/config" > "$h/.ssh/config"
assert "doctor: missing Include exits 1" sh -c "! HOME='$h' PATH='$h/bin:/usr/bin:/bin' bash '$DOCTOR' > '$h/out' 2>&1"
assert "doctor: missing Include prints an [X] line" grep -q '^\[X\] .*config_cloudflared' "$h/out"

# 4. symlinked config_cloudflared fails
h="$(fresh_home symlink)"
rm "$h/.ssh/config_cloudflared"
ln -s "$REPO/ssh/configs/config_cloudflared.tmpl" "$h/.ssh/config_cloudflared"
assert "doctor: symlinked config_cloudflared exits 1" sh -c "! HOME='$h' PATH='$h/bin:/usr/bin:/bin' bash '$DOCTOR' > '$h/out' 2>&1"
assert "doctor: symlinked config_cloudflared names the symlink" grep -q '^\[X\] .*symlink' "$h/out"

# 5. cloudflared missing from PATH fails
h="$(fresh_home nocf)"
rm "$h/bin/cloudflared"
assert "doctor: cloudflared missing exits 1" sh -c "! HOME='$h' PATH='$h/bin:/usr/bin:/bin' bash '$DOCTOR' > '$h/out' 2>&1"
assert "doctor: cloudflared missing prints an [X] line" grep -q '^\[X\] .*cloudflared' "$h/out"

# 6. host role: user-domain unit present, key authorized
h="$(fresh_home host-ok)"
mkdir -p "$h/Library/LaunchAgents"
: > "$h/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
printf 'ssh-ed25519 AAAATESTKEYONLY test@example.com\n' > "$h/.ssh/id_ed25519_personal.pub"
printf 'ssh-ed25519 AAAATESTKEYONLY test@example.com\n' > "$h/.ssh/authorized_keys"
run_doctor "$h" "$h/out" || true
assert "doctor: host role detected from the LaunchAgents unit" grep -q '^\[INFO\] .*session host' "$h/out"
assert "doctor: authorized_keys with the personal key is OK" grep -q '^\[OK\] .*authorized_keys' "$h/out"

# 7. host role: unit present, key missing warns
h="$(fresh_home host-nokey)"
mkdir -p "$h/Library/LaunchAgents"
: > "$h/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
printf 'ssh-ed25519 AAAATESTKEYONLY test@example.com\n' > "$h/.ssh/id_ed25519_personal.pub"
run_doctor "$h" "$h/out" || true
assert "doctor: host without the personal key in authorized_keys warns" \
    grep -q '^\[WARNING\] .*authorized_keys' "$h/out"

# 8. the script stays read-only
assert "doctor: contains no service or tunnel mutation outside comments" \
    sh -c "! grep -v '^[[:space:]]*#' '$DOCTOR' | grep -E -q 'sudo|launchctl (load|bootstrap|kickstart)|systemctl (enable|start|restart)|cloudflared tunnel|cloudflared service'"
assert "doctor: is executable and parses" sh -c "test -x '$DOCTOR' && bash -n '$DOCTOR'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
