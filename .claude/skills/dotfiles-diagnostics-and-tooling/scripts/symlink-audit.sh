#!/usr/bin/env bash
# symlink-audit.sh - Walk the expected dotfiles symlink map and report state.
#
# The expected map is transcribed from install/common/link.sh and
# install/common/claude-links.sh (link_claude_config_dir). Per entry, reports:
#   OK            symlink present, resolves, points at the expected target
#   WRONG-TARGET  symlink resolves but points somewhere else
#   DANGLING      symlink whose target does not exist
#   NOT-A-LINK    a real file/dir sits where a symlink belongs
#   MISSING       nothing at the path
# Machine-local files (settings.json, ~/.gitconfig-work) are checked inversely:
# they must be REAL files, never symlinks (installers write through symlinks
# into the repo -- the corruption claude-links.sh guards against).
#
# Read-only: never modifies anything. Exit 1 on any non-OK entry.
#
# Usage: symlink-audit.sh            full machine layout (link.sh scope)
#        symlink-audit.sh --cloud    partial cloud layout: only ~/.claude
#                                    (what bootstrap-cloud.sh creates)
# Env:   DOTFILES=/path/to/checkout  override repo-root autodetection

set -u

CLOUD=0
for arg in "$@"; do
  case "$arg" in
    --cloud) CLOUD=1 ;;
    *) echo "Unknown argument: $arg (supported: --cloud)" >&2; exit 2 ;;
  esac
done

# Repo root: this script lives at <root>/.claude/skills/<skill>/scripts/.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DOTFILES="${DOTFILES:-$(cd -P "$SCRIPT_DIR/../../../.." >/dev/null 2>&1 && pwd)}"
if [ ! -f "$DOTFILES/install/common/link.sh" ]; then
  echo "[X] Cannot locate dotfiles root (tried $DOTFILES). Set DOTFILES=/path/to/checkout." >&2
  exit 2
fi

BAD=0
TOTAL=0

# Physically resolve a path's PARENT (the leaf may not exist), so string
# comparison survives symlinked intermediate dirs.
norm() {
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  if d="$(cd -P "$d" 2>/dev/null && pwd)"; then
    printf '%s/%s\n' "$d" "$b"
  else
    printf '%s\n' "$1"
  fi
}

# check_link <link-path> <expected-target>
check_link() {
  local path="$1" expected="$2" target
  TOTAL=$((TOTAL + 1))
  if [ -L "$path" ]; then
    target="$(readlink "$path")"
    if [ ! -e "$path" ]; then
      printf '[X]  DANGLING      %s -> %s\n' "$path" "$target"; BAD=$((BAD + 1))
    elif [ "$(norm "$target")" = "$(norm "$expected")" ]; then
      printf '[OK] OK            %s\n' "$path"
    else
      printf '[X]  WRONG-TARGET  %s -> %s (expected %s)\n' "$path" "$target" "$expected"
      BAD=$((BAD + 1))
    fi
  elif [ -e "$path" ]; then
    printf '[X]  NOT-A-LINK    %s (real file/dir; expected symlink -> %s)\n' "$path" "$expected"
    BAD=$((BAD + 1))
  else
    printf '[X]  MISSING       %s (expected symlink -> %s)\n' "$path" "$expected"
    BAD=$((BAD + 1))
  fi
}

# check_machine_local <path>  -- must be a REAL file, never a symlink
check_machine_local() {
  local path="$1"
  TOTAL=$((TOTAL + 1))
  if [ -L "$path" ]; then
    printf '[X]  IS-A-LINK     %s -> %s (must be machine-local; installers write through symlinks into the repo)\n' \
      "$path" "$(readlink "$path")"
    BAD=$((BAD + 1))
  elif [ -f "$path" ]; then
    printf '[OK] OK            %s (machine-local file)\n' "$path"
  else
    printf '[X]  MISSING       %s (machine-local file never seeded)\n' "$path"
    BAD=$((BAD + 1))
  fi
}

