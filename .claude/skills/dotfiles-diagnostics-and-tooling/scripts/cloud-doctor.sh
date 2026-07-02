#!/usr/bin/env bash
# cloud-doctor.sh - Verify a cloud/ephemeral Claude Code session end-to-end.
#
# Checks, in order:
#   1. ~/.claude assets are symlinks resolving into a dotfiles checkout
#      (the layout link_claude_config_dir in install/common/claude-links.sh creates)
#   2. settings.json is a real machine-local file (not a symlink) and registers
#      SessionStart hooks (account_guard.py from claude/settings.json.tmpl)
#   3. Both plugins are recorded in installed_plugins.json (the on-disk ground
#      truth -- `claude plugins install` can exit 0 without writing it)
#   4. git author is a real identity, not the platform default
#      "Claude <noreply@anthropic.com>" that bootstrap-cloud reattributes
#   5. python3 and node are on PATH (hooks and statusline need them at runtime)
#
# Read-only: never modifies anything. Exit 1 if any [X] check fails.
# Respects CLAUDE_CONFIG_DIR; defaults to ~/.claude (cloud containers are
# personal-account only).
#
# Usage: cloud-doctor.sh

set -u

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PLATFORM_DEFAULT_EMAIL="noreply@anthropic.com"
FAILED=0

ok()   { printf '[OK]      %s\n' "$1"; }
warn() { printf '[WARNING] %s\n' "$1"; }
info() { printf '[INFO]    %s\n' "$1"; }
fail() { printf '[X]       %s\n' "$1"; FAILED=1; }
section() { printf '\n--- %s ---\n' "$1"; }

# --- 1. symlinked assets --------------------------------------------------
section "claude assets ($CLAUDE_DIR)"

DOTFILES=""
if [ -L "$CLAUDE_DIR/CLAUDE.md" ] && [ -e "$CLAUDE_DIR/CLAUDE.md" ]; then
  # Derive the dotfiles root from the anchor link: <root>/claude/CLAUDE.md
  DOTFILES="$(dirname "$(dirname "$(readlink "$CLAUDE_DIR/CLAUDE.md")")")"
  if [ -f "$DOTFILES/bootstrap-cloud.sh" ]; then
    ok "CLAUDE.md links into dotfiles checkout at $DOTFILES"
  else
    fail "CLAUDE.md target's repo root ($DOTFILES) has no bootstrap-cloud.sh -- not a dotfiles checkout?"
    DOTFILES=""
  fi
elif [ -L "$CLAUDE_DIR/CLAUDE.md" ]; then
  fail "CLAUDE.md is a DANGLING symlink -> $(readlink "$CLAUDE_DIR/CLAUDE.md") (re-run bootstrap-cloud.sh)"
else
  fail "CLAUDE.md missing or not a symlink at $CLAUDE_DIR/CLAUDE.md (bootstrap-cloud.sh never ran?)"
fi

for name in operating-principles.md commands agents hooks skills rules statusline.js; do
  path="$CLAUDE_DIR/$name"
  if [ -L "$path" ] && [ -e "$path" ]; then
    target="$(readlink "$path")"
    if [ -n "$DOTFILES" ]; then
      case "$target" in
        "$DOTFILES"/claude/*) ok "$name -> $target" ;;
        *) fail "$name links OUTSIDE the dotfiles checkout: $target" ;;
      esac
    else
      warn "$name is a symlink -> $target (cannot validate root; CLAUDE.md check failed)"
    fi
  elif [ -L "$path" ]; then
    fail "$name is a DANGLING symlink -> $(readlink "$path")"
  elif [ -e "$path" ]; then
    fail "$name exists but is NOT a symlink (real dir shadows the dotfiles asset; re-run bootstrap-cloud.sh)"
  else
    fail "$name missing (re-run bootstrap-cloud.sh)"
  fi
done

# --- 2. settings.json -----------------------------------------------------
section "settings.json"

SETTINGS="$CLAUDE_DIR/settings.json"
if [ -L "$SETTINGS" ]; then
  fail "settings.json is a symlink -- must be machine-local (installers write to it; see claude-links.sh)"
elif [ ! -f "$SETTINGS" ]; then
  fail "settings.json missing (bootstrap-cloud reconcile never ran)"
elif command -v python3 >/dev/null 2>&1; then
  hook_out="$(python3 - "$SETTINGS" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
except (json.JSONDecodeError, OSError) as exc:
    print(f"UNPARSEABLE: {exc}")
    sys.exit(0)
groups = cfg.get("hooks", {}).get("SessionStart", [])
cmds = [os.path.basename(h.get("command", ""))
        for g in groups for h in g.get("hooks", [])]
print(",".join(c for c in cmds if c))
PY
)"
  case "$hook_out" in
    UNPARSEABLE:*) fail "settings.json is not valid JSON ($hook_out)" ;;
    *account_guard.py*) ok "SessionStart hooks registered: $hook_out" ;;
    "") fail "no SessionStart hooks in settings.json (template never reconciled; run bootstrap-cloud.sh)" ;;
    *) fail "SessionStart hooks present ($hook_out) but account_guard.py missing (partial reconcile)" ;;
  esac
else
  if grep -q '"SessionStart"' "$SETTINGS"; then
    warn "SessionStart key present (python3 unavailable; hook list not validated)"
  else
    fail "no SessionStart hooks in settings.json"
  fi
fi

# --- 3. plugins -----------------------------------------------------------
section "plugins"

IPJ="$CLAUDE_DIR/plugins/installed_plugins.json"
if [ ! -f "$IPJ" ]; then
  fail "installed_plugins.json missing at $IPJ -- NO plugins are installed"
else
  for plugin_id in "ecc@ecc" "superpowers@claude-plugins-official"; do
    if grep -q "$plugin_id" "$IPJ"; then
      ok "$plugin_id recorded in installed_plugins.json"
    else
      fail "$plugin_id NOT in installed_plugins.json (recover: claude plugins install $plugin_id)"
    fi
  done
fi

# --- 4. git identity ------------------------------------------------------
section "git identity"

if command -v git >/dev/null 2>&1; then
  email="$(git config --global user.email 2>/dev/null || true)"
  name="$(git config --global user.name 2>/dev/null || true)"
  if [ -z "$email" ]; then
    fail "no global user.email set (bootstrap-cloud reattribute_git_identity never ran)"
  elif [ "$email" = "$PLATFORM_DEFAULT_EMAIL" ]; then
    fail "git author is still the platform default ($name <$email>) -- commits would be misattributed"
  else
    ok "git author: $name <$email>"
  fi
else
  fail "git not on PATH"
fi

# --- 5. runtimes ----------------------------------------------------------
section "runtimes"

command -v python3 >/dev/null 2>&1 \
  && ok "python3 on PATH ($(command -v python3))" \
  || fail "python3 missing -- guard/SessionStart hooks will not run"
command -v node >/dev/null 2>&1 \
  && ok "node on PATH ($(command -v node))" \
  || fail "node missing -- statusline will not render"

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf 'cloud-doctor: FAILURES found -- see [X] lines above.\n'
  exit 1
fi
printf 'cloud-doctor: all checks passed.\n'
