#!/usr/bin/env bash
# Fake gh: appends every call to FAKE_GH_LOG, serves FAKE_GH_PR_JSON for
# `pr view`, and fails loudly on anything else (so an accidental `pr edit`
# shows up in the log AND as a non-zero exit).
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  cat "${FAKE_GH_PR_JSON:?}"
  exit 0
fi
echo "fake gh: unexpected call: $*" >&2
exit 1
