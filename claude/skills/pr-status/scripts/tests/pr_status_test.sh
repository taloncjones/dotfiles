#!/bin/sh
# Runs the pr-status unittest suite; registered in bin/dotfiles-tests.
set -eu
tests_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
scripts_dir="$(CDPATH= cd -- "$tests_dir/.." && pwd)"
cd "$scripts_dir"
exec python3 -B -m unittest discover -s tests -p 'test_*.py'
