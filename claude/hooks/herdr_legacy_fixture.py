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


def _seed_task_lead_gate(args):
    """Publish an enabled gate and a capable procedure marker for tests.

    The activation gate ships DISABLED and the shipped procedure advertises
    capability 0, so an unseeded lead claim is refused. Historical contract
    tests exercise successful lead claims, so this fixture gives them an
    environment in which leads genuinely are enabled -- an enabled gate record
    in the payload root and a capability-1 marker in the config dir the reader
    resolves. Fixture setup, not a production bypass: the production reader is
    unchanged and still resolves the account's real config dir.
    """
    if os.environ.get("HERDR_FIXTURE_NO_SEED"):
        return

    def value(flag):
        return args[args.index(flag) + 1] if flag in args else None

    slug = value("--repo-slug")
    if not slug or not core.valid_repo_slug(slug):
        return
    root = Path(os.environ["CLAUDE_CONFIG_DIR"])

    skill = root / "skills" / "herdr-orchestration"
    skill.mkdir(parents=True, exist_ok=True)
    (skill / "SKILL.md").write_text(
        '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n',
        encoding="utf-8",
    )

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
        if args and args[0] == "claim-owner" and "--control-tier" in args:
            if args[args.index("--control-tier") + 1] == "lead":
                _seed_task_lead_gate(args)
    return core.main(args)


if __name__ == "__main__":
    sys.exit(main())
