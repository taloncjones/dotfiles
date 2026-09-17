"""Explicit pre-registry owner fixtures for historical Herd contract tests."""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

import herdr_orch_core as core
from workflow_context import open_state_parent


def flag_value(args, flag):
    """The token after `flag`, or None when it is absent or trailing.

    A trailing flag has no value, so it reads as absent. Indexing past the end
    would raise IndexError out of a fixture whose whole job is to hand argv to
    the real CLI, which then never gets to report the usage error itself.
    """
    if flag not in args:
        return None
    index = args.index(flag) + 1
    return args[index] if index < len(args) else None


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


def _seed_task_lead_gate(args):
    """Publish an enabled gate and a capable procedure marker for tests.

    The activation gate ships DISABLED and the shipped procedure advertises
    capability 0, so an unseeded lead claim is refused. Historical contract
    tests exercise successful lead claims, so this fixture gives them an
    environment in which leads genuinely are enabled -- an enabled gate record
    in the payload root and a capability-1 marker in the config dir the reader
    resolves. Fixture setup, not a production bypass: the production reader is
    unchanged and still resolves the account's real config dir.

    Confinement is two independent locks, because the marker this writes is
    the whole adversarial claim behind an admitted lead -- and it writes into
    a TRACKED file's name:

    1. The resolved config dir must sit under the real temp root. This bounds
       the path we were handed.
    2. Every component below it is created and opened NO-FOLLOW, so a symlink
       planted at `skills` (or anywhere under it) is refused instead of
       followed. Lock 1 alone is not confinement: it constrains the root and
       says nothing about what the components below it point at, so a
       legitimate mktemp config dir containing `skills -> ~/.claude/skills`
       used to overwrite the tracked SKILL.md with a capability-1 marker.
    """
    if os.environ.get("HERDR_FIXTURE_NO_SEED"):
        return

    def value(flag):
        return flag_value(args, flag)

    slug = value("--repo-slug")
    if not slug or not core.valid_repo_slug(slug):
        return
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]).resolve()
    tmp = Path(os.path.realpath(tempfile.gettempdir())).resolve()
    if tmp not in root.parents:
        return

    marker = root / "skills" / "herdr-orchestration" / "SKILL.md"
    try:
        parent, name = open_state_parent(marker, create=True)
    except (OSError, ValueError):
        # A symlinked or non-directory component: seed nothing rather than
        # write through it. open_state_parent raises ValueError("state path
        # contains a symlink") for exactly this case.
        return
    try:
        fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent,
        )
    except OSError:
        return
    finally:
        os.close(parent)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write('<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n')

    rd = core.repo_dir(slug)
    rd.mkdir(parents=True, exist_ok=True)
    scope = core.account_scope(os.getcwd(), value("--runtime") or "claude")
    core.write_json_atomic(core.herdr_caps.gate_path(rd), {
        "schema_version": 1,
        "repo_slug": slug,
        "repo_id": None,
        "account_id": scope["account_id"],
        "enabled": True,
    })


def main():
    args = sys.argv[1:]
    if args and args[0] == "classify-banner" and "--after" not in args:
        # Canned fixture text is produced for this invocation, with no history.
        args = [*args, "--fresh-capture"]
    if args and args[0] == "claim-owner":

        def value(flag):
            return flag_value(args, flag)

        try:
            int(value("--pid"))
        except (TypeError, ValueError):
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
        if flag_value(args, "--control-tier") == "lead":
            _seed_task_lead_gate(args)
    return core.main(args)


if __name__ == "__main__":
    sys.exit(main())
