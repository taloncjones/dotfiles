#!/usr/bin/env bash
# symlink-audit.sh - Audit the dotfiles symlink map, then scan for orphaned links.
#
# Walks the expected map, a transcription of what install/<platform>/link.sh
# writes (install/common/link.sh, link_claude_config_dir, link_codex_surfaces).
# symlink-audit.test.sh runs the real installer into a scratch HOME and fails when
# this transcription drifts. Per entry:
#   OK            symlink present, resolves, points at the expected target
#   WRONG-TARGET  symlink resolves but points somewhere else
#   DANGLING      symlink whose target does not exist
#   NOT-A-LINK    a real file/dir sits where a symlink belongs
#   MISSING       nothing at the path
# Machine-local files (settings.json, ~/.gitconfig-work, ...) are checked inversely:
# they must be REAL files, never symlinks (installers write through symlinks
# into the repo -- the corruption claude-links.sh guards against).
#
# Read-only: never modifies anything. Exit 1 on any non-OK entry; exit 2 on
# usage errors.
#
# Usage: symlink-audit.sh [--cloud] [--list-expected]
#   --cloud          partial cloud layout: only ~/.claude (what bootstrap-cloud.sh creates)
#   --list-expected  print the map as tab-separated rows and exit
# Env:   DOTFILES=/path/to/checkout  override repo-root autodetection

set -u

TAB=$'\t'

CLOUD=0
LIST=0
for arg in "$@"; do
  case "$arg" in
    --cloud) CLOUD=1 ;;
    --list-expected) LIST=1 ;;
    *) echo "Unknown argument: $arg (supported: --cloud, --list-expected)" >&2; exit 2 ;;
  esac
done

# Repo root: this script lives at <root>/.claude/skills/<skill>/scripts/.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DOTFILES="${DOTFILES:-$(cd -P "$SCRIPT_DIR/../../../.." >/dev/null 2>&1 && pwd)}"
if [ ! -f "$DOTFILES/install/common/link.sh" ]; then
  echo "[X] Cannot locate dotfiles root (tried $DOTFILES). Set DOTFILES=/path/to/checkout." >&2
  exit 2
fi

IS_DARWIN=0
[ "$(uname)" = Darwin ] && IS_DARWIN=1

# Map rows: section<TAB>title | link<TAB>path<TAB>target | machine-local<TAB>path
row_section() { printf 'section\t%s\n' "$1"; }
row_link() { printf 'link\t%s\t%s\n' "$1" "$2"; }
row_local() { printf 'machine-local\t%s\n' "$1"; }

# One Claude config dir (link_claude_config_dir in install/common/claude-links.sh).
emit_claude_dir() {
  local cdir="$1" name
  row_section "claude config dir: $cdir"
  for name in CLAUDE.md operating-principles.md commands agents hooks skills rules statusline.js; do
    row_link "$cdir/$name" "$DOTFILES/claude/$name"
  done
  # Local-only audit files: the installer links them only when present.
  for name in Fable5.md Opus4.md; do
    if [ -f "$DOTFILES/claude/$name" ]; then
      row_link "$cdir/$name" "$DOTFILES/claude/$name"
    fi
  done
  row_local "$cdir/settings.json"
}

