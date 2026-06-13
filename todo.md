# Dotfiles Improvements

Tracked from audit on 2026-05-06. Items are roughly ordered by priority.

## High priority (correctness bugs)

- [x] **Fix typo breaking Intel Mac install** — `install/common/zsh.sh:16` has `/user/local/bin/zsh`; should be `/usr/local/bin/zsh`.
- [x] **Remove hardcoded username from PATH** — `zsh/.zprofile:19` uses a `/Users/<username>/.local/bin` path; replace with `$HOME/.local/bin`.
- [x] **Guard `gh auth token` call** — `zsh/.zprofile:22` runs unconditionally and errors when `gh` isn't installed/authed. Wrap in `command -v gh` check or redirect stderr.
- [x] **Fix `CURRENTSHELL=$(which $SHELL)`** — `install/common/zsh.sh:28`. `$SHELL` is already a path; `which /bin/zsh` is meaningless. Use `CURRENTSHELL="$SHELL"` or `dscl` lookup on macOS.
- [x] **Add `set -euo pipefail`** — `install/install.sh:17` only has `set -e`. Add `-u` and `pipefail` so the `dpkg-query | grep` pipe (line 90) and undefined vars actually fail.
- [x] **apt install loop swallows errors** — `install/install.sh:88-96`. Quote `"$package"` and add `|| exit 1` after `sudo apt install`.
- [x] **Aliases evaluated at source time** — `zsh/aliases.zsh` lines using `alias ls="$(which eza) ..."`. If eza isn't installed yet on first shell load, alias becomes broken. Switch to single-quoted aliases or guard with `command -v eza`.
- [x] **Update oh-my-zsh install URL** — `install/install.sh:59,109` uses `raw.github.com`; switch to `raw.githubusercontent.com`.

## Medium priority (robustness)

- [x] **Don't `rm -rf` real dirs before relinking** — `install/common/link.sh:49` removes `~/.claude/{commands,agents,hooks}` unconditionally. If a later link step fails, data is gone. Only remove if it's a symlink: `[[ -L path ]] && rm path`.
- [x] **Make `setup-claude` idempotent** — `bin/setup-claude` appends to `.git/info/exclude` without dedup. Use `grep -qxF "$line" file || echo "$line" >> file`.
- [x] **Remove machine-specific `safe.directory` entries** — `git/.gitconfig:77-78` hardcodes `/Users/<username>/...` paths. Use `~/Git/*` glob or move to non-symlinked local include.
- [x] **Drop duplicate `compinit`** — `zsh/.zshrc:91-95` calls it twice in the rebuild path.
- [x] **Respect existing `XDG_CONFIG_HOME`** — `zsh/.zshrc:10`. Use `${XDG_CONFIG_HOME:-$HOME/.config}`.

## Low priority (style/consistency)

- [ ] **Replace backticks with `$(...)`** — `zsh/.zprofile`, `install/common/zsh.sh`.
- [ ] **`update()` should propagate failure** — `zsh/functions.zsh`. Add `|| return 1` after `bash $DOTFILEDIR/install/install.sh`.
- [ ] **Document Brewfile split in README** — `install/common/Brewfile.rb` (CLI, all platforms) vs `install/macos/Brewfile.rb` (macOS GUI apps) isn't clearly distinguished.
