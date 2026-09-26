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
assert "workflow bootstrap no longer installs ECC" \
    sh -c "! rg -q 'ecc-install|ecc_status' install/common/claude-plugins.sh"
assert "workflow bootstrap no longer installs Superpowers" \
    sh -c "! rg -q 'superpowers-install|superpowers_status' install/common/claude-plugins.sh"
assert "cloud bootstrap installs no plugin" \
    sh -c "! rg -q 'ensure_plugin' bootstrap-cloud.sh && rg -q -- '--no-plugins' bootstrap-cloud.sh"

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

assert "zed settings enforce account-pinned claude agent entries" \
    node -e '
const fs=require("fs");
const raw=fs.readFileSync("zed/settings.json","utf8");
const o=JSON.parse(raw.replace(/^\s*\/\/.*$/gm,"").replace(/,\s*([}\]])/g,"$1"));
const a=o.agent_servers||{};
const want={"claude-personal":"personal","claude-acp":"personal","claude-work":"work"};
for(const k of Object.keys(want)){
  if(!(k in a))process.exit(1);
}
for(const[k,e]of Object.entries(a)){
  if(!k.startsWith("claude"))continue;
  if(!(k in want))process.exit(1);
  if(!e||e.type!=="custom")process.exit(1);
  if(e.command!=="~/bin/zed-claude-agent")process.exit(1);
  const args=e.args||[];
  if(args[0]!==want[k])process.exit(1);
  if(e.env&&(("CLAUDE_CONFIG_DIR" in e.env)||("ANTHROPIC_API_KEY" in e.env)))process.exit(1);
}
'

assert "zed agent wrapper pins the adapter version" \
    rg -q -F '@agentclientprotocol/claude-agent-acp@0.79.0' bin/zed-claude-agent

assert "link.sh links zed-claude-agent into ~/bin" \
    rg -q -F 'ln -sf "$DOTFILEDIR"/bin/zed-claude-agent "$HOME"/bin/zed-claude-agent' install/common/link.sh

assert "link.sh links herdr-zed-attach into ~/bin" \
    rg -q -F 'ln -sf "$DOTFILEDIR"/bin/herdr-zed-attach "$HOME"/bin/herdr-zed-attach' install/common/link.sh

assert "link.sh links zed settings" \
    rg -q -F 'ln -sf "$DOTFILEDIR"/zed/settings.json "$HOME/.config/zed/settings.json"' install/macos/link.sh

assert "macOS Brewfile installs zed cask" \
    rg -q 'cask "zed"' install/macos/Brewfile.rb
assert "macOS Brewfile installs node for agent adapters" \
    rg -q 'brew "node"' install/macos/Brewfile.rb

assert "link.sh runs the private store step without aborting the install" \
    rg -q -F 'bash "$DOTFILEDIR"/install/common/exocortex.sh install || echo "[WARNING]' install/common/link.sh
assert "cloud bootstrap never runs the private store step" \
    sh -c "! rg -q -i exocortex bootstrap-cloud.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
