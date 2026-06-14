#!/bin/sh
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

assert "macOS Brewfile uses current Docker Desktop cask" \
    rg -q 'cask "docker-desktop"' install/macos/Brewfile.rb
assert "macOS Brewfile avoids renamed docker cask" \
    sh -c "! rg -q 'cask \"docker\"' install/macos/Brewfile.rb"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
