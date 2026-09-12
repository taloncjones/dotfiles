#!/usr/bin/env python3
"""SessionStart hook: warn when claude/settings.json.tmpl changed since the
last reconcile.

reconcile_claude_settings_file (install/common/claude-links.sh) stamps the
template's SHA-256 into <config-dir>/.settings-template-sha256 on every
successful reconcile. This hook re-hashes the template (found through the
config dir's hooks/ symlink back into the dotfiles repo) and compares. A
mismatch means template-owned settings (hook registrations, env, permissions)
changed without a reconcile: recommend `update --ai` plus a restart.

Advisory only: every failure path (no repo, no template, unreadable stamp)
exits 0 silently. Cloud containers without the repo hit that path by design.
"""

import hashlib
import json
import os
import sys


def main() -> int:
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )

    hooks_dir = os.path.join(config_dir, "hooks")
    try:
        repo_hooks = os.path.realpath(hooks_dir)
    except OSError:
        return 0
    # hooks/ resolves to <repo>/claude/hooks; the template sits beside it.
    template = os.path.join(os.path.dirname(repo_hooks), "settings.json.tmpl")
    if not os.path.isfile(template):
        return 0

    try:
        with open(template, "rb") as fh:
            current_sha = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return 0

    stamp_path = os.path.join(config_dir, ".settings-template-sha256")
    stamp_state = "missing"
    stamped_sha = None
    try:
        with open(stamp_path, "rb") as fh:
            raw = fh.read()
        # A corrupt (non-UTF-8 or garbage) stamp is still a reason to nudge:
        # decode defensively so the hook can never traceback.
        stamped_sha = raw.decode("utf-8", errors="replace").strip() or None
        if stamped_sha is not None:
            stamp_state = "present"
    except OSError:
        stamp_state = "missing"

    if stamp_state == "present" and stamped_sha == current_sha:
        return 0

    if stamp_state == "missing":
        reason = "no reconcile stamp found"
    else:
        reason = "settings template changed since last reconcile"
    message = (
        f"[WARNING] {reason} -- run 'update --ai' and restart Claude "
        "to pick up template-owned settings (hooks, env, permissions)."
    )
    print(message, file=sys.stderr)
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": message,
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
