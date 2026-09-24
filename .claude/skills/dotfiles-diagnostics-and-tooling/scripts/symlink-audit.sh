#!/usr/bin/env bash
# symlink-audit.sh - Audit the dotfiles symlink map, then scan for orphaned links.
#
# Pass 1 walks the expected map, a transcription of what install/<platform>/link.sh
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
# Pass 2 scans fixed dirs for symlinks outside the map whose literal target lies
# inside a dotfiles checkout ($DOTFILES plus each --root):
#   ORPHAN-DANGLING  target missing, in any scanned dir
#   ORPHAN-LIVE      target exists and the link sits in an installer-owned dir
#   UNOWNED-LIVE     target exists in a shared dir; [INFO] only, never a failure
#   INCOMPLETE       a scan could not finish, so the clean verdict is withheld
#
# Read-only: never modifies anything. Exit 1 on any non-OK entry, orphan link or
# scan error; exit 2 on usage errors.
#
# Usage: symlink-audit.sh [--cloud] [--root PATH]... [--list-expected]
#   --cloud          partial cloud layout: only ~/.claude (what bootstrap-cloud.sh creates)
#   --root PATH      also treat PATH as a dotfiles checkout (repeatable; may no longer exist)
#   --list-expected  print the map as tab-separated rows and exit
# Env:   DOTFILES=/path/to/checkout  override repo-root autodetection

set -u

TAB=$'\t'
NL=$'\n'

CLOUD=0
LIST=0
EXTRA_ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cloud) CLOUD=1 ;;
    --list-expected) LIST=1 ;;
    --root)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--root needs a path" >&2
        exit 2
      fi
      case "$2" in
        /*) EXTRA_ROOTS+=("$2") ;;
        *) EXTRA_ROOTS+=("$PWD/$2") ;;
      esac
      shift
      ;;
    *) echo "Unknown argument: $1 (supported: --cloud, --root PATH, --list-expected)" >&2; exit 2 ;;
  esac
  shift
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

# Newline-delimited map paths; the orphan scan skips them.
EXPECTED="$NL"
while IFS="$TAB" read -r kind path target; do
  case "$kind" in
    section) echo; echo "--- $path ---" ;;
    link) EXPECTED="$EXPECTED$path$NL"; check_link "$path" "$target" ;;
    machine-local) EXPECTED="$EXPECTED$path$NL"; check_machine_local "$path" ;;
  esac
done < <(emit_map)

ORPHANS=0
SCAN_ERRORS=0
FOREIGN=0

# Installer-owned dirs: the architecture contract makes the installer the only
# sanctioned writer of dotfiles links here, so an unmapped live link is stale.
# Every other scanned dir is shared with other tools and the user.
if [ "$CLOUD" -eq 1 ]; then
  OWNED="$NL$HOME/.claude$NL"
else
  OWNED="$NL$HOME/.claude$NL$HOME/.claude-work$NL$HOME/.codex/hooks$NL$HOME/.codex/skills$NL$HOME/.codex/rules$NL"
fi

# Scan table: dir<TAB>depth. No dir lies within another's depth.
emit_scan_table() {
  if [ "$CLOUD" -eq 1 ]; then
    printf '%s\t2\n' "$HOME/.claude"
    return
  fi
  printf '%s\t1\n' "$HOME" "$HOME/bin" "$HOME/.ssh" "$HOME/.local/bin"
  printf '%s\t3\n' "$HOME/.config"
  printf '%s\t2\n' "$HOME/.codex" "$HOME/.claude" "$HOME/.claude-work"
  if [ "$IS_DARWIN" -eq 1 ]; then
    printf '%s\t1\n' "$HOME/Library/Application Support/Code/User"
  fi
}

# Lexically normalize an absolute path: drop "." and empty parts, apply "..".
lexnorm() {
  local part out="" IFS=/
  set -f
  for part in $1; do
    case "$part" in
      '' | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  set +f
  printf '%s\n' "${out:-/}"
}

# Deepest existing directory on an absolute path. A dir that cannot be searched
# hides everything below it, so the walk stops there.
existing_dir() {
  local head="$1"
  while [ "$head" != / ] && [ ! -d "$head" ]; do
    head="${head%/*}"
    [ -n "$head" ] || head=/
  done
  printf '%s\n' "$head"
}

# Replace the deepest existing ancestor dir of an absolute path with its
# physical path (/var vs /private/var, a symlinked ~/Git). Works for paths
# that no longer exist, such as a deleted checkout.
phys_prefix() {
  local head real
  head="$(existing_dir "$1")"
  if [ "$head" = / ] || ! real="$(cd -P "$head" 2>/dev/null && pwd)"; then
    printf '%s\n' "$1"
    return
  fi
  printf '%s%s\n' "$real" "${1#"$head"}"
}

# Root forms: the given path and its physical form, each paired with the root
# as reported. Arrays, not here-documents: bash 3.2 backs a here-document with a
# temp file, and a failed one would silently empty the loop.
ROOT_FORM=()
ROOT_SHOWN=()
add_root() {
  local given phys
  given="$(lexnorm "$1")"
  echo "[INFO] checkout root: $given"
  ROOT_FORM+=("$given")
  ROOT_SHOWN+=("$given")
  phys="$(phys_prefix "$given")"
  if [ "$phys" != "$given" ]; then
    ROOT_FORM+=("$phys")
    ROOT_SHOWN+=("$given")
  fi
}

# Print the root strictly containing $1 on a path-component boundary; a target
# equal to a root is a checkout alias, not inside it. Longest form wins.
root_of() {
  local path="$1" form best="" best_len=0 i=0
  while [ "$i" -lt "${#ROOT_FORM[@]}" ]; do
    form="${ROOT_FORM[$i]}"
    case "$path" in
      "$form"/?*)
        if [ "${#form}" -gt "$best_len" ]; then
          best="${ROOT_SHOWN[$i]}"
          best_len="${#form}"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$best"
}

incomplete() {
  printf '[X]  INCOMPLETE      %s (%s)\n' "$1" "$2"
  SCAN_ERRORS=$((SCAN_ERRORS + 1))
}

# For a path [ -e ] cannot reach: print nothing when its absence is proven,
# else the path that blocks the proof. Pass the uncollapsed path: the kernel
# must search "locked" in "locked/../x" even though lexnorm drops it. [ -e ] is also false on a permission
# error or a broken symlink along the way, so the deepest entry that does exist
# decides: a searchable dir or a non-directory proves absence; an unsearchable
# dir or an unresolvable symlink does not.
absence_blocker() {
  local p="$1"
  while [ "$p" != / ] && [ ! -e "$p" ] && [ ! -L "$p" ]; do
    p="${p%/*}"
    [ -n "$p" ] || p=/
  done
  if [ -d "$p" ]; then
    [ -x "$p" ] || printf '%s\n' "$p"
  elif [ -L "$p" ]; then
    printf '%s\n' "$p"
  fi
}

classify() {
  local link="$1" literal parent raw abs root blocker
  case "$EXPECTED" in *"$NL$link$NL"*) return ;; esac
  if ! literal="$(readlink "$link")"; then
    incomplete "$link" "readlink failed"
    return
  fi
  case "$literal" in
    /*) raw="$literal" ;;
    *)
      if ! parent="$(cd -P "${link%/*}" 2>/dev/null && pwd)"; then
        incomplete "$link" "cannot resolve its parent dir"
        return
      fi
      raw="$parent/$literal"
      ;;
  esac
  abs="$(lexnorm "$raw")"
  root="$(root_of "$abs")"
  # Resolve the parent only: following the leaf would adopt a foreign link that
  # itself points into a checkout.
  [ -n "$root" ] || root="$(root_of "$(phys_prefix "${abs%/*}")/${abs##*/}")"
  if [ -z "$root" ]; then
    FOREIGN=$((FOREIGN + 1))
  elif [ ! -e "$link" ] && blocker="$(absence_blocker "$raw")" && [ -n "$blocker" ]; then
    incomplete "$link" "cannot confirm the target is missing: $blocker"
  elif [ ! -e "$link" ]; then
    printf '[X]  ORPHAN-DANGLING %s -> %s (missing inside checkout %s)\n' "$link" "$literal" "$root"
    ORPHANS=$((ORPHANS + 1))
  else
    case "$OWNED" in
      *"$NL${link%/*}$NL"*)
        printf '[X]  ORPHAN-LIVE     %s -> %s (inside checkout %s; not in the installer map)\n' \
          "$link" "$literal" "$root"
        ORPHANS=$((ORPHANS + 1))
        ;;
      *)
        printf '[INFO] UNOWNED-LIVE  %s -> %s (inside checkout %s; shared dir, not judged)\n' \
          "$link" "$literal" "$root"
        ;;
    esac
  fi
}

