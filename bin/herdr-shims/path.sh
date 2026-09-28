# Keep the herdr gh shim first on PATH. POSIX sh; zsh sources it unchanged.
# An armed session is one whose PATH holds a .../bin/herdr-shims dir (the
# only variable Codex's `inherit = "core"` keeps). Sourced at the end of
# zsh/.zprofile and zsh/.zshrc, and via BASH_ENV in every bash, because
# login shells re-derive PATH (path_helper, brew shellenv) and would put the
# real gh first. Unarmed, it changes nothing.
_dotfiles_gh_anchor_rest="${PATH:-}:"
_dotfiles_gh_anchor_dir=
while [ -n "$_dotfiles_gh_anchor_rest" ]; do
    _dotfiles_gh_anchor_entry="${_dotfiles_gh_anchor_rest%%:*}"
    _dotfiles_gh_anchor_rest="${_dotfiles_gh_anchor_rest#*:}"
    case "$_dotfiles_gh_anchor_entry" in
        */bin/herdr-shims)
            if [ -x "$_dotfiles_gh_anchor_entry/gh" ]; then
                _dotfiles_gh_anchor_dir="$_dotfiles_gh_anchor_entry"
                break
            fi
            ;;
    esac
done
if [ -n "$_dotfiles_gh_anchor_dir" ]; then
    _dotfiles_gh_anchor_rest="${PATH:-}:"
    _dotfiles_gh_anchor_path="$_dotfiles_gh_anchor_dir"
    while [ -n "$_dotfiles_gh_anchor_rest" ]; do
        _dotfiles_gh_anchor_entry="${_dotfiles_gh_anchor_rest%%:*}"
        _dotfiles_gh_anchor_rest="${_dotfiles_gh_anchor_rest#*:}"
        if [ -n "$_dotfiles_gh_anchor_entry" ] && [ "$_dotfiles_gh_anchor_entry" != "$_dotfiles_gh_anchor_dir" ]; then
            _dotfiles_gh_anchor_path="$_dotfiles_gh_anchor_path:$_dotfiles_gh_anchor_entry"
        fi
    done
    PATH="$_dotfiles_gh_anchor_path"
fi
unset _dotfiles_gh_anchor_rest _dotfiles_gh_anchor_dir _dotfiles_gh_anchor_entry _dotfiles_gh_anchor_path
