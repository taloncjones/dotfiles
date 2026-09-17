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


def _publish_marker(parent, name):
    """Write the capability marker by creating a NEW file and renaming it over
    `name`, never by opening `name` itself.

    O_NOFOLLOW refuses a symlink at the leaf. It does NOT refuse a hardlink: a
    hardlink is a second directory entry for one inode, not a path component,
    so neither the no-follow walk above nor the leaf flag can see it, and an
    O_TRUNC open through it destroys the aliased file's contents -- including
    a TRACKED file outside the temp root, with both confinement locks intact.

    Creating a fresh inode with O_EXCL and renaming over the name never opens
    the attacker-supplied inode at all. The rename replaces the DIRECTORY
    ENTRY, so a planted hardlink is simply unlinked from that name and its
    other name keeps its bytes. There is no window to lose: unlinking first
    and re-opening would reopen the race, and checking st_nlink after an
    O_TRUNC open is too late, because the kernel truncates during open().
    This is the discipline `write_json_atomic` already applies to the gate
    record below; the marker write was the one place that did not.
    """
    tmp_name = f".{name}.{os.getpid()}.tmp"
    fd = os.open(
        tmp_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=parent,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write('<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n')
        os.rename(tmp_name, name, src_dir_fd=parent, dst_dir_fd=parent)
    except BaseException:
        try:
            os.unlink(tmp_name, dir_fd=parent)
        except OSError:
            pass
        raise


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

    Confinement matters here for a plain reason, not a grand one: this writes
    into a TRACKED file's name, and getting it wrong destroys source. (An
    earlier version of this docstring justified it by calling the marker "the
    whole adversarial claim behind an admitted lead". That was wrong, and
    herdr_capabilities._read_procedure_text now explains why: the marker is
    forgeable by anything able to plant a symlink, so the activation gate is
    an interlock against accident and drift, not an adversarial control. The
    confinement below is still required -- the reason is data safety.)

    Two independent locks:

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
        _publish_marker(parent, name)
    except OSError:
        return
    finally:
        os.close(parent)

    rd = core.repo_dir(slug)
    try:
        core.create_payload_dir(rd)
    except (OSError, ValueError):
        # Same no-follow discipline as the marker write. A plain mkdir here
        # would follow a symlinked component and create real directories
        # inside the link target before write_json_atomic refused the record
        # and raised out of a fixture that is supposed to seed or do nothing.
        return
    scope = core.account_scope(os.getcwd(), value("--runtime") or "claude")
    # Guarded like the two writes above it. A symlink at the gate LEAF makes
    # atomic_json_at raise, and unguarded that escaped here -- after the
    # marker was already published, leaving the fixture half-seeded and
    # crashing, against its seed-or-do-nothing contract.
    try:
        _publish_gate(rd, slug, scope["account_id"])
    except (OSError, ValueError):
        return


def _publish_gate(rd, slug, account_id):
    core.write_json_atomic(core.herdr_caps.gate_path(rd), {
        "schema_version": 1,
        "repo_slug": slug,
        "repo_id": None,
        "account_id": account_id,
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
