###############################
#  Taps                       #
###############################

# none!

###############################
#  Utilities                  #
###############################

brew "coreutils"
brew "mas"          # Mac App Store CLI
brew "fzf"
brew "ripgrep"
brew "lazygit"
brew "pipx"
brew "blueutil"
brew "uv"           # Modern Python package and project manager (replaces pyenv, pip, pip-tools)
cask "font-fira-code"
cask "font-jetbrains-mono"
# AI tools
cask "claude" unless system("test -e /Applications/Claude.app")
# Claude Code CLI installed via native installer (see install/common/claude-code.sh)
# Codex CLI installed via OpenAI's official installer (see install/common/codex.sh)

###############################
#  macOS Apps via Cask        #
###############################

# cask list: https://formulae.brew.sh/cask/

cask_args appdir: "/Applications"

# social
cask "discord" unless system("test -e /Applications/Discord.app")
cask "slack" unless system("test -e /Applications/Slack.app")
cask "whatsapp" unless system("test -e /Applications/WhatsApp.app")

# music 
cask "spotify" unless system("test -e /Applications/Spotify.app")

# terminal
cask "ghostty" unless system("test -e /Applications/Ghostty.app")

# development
cask "sourcetree" unless system("test -e /Applications/Sourcetree.app")
cask "sublime-text" unless system("test -e \"/Applications/Sublime Text.app\"")
cask "visual-studio-code" unless system("test -e \"/Applications/Visual Studio Code.app\"")

# utilities
cask "appcleaner" unless system("test -e /Applications/AppCleaner.app")
cask "protonvpn" unless system("test -e /Applications/ProtonVPN.app")
cask "proton-mail" unless system("test -e \"/Applications/Proton Mail.app\"")
cask "proton-drive" unless system("test -e \"/Applications/Proton Drive.app\"")
cask "dropbox" unless system("test -e /Applications/Dropbox.app")
cask "1password" unless system("test -e /Applications/1Password.app")
cask "cryptomator" unless system("test -e /Applications/Cryptomator.app")
cask "raycast" unless system("test -e /Applications/Raycast.app")
# cask "monarch" unless system("test -e /Applications/Monarch.app")
cask "alt-tab" unless system("test -e /Applications/AltTab.app")
cask "bartender" unless system("test -e \"/Applications/Bartender 5.app\"")
cask "cleanshot" unless system("test -e \"/Applications/CleanShot X.app\"")
cask "itsycal" unless system("test -e \"/Applications/Itsycal.app\"")
cask "bettertouchtool" unless system("test -e /Applications/BetterTouchTool.app")
cask "adguard" unless system("test -e /Applications/AdGuard.app")

# productivity
cask "reminders-menubar" unless system("test -e \"/Applications/Reminders MenuBar.app\"")
cask "fantastical" unless system("test -e /Applications/Fantastical.app")
cask "cardhop" unless system("test -e /Applications/Cardhop.app")
cask "microsoft-word" unless system("test -e \"/Applications/Microsoft Word.app\"")
cask "microsoft-excel" unless system("test -e \"/Applications/Microsoft Excel.app\"")
cask "microsoft-powerpoint" unless system("test -e \"/Applications/Microsoft PowerPoint.app\"")


# browser
cask "firefox" unless system("test -e /Applications/Firefox.app")

###############################
#  macOS Utilities via Cask   #
###############################

cask "1password-cli"
cask "miniconda"
cask "docker"
# https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/warp-to-warp/
cask "cloudflare-warp" 


###############################
#  macOS Apps via App Store   #
###############################

# to see existing macOS apps, run $ mas list

# Apple
# mas "Xcode", id: 497799835

# Third Party
mas "Magnet", id: 441258766
mas "Things", id: 904280696
mas "Dropover", id: 1355679052