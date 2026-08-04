#!/usr/bin/env bash
# codex-plugin-dedupe.sh - Disable duplicate Codex workflow plugin providers
#
# The dotfiles-workflows marketplace copies of ECC and Superpowers are
# canonical for Codex; when one is enabled, its upstream/account-provisioned
# duplicate entries in ~/.codex/config.toml are flipped to enabled = false.
# Function definitions only -- callers invoke dedupe_codex_workflow_plugins.
#
# Sourced twice per install/update cycle:
#   - install/common/link.sh (link time, steady-state self-heal)
#   - install/common/claude-plugins.sh (post-install, so a first install that
#     just enabled the dotfiles-workflows providers dedupes in the same cycle
#     instead of waiting for the next update)

codex_plugin_enabled() {
  local config="$1"
  local plugin="$2"

  awk -v plugin="$plugin" '
    function clean(line) {
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      return line
    }
    {
      line = clean($0)
      if (line == "[plugins.\"" plugin "\"]") {
        in_plugin = 1
        next
      }
      if (in_plugin && line ~ /^\[/) {
        in_plugin = 0
      }
      if (in_plugin && line ~ /^enabled[[:space:]]*=[[:space:]]*true$/) {
        found = 1
      }
    }
    END {
      exit found ? 0 : 1
    }
  ' "$config"
}

disable_codex_plugin() {
  local config="$1"
  local plugin="$2"
  local tmp="$config.tmp.$$"

  codex_plugin_enabled "$config" "$plugin" || return 0
  cp -p "$config" "$tmp" || return 1

  if ! awk -v plugin="$plugin" '
    function clean(line) {
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      return line
    }
    {
      normalized = clean($0)
      if (normalized == "[plugins.\"" plugin "\"]") {
        in_plugin = 1
      } else if (in_plugin && normalized ~ /^\[/) {
        in_plugin = 0
      }
      if (in_plugin && normalized ~ /^enabled[[:space:]]*=[[:space:]]*true$/) {
        code = $0
        comment = ""
        hash = index(code, "#")
        if (hash) {
          comment = substr(code, hash)
          code = substr(code, 1, hash - 1)
        }
        sub(/true[[:space:]]*$/, "false", code)
        print code (comment == "" ? "" : " " comment)
        next
      }
      print
    }
  ' "$config" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$config"
}

dedupe_codex_workflow_plugins() {
  local config="$HOME/.codex/config.toml"

  [ -f "$config" ] || return 0

  if codex_plugin_enabled "$config" "ecc@dotfiles-workflows"; then
    disable_codex_plugin "$config" "ecc@ecc"
  fi

  if codex_plugin_enabled "$config" "superpowers@dotfiles-workflows"; then
    disable_codex_plugin "$config" "superpowers@openai-curated"
    disable_codex_plugin "$config" "superpowers@claude-plugins-official"
  fi
}
