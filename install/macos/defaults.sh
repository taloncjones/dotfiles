#!/usr/bin/env bash
# defaults.sh - Apply macOS system preferences
#
# Sets Finder, Dock, and security preferences. Disables unwanted system agents.
# Some changes require logout/restart to take effect.

# Disable a launch agent by renaming its bundle to prevent loading on next boot.
# Uses sudo as fallback for system agents.
disable_agent() {
    if [ -e "$1" ]; then
	    mv "$1" "$1_DISABLED" >/dev/null 2>&1 || sudo mv "$1" "$1_DISABLED" >/dev/null 2>&1
    fi
}

# Immediately unload a running launch agent from launchd.
unload_agent() {
	launchctl unload -w "$1" >/dev/null 2>&1
}

# Quit System Preferences.app if open
osascript -e 'tell application "System Preferences" to quit'

echo "Setting macOS defaults and preferences..."

# General

# Require password immediately after sleep or screen saver begins
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0

# Automatically hide and show the dock
defaults write com.apple.dock autohide -bool true

# Set dock icon size to 45px
defaults write com.apple.dock tilesize -int 45

# Require password immediately after sleep or screen saver begins
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0

# Finder: show all filename extensions
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Disable the warning when changing a file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Stop photos from opening every time a device is plugged in
defaults -currentHost write com.apple.ImageCapture disableHotPlug -bool true

# Enable snap-to-grid for icons on the desktop and in other icon views
/usr/libexec/PlistBuddy -c "Set :DesktopViewSettings:IconViewSettings:arrangeBy grid" ~/Library/Preferences/com.apple.finder.plist
/usr/libexec/PlistBuddy -c "Set :FK_StandardViewSettings:IconViewSettings:arrangeBy grid" ~/Library/Preferences/com.apple.finder.plist
/usr/libexec/PlistBuddy -c "Set :StandardViewSettings:IconViewSettings:arrangeBy grid" ~/Library/Preferences/com.apple.finder.plist

# Always open everything in Finder's column view.
# Use list view in all Finder windows by default
# Four-letter codes for the other view modes: `icnv`, `clmv`, `Flwv`
defaults write com.apple.finder FXPreferredViewStyle -string "clmv"

# Turn off the guest account (security best practice - prevents unauthorized local access)
if grep -q "enabled" <<< "$(sysadminctl -guestAccount status 2>&1)"; then
    echo "Disabling guest account..."
    sudo sysadminctl -guestAccount off
fi

# Disable iTunes/Music helper and remote control daemon (prevents auto-launch when media keys pressed)
disable_agent /Applications/iTunes.app/Contents/MacOS/iTunesHelper.app
unload_agent /System/Library/LaunchAgents/com.apple.rcd.plist

# Don't rearrange spaces based on recent use
defaults write com.apple.dock mru-spaces -bool false

echo "All done! Some of the defaults / preferences changes require a logout/restart to take effect."