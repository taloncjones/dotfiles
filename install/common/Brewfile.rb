###############################
#  Utilities                  #
###############################

# we want ZSH as our default shell on all environments
# and not to use system as to keep it updated with latest
brew "zsh"

# wget for pulling web data
brew "wget"

# eza as ls replacement
brew "eza"

# install git since platform git is often old
brew "git"

# glow for markdown rendering in the terminal 
# https://github.com/charmbracelet/glow
brew "glow"

# highlight for syntax highlighting in the terminal
# http://www.andre-simon.de/doku/highlight/en/highlight.php
# https://gitlab.com/saalen/highlight
brew "highlight"

# install highlighting for several commands like whois, ping, etc
# https://github.com/garabik/grc
brew "grc"

# perl-like regular expressions, used in some aliases
brew "pcre"

# htop is a better top
brew "htop"

# duf is a better df
brew "duf"

# 7zip for file compression/decompression
brew "p7zip"

# domain name lookup and information
brew "whois"

# name server record lookup and information
brew "doggo"

# bat is a better cat
brew "bat"

# hugo is useful for static site generation & deployment
brew "hugo"

# ncdu is a better tool for showing directory sizes
brew "ncdu"

# tldr is like man, but better
brew "tldr"

# trippy is like traceroute, but better
brew "trippy"

# fd is a find replacement
brew "fd"

# cloudflared client
brew "cloudflared"

# fastfetch used for printing system information
# neofetch was used previously, but it has been archived as of April 26, 2024
brew "fastfetch"

# onefetch used for printing git repo information
brew "onefetch"

# prettier for formatting markdown, json, yaml, etc
brew "prettier"

# gemini CLI for Google Gemini
brew "gemini-cli"

# bun JavaScript runtime, used by Claude Code MCP servers
brew "oven-sh/bun/bun"

# docker CLI and compose plugin (daemon provided by Docker Desktop)
brew "docker"
brew "docker-compose"