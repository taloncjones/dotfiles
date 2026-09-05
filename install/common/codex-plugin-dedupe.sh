#!/usr/bin/env bash
# codex-plugin-dedupe.sh - Disable duplicate Codex workflow plugin providers
#
# The dotfiles-workflows marketplace copies of ECC and Superpowers are
# canonical for Codex; when one is enabled, its upstream/account-provisioned
# duplicate entries in CODEX_HOME/config.toml are flipped to enabled = false.
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
  local codex_surface_home="${CODEX_HOME:-$HOME/.codex}"
  local config="$codex_surface_home/config.toml"

  [ -f "$config" ] || return 0

  if codex_plugin_enabled "$config" "ecc@dotfiles-workflows"; then
    disable_codex_plugin "$config" "ecc@ecc"
  fi

  if codex_plugin_enabled "$config" "superpowers@dotfiles-workflows"; then
    disable_codex_plugin "$config" "superpowers@openai-curated"
    disable_codex_plugin "$config" "superpowers@claude-plugins-official"
  fi

  # Keep repo-owned compatibility repairs in the same install/update lifecycle.
  # Focused discovery is opt-in; the helper remembers a previously adopted
  # catalog and never removes skill files or rewrites Claude configuration.
  local surface_helper="$DOTFILEDIR/install/common/codex-surfaces.py"
  if [ -f "$surface_helper" ]; then
    if command -v uv >/dev/null 2>&1; then
      uv run --python '>=3.11' --no-project --offline --no-cache python \
        "$surface_helper" --codex-home "$codex_surface_home" --apply >/dev/null || return 1
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
      python3 "$surface_helper" --codex-home "$codex_surface_home" --apply >/dev/null || return 1
    else
      echo "[WARNING] Python 3.11+ is required to reconcile Codex plugin surfaces; install a supported Python or uv." >&2
      return 1
    fi
  fi
}
