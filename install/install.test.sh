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

assert "zed settings enforce account-pinned claude agent entries" \
    node -e '
const fs=require("fs");
const raw=fs.readFileSync("zed/settings.json","utf8");
const o=JSON.parse(raw.replace(/^\s*\/\/.*$/gm,"").replace(/,\s*([}\]])/g,"$1"));
const a=o.agent_servers||{};
const pin="@agentclientprotocol/claude-agent-acp@0.79.0";
const want={"claude-personal":"/Users/talon/.claude","claude-work":"/Users/talon/.claude-work","claude-acp":"/Users/talon/.claude"};
for(const[k,dir]of Object.entries(want)){
  if(!(k in a))process.exit(1);
}
for(const[k,e]of Object.entries(a)){
  if(!k.startsWith("claude"))continue;
  const dir=want[k];
  if(!dir)process.exit(1);
  if(!e||e.type!=="custom")process.exit(1);
  if(e.command!=="/usr/bin/env")process.exit(1);
  const args=e.args||[];
  if(args[0]!=="-u"||args[1]!=="ANTHROPIC_API_KEY"||args[2]!=="npx")process.exit(1);
  if(!args.includes(pin))process.exit(1);
  if(!e.env||e.env.CLAUDE_CONFIG_DIR!==dir)process.exit(1);
  if(Object.prototype.hasOwnProperty.call(e.env,"ANTHROPIC_API_KEY"))process.exit(1);
}
'

assert "link.sh links zed settings" \
    rg -q -F 'ln -sf "$DOTFILEDIR"/zed/settings.json "$HOME/.config/zed/settings.json"' install/macos/link.sh

assert "macOS Brewfile installs zed cask" \
    rg -q 'cask "zed"' install/macos/Brewfile.rb
assert "macOS Brewfile installs node for agent adapters" \
    rg -q 'brew "node"' install/macos/Brewfile.rb

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
