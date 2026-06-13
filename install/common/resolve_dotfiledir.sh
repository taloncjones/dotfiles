#!/usr/bin/env bash
# resolve_dotfiledir.sh - Resolve the dotfiles repository directory
#
# Sources this file to set DOTFILEDIR to the absolute path of the dotfiles repo.
# Handles symlinks by following them to find the true script location.
#
# Usage: source "$path_to_this_file" "$0" or source with BASH_SOURCE
#
# After sourcing, DOTFILEDIR will be set and exported.

# Allow caller to pass the source file, or use BASH_SOURCE
_resolve_source="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"

# Follow symlinks to find the true location
while [ -h "$_resolve_source" ]; do
  _resolve_dir="$( cd -P "$( dirname "$_resolve_source" )" >/dev/null 2>&1 && pwd )"
  _resolve_source="$(readlink "$_resolve_source")"
  # Handle relative symlinks
  [[ $_resolve_source != /* ]] && _resolve_source="$_resolve_dir/$_resolve_source"
done
_resolve_script_dir="$( cd -P "$( dirname "$_resolve_source" )" >/dev/null 2>&1 && pwd )"

# Navigate up to find DOTFILEDIR based on script location
# Scripts in install/common/ need to go up 2 levels
# Scripts in install/macos/ or install/linux/ need to go up 2 levels
# Scripts in install/ need to go up 1 level
case "$_resolve_script_dir" in
  */install/common|*/install/macos|*/install/linux)
    DOTFILEDIR="$(dirname "$(dirname "$_resolve_script_dir")")"
    ;;
  */install)
    DOTFILEDIR="$(dirname "$_resolve_script_dir")"
    ;;
  *)
    # Default: assume script is at repo root
    DOTFILEDIR="$_resolve_script_dir"
    ;;
esac

export DOTFILEDIR

# Cleanup temporary variables
unset _resolve_source _resolve_dir _resolve_script_dir
