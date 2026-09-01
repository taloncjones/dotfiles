#!/usr/bin/env bash
# zshenv-migrate.sh - move a machine-local ~/.zshenv aside before link.sh
# replaces it with the tracked symlink. Kept as a function in its own file so
# the test suite can exercise it against a sandbox HOME. Non-destructive and
# idempotent: existing content is moved, never overwritten or deleted.

# migrate_home_zshenv <home> <repo_zshenv_path>
# Returns 0 when the caller may create the ~/.zshenv symlink, 1 to skip.
migrate_home_zshenv() {
  local home="$1" repo_zshenv="$2"
  local target="$home/.zshenv"
  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" != "$repo_zshenv" ]; then
      echo "NOTICE: replacing ~/.zshenv symlink (old target: $(readlink "$target"))"
    fi
    return 0
  fi
  if [ ! -e "$target" ]; then
    return 0
  fi
  if [ -f "$target" ]; then
    # -e misses a dangling ~/.zshenv.local symlink; treat any existing
    # entry (including broken links) as occupied -- never overwrite.
    if [ ! -e "$home/.zshenv.local" ] && [ ! -L "$home/.zshenv.local" ]; then
      mv "$target" "$home/.zshenv.local"
      echo "NOTICE: moved machine-local ~/.zshenv to ~/.zshenv.local (sourced by the tracked .zshenv)"
    else
      local bak="$home/.zshenv.dotfiles-bak.$(date +%s)" n=0
      while [ -e "$bak" ] || [ -L "$bak" ]; do
        n=$((n + 1))
        bak="$home/.zshenv.dotfiles-bak.$(date +%s).$n"
      done
      mv "$target" "$bak"
      echo "NOTICE: ~/.zshenv.local already exists; moved old ~/.zshenv to $bak -- its content no longer executes, merge it into ~/.zshenv.local manually"
    fi
    return 0
  fi
  echo "ERROR: ~/.zshenv is neither a regular file nor a symlink; skipping the .zshenv link (fix manually; symlink-audit will flag it)" >&2
  return 1
}
