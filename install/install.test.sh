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
assert "workflow bootstrap supports a Codex-only machine" \
    rg -q 'command -v claude.*command -v codex' install/common/claude-plugins.sh
assert "workflow bootstrap attempts Superpowers after an ECC failure" \
    sh -c "rg -q 'ecc-install \\|\\| ecc_status=' install/common/claude-plugins.sh && rg -q 'superpowers-install \\|\\| superpowers_status=' install/common/claude-plugins.sh"
assert "workflow bootstrap reports combined runtime status" \
    rg -q 'ecc_status.*superpowers_status' install/common/claude-plugins.sh

assert "ssh config includes config_cloudflared between config_local and config_personal" \
    awk '/^Include ~\/.ssh\/config_local$/{a=NR} /^Include ~\/.ssh\/config_cloudflared$/{b=NR} /^Include ~\/.ssh\/config_personal$/{c=NR} END{exit !(a && b && c && a<b && b<c)}' ssh/configs/config
assert "cloudflared ssh template carries the access ProxyCommand" \
    rg -q -F '    ProxyCommand cloudflared access ssh --hostname %h' ssh/configs/config_cloudflared.tmpl
assert "cloudflared ssh template hosts stay on the example.com placeholder" \
    sh -c "test -f ssh/configs/config_cloudflared.tmpl && rg -q '^Host ' ssh/configs/config_cloudflared.tmpl && ! rg '^Host ' ssh/configs/config_cloudflared.tmpl | rg -v -q '\\.ssh\\.example\\.com$'"
assert "link.sh seeds config_cloudflared machine-local, never symlinks it" \
    sh -c "rg -q -F 'seed_machine_local_file \"\$DOTFILEDIR\"/ssh/configs/config_cloudflared.tmpl \"\$HOME\"/.ssh/config_cloudflared' install/common/link.sh && ! rg -q 'ln -sf.*config_cloudflared' install/common/link.sh"
assert "link.sh links remote-access-doctor into ~/bin" \
    rg -q -F 'ln -sf "$DOTFILEDIR"/bin/remote-access-doctor "$HOME"/bin/remote-access-doctor' install/common/link.sh

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