emit_map() {
  local name skill_dir
  if [ "$CLOUD" -eq 1 ]; then
    # Cloud containers get only the personal Claude layer (bootstrap-cloud.sh).
    emit_claude_dir "$HOME/.claude"
    return
  fi

  row_section "zsh"
  row_link "$HOME/.zprofile" "$DOTFILES/zsh/.zprofile"
  row_link "$HOME/.zshrc" "$DOTFILES/zsh/.zshrc"
  row_link "$HOME/.zshenv" "$DOTFILES/zsh/.zshenv"
  row_link "$HOME/.config/.aliases.zsh" "$DOTFILES/zsh/aliases.zsh"
  row_link "$HOME/.config/.functions.zsh" "$DOTFILES/zsh/functions.zsh"
  row_link "$HOME/.config/.trippy.toml" "$DOTFILES/zsh/.trippy.toml"

  row_section "git"
  row_link "$HOME/.gitconfig" "$DOTFILES/git/.gitconfig"
  row_link "$HOME/.stCommitMsg" "$DOTFILES/git/.stCommitMsg"
  row_link "$HOME/.gitignore_global" "$DOTFILES/git/.gitignore_global"
  row_link "$HOME/.gitconfig-personal" "$DOTFILES/git/personal/.gitconfig-personal"
  row_link "$HOME/.config/git/hooks" "$DOTFILES/git/hooks"
  row_local "$HOME/.gitconfig-work"

  row_section "ssh"
  row_link "$HOME/.ssh/config" "$DOTFILES/ssh/configs/config"
  row_link "$HOME/.ssh/config_personal" "$DOTFILES/ssh/configs/personal/config_personal"
  row_link "$HOME/.ssh/config_work" "$DOTFILES/ssh/configs/work/config_work"
  row_link "$HOME/.ssh/id_ed25519_personal.pub" "$DOTFILES/ssh/keys/id_ed25519_personal.pub"
  row_local "$HOME/.ssh/config_cloudflared"
  row_local "$HOME/.config/1Password/ssh/agent.toml"

  emit_claude_dir "$HOME/.claude"
  emit_claude_dir "$HOME/.claude-work"

  row_section "bin"
  for name in dotfiles-repair setup-claude identity-setup identity-doctor \
    remote-access-doctor zed-claude-agent herdr-zed-attach dotfiles-tests; do
    row_link "$HOME/bin/$name" "$DOTFILES/bin/$name"
  done

  row_section "ghostty"
  row_link "$HOME/.config/ghostty/config" "$DOTFILES/ghostty/config"

  # link_codex_surfaces in install/common/codex-links.sh.
  row_section "codex"
  row_link "$HOME/.codex/AGENTS.md" "$DOTFILES/codex/AGENTS.md"
  for name in no_ai_attribution_bash.py block_secrets.py emoji_guard.py no_ai_comments.py \
    herdr_stop_gate.py orch_edit_guard.py; do
    row_link "$HOME/.codex/hooks/$name" "$DOTFILES/codex/hooks/$name"
  done
  for name in herdr_worktree_guard.py rm_guard.py git_remote_guard.py planning_artifact_guard.py; do
    row_link "$HOME/.codex/hooks/$name" "$DOTFILES/claude/hooks/$name"
  done
  for name in repo-recall post-merge todos handoff kickoff voice brainstorming writing-specs writing-plans; do
    row_link "$HOME/.codex/skills/$name" "$DOTFILES/claude/skills/$name"
  done
  if [ -d "$DOTFILES/codex/skills" ]; then
    for skill_dir in "$DOTFILES"/codex/skills/*/; do
      [ -d "$skill_dir" ] || continue
      row_link "$HOME/.codex/skills/$(basename "$skill_dir")" "${skill_dir%/}"
    done
  fi
  row_link "$HOME/.codex/rules/agent-lessons.md" "$DOTFILES/claude/rules/personal/agent-lessons.md"

  if [ "$IS_DARWIN" -eq 1 ]; then
    # install/macos/link.sh.
    row_section "macos apps"
    for name in settings.json keybindings.json welcomePage.js; do
      row_link "$HOME/Library/Application Support/Code/User/$name" "$DOTFILES/vscode/$name"
    done
    row_link "$HOME/.config/zed/settings.json" "$DOTFILES/zed/settings.json"
  fi
}

if [ "$LIST" -eq 1 ]; then
  emit_map | grep -v "^section$TAB"
  exit 0
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

echo "symlink-audit: dotfiles root = $DOTFILES  (mode: $([ "$CLOUD" -eq 1 ] && echo cloud || echo full))"

while IFS="$TAB" read -r kind path target; do
  case "$kind" in
    section) echo; echo "--- $path ---" ;;
    link) check_link "$path" "$target" ;;
    machine-local) check_machine_local "$path" ;;
  esac
done < <(emit_map)

echo
if [ "$BAD" -ne 0 ]; then
  printf 'symlink-audit: %d of %d entries NOT OK.\n' "$BAD" "$TOTAL"
  exit 1
fi
printf 'symlink-audit: all %d entries OK.\n' "$TOTAL"
