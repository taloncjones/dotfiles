"""Explicit pre-registry owner fixtures for historical Herd contract tests."""

import json
import os
import sys
import time
from pathlib import Path

import herdr_orch_core as core


def claim_legacy_owner(rd, session_id, host, pid, *args, **kwargs):
    """Seed a legitimate old incumbent, then exercise its real migration."""
    rd = Path(rd)
    if (
        not (rd / "owner.json").exists()
        and not core.coordination.owner_path(rd).exists()
    ):
        rd.mkdir(parents=True, exist_ok=True)
        (rd / "owner.json").write_text(
            json.dumps(
                {
                    "session_id": session_id,
                    "host": host,
                    "pid": pid,
                    "fence": 1,
                    "heartbeat_ts": time.time(),
                    "messaging_socket": None,
                }
            )
        )
    return core.claim_owner(rd, session_id, host, pid, *args, **kwargs)


def main():
    args = sys.argv[1:]
    if args and args[0] == "classify-banner" and "--after" not in args:
        # Canned fixture text is produced for this invocation, with no history.
        args = [*args, "--fresh-capture"]
    if args and args[0] == "claim-owner":

        def value(flag):
            return args[args.index(flag) + 1]

        try:
            int(value("--pid"))
        except ValueError:
            return core.main(args)
        slug = value("--repo-slug")
        if core.valid_repo_slug(slug):
            rd = core.repo_dir(slug)
            if (
                not (rd / "owner.json").exists()
                and not core.coordination.owner_path(rd).exists()
            ):
                rd.mkdir(parents=True, exist_ok=True)
                (rd / "owner.json").write_text(
                    json.dumps(
                        {
                            "session_id": value("--session"),
                            "host": value("--host"),
                            "pid": int(value("--pid")),
                            "fence": 1,
                            "heartbeat_ts": time.time(),
                            "messaging_socket": None,
                        }
                    )
                )
        # The historical slug fixtures intentionally have no checkout identity.
        # They can only exercise migration, never mint a fresh unbound owner.
        root = Path(os.environ["CLAUDE_CONFIG_DIR"])
        root.mkdir(parents=True, exist_ok=True)
        os.chdir(root)
    return core.main(args)


if __name__ == "__main__":
    sys.exit(main())