# The enumeration subshell ends its NUL stream with one FINDRC=<status> record.
# bash 3.2 exposes no process-substitution status, so a stream without exactly
# one numeric record means find failed or the subshell died mid-scan.
scan_dir() {
  local dir="$1" depth="$2" rec rc="" blocker
  if [ -L "$dir" ]; then
    incomplete "$dir" "scan dir is a symlink, not followed"
    return
  fi
  if [ ! -d "$dir" ]; then
    blocker="$(absence_blocker "$dir")"
    [ -z "$blocker" ] || incomplete "$dir" "cannot confirm the scan dir is absent: $blocker"
    return
  fi
  while IFS= read -r -d '' rec; do
    case "$rec" in
      FINDRC=*)
        if [ -n "$rc" ]; then
          rc=dup
        else
          rc="${rec#FINDRC=}"
          [ -n "$rc" ] || rc=bad
        fi
        ;;
      *)
        [ -z "$rc" ] || rc=dup
        classify "$rec"
        ;;
    esac
  done < <(find -P "$dir" -mindepth 1 -maxdepth "$depth" -type l -print0 2>/dev/null; printf 'FINDRC=%s\0' "$?")
  case "$rc" in
    0) ;;
    '') incomplete "$dir" "enumeration ended without a completion record" ;;
    dup) incomplete "$dir" "records after the completion record" ;;
    *[!0-9]*) incomplete "$dir" "malformed completion record" ;;
    *) incomplete "$dir" "find exited $rc" ;;
  esac
}

echo
echo "--- orphan scan ---"
add_root "$DOTFILES"
i=0
while [ "$i" -lt "${#EXTRA_ROOTS[@]}" ]; do
  add_root "${EXTRA_ROOTS[$i]}"
  i=$((i + 1))
done
while IFS="$TAB" read -r dir depth; do
  scan_dir "$dir" "$depth"
done < <(emit_scan_table)
echo "[INFO] $FOREIGN symlink(s) outside dotfiles checkouts ignored"

echo
if [ "$BAD" -eq 0 ] && [ "$ORPHANS" -eq 0 ] && [ "$SCAN_ERRORS" -eq 0 ]; then
  printf 'symlink-audit: all %d entries OK, no orphan links.\n' "$TOTAL"
  exit 0
fi
printf 'symlink-audit: %d of %d entries NOT OK, %d orphan link(s), %d scan error(s).\n' \
  "$BAD" "$TOTAL" "$ORPHANS" "$SCAN_ERRORS"
exit 1