# One Claude config dir (claude-links.sh link_claude_config_dir).
audit_claude_dir() {
  local cdir="$1" name
  echo
  echo "--- claude config dir: $cdir ---"
  for name in CLAUDE.md operating-principles.md commands agents hooks skills rules statusline.js; do
    check_link "$cdir/$name" "$DOTFILES/claude/$name"
  done
  check_machine_local "$cdir/settings.json"
}

echo "symlink-audit: dotfiles root = $DOTFILES  (mode: $([ "$CLOUD" -eq 1 ] && echo cloud || echo full))"

if [ "$CLOUD" -eq 1 ]; then
  # Cloud containers get only the personal Claude layer (bootstrap-cloud.sh).
  audit_claude_dir "$HOME/.claude"
else
  echo
  echo "--- zsh ---"
  check_link "$HOME/.zprofile"                "$DOTFILES/zsh/.zprofile"
  check_link "$HOME/.zshrc"                   "$DOTFILES/zsh/.zshrc"
  check_link "$HOME/.config/.aliases.zsh"     "$DOTFILES/zsh/aliases.zsh"
  check_link "$HOME/.config/.functions.zsh"   "$DOTFILES/zsh/functions.zsh"
  check_link "$HOME/.config/.trippy.toml"     "$DOTFILES/zsh/.trippy.toml"

  echo
  echo "--- git ---"
  check_link "$HOME/.gitconfig"               "$DOTFILES/git/.gitconfig"
  check_link "$HOME/.stCommitMsg"             "$DOTFILES/git/.stCommitMsg"
  check_link "$HOME/.gitignore_global"        "$DOTFILES/git/.gitignore_global"
  check_link "$HOME/.gitconfig-personal"      "$DOTFILES/git/personal/.gitconfig-personal"
  check_link "$HOME/.config/git/hooks"        "$DOTFILES/git/hooks"
  check_machine_local "$HOME/.gitconfig-work"

  echo
  echo "--- ssh ---"
  check_link "$HOME/.ssh/config"                    "$DOTFILES/ssh/configs/config"
  check_link "$HOME/.ssh/config_personal"           "$DOTFILES/ssh/configs/personal/config_personal"
  check_link "$HOME/.ssh/config_work"               "$DOTFILES/ssh/configs/work/config_work"
  check_link "$HOME/.ssh/id_ed25519_personal.pub"   "$DOTFILES/ssh/keys/id_ed25519_personal.pub"

  audit_claude_dir "$HOME/.claude"
  audit_claude_dir "$HOME/.claude-work"

  echo
  echo "--- bin ---"
  for name in dotfiles-repair setup-claude identity-setup identity-doctor dotfiles-tests; do
    check_link "$HOME/bin/$name" "$DOTFILES/bin/$name"
  done

  echo
  echo "--- ghostty ---"
  check_link "$HOME/.config/ghostty/config" "$DOTFILES/ghostty/config"

  echo
  echo "--- codex ---"
  check_link "$HOME/.codex/AGENTS.md" "$DOTFILES/codex/AGENTS.md"
  for name in no_ai_attribution_bash.py block_secrets.py emoji_guard.py no_ai_comments.py; do
    check_link "$HOME/.codex/hooks/$name" "$DOTFILES/codex/hooks/$name"
  done
  # Repo-managed Codex bridge skills (link.sh loops over codex/skills/*/).
  if [ -d "$DOTFILES/codex/skills" ]; then
    for skill_dir in "$DOTFILES"/codex/skills/*/; do
      [ -d "$skill_dir" ] || continue
      check_link "$HOME/.codex/skills/$(basename "$skill_dir")" "${skill_dir%/}"
    done
  fi
fi

echo
if [ "$BAD" -ne 0 ]; then
  printf 'symlink-audit: %d of %d entries NOT OK.\n' "$BAD" "$TOTAL"
  exit 1
fi
printf 'symlink-audit: all %d entries OK.\n' "$TOTAL"
