#!/usr/bin/env bash
# bootstrap.sh - Entry point for dotfiles installation
#
# Run this script to set up a new machine with all dotfiles, packages, and preferences.
# Usage: ./bootstrap.sh
#
# This script sources install/install.sh which handles platform detection and runs
# the appropriate installation steps for macOS or Linux.

source install/install.sh