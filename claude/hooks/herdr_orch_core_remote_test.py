"""github_owner_repo and the ship brief's origin check, against a fake ssh binary."""

import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HOOKS = Path(__file__).resolve().parent
sys.path.insert(0, str(HOOKS))
SPEC = importlib.util.spec_from_file_location("herdr_orch_core", HOOKS / "herdr_orch_core.py")
core = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(core)


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name)
        self.log = self.bin / "ssh.log"
        patcher = mock.patch.dict(os.environ, {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_ssh(self, body):
        path = self.bin / "ssh"
        path.write_text(f'#!/bin/sh\necho "$*" >> "{self.log}"\n{body}\n')
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def ssh_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_plain_github_forms_make_no_ssh_call(self):
        self.fake_ssh("echo hostname github.com")
        for url in (
            "https://github.com/Org/Repo.git",
            "git@github.com:Org/Repo.git",
            "ssh://git@github.com/Org/Repo",
        ):
            self.assertEqual(core.github_owner_repo(url), ("Org", "Repo"), url)
        self.assertEqual(self.ssh_calls(), [])

    def test_scp_alias_resolving_to_github(self):
        self.fake_ssh("echo hostname GitHub.com")
        self.assertEqual(core.github_owner_repo("git@Git-work:Org/Repo.git"), ("Org", "Repo"))
        self.assertEqual(self.ssh_calls(), ["-G -l git Git-work"])

    def test_ssh_url_alias_resolving_to_github(self):
        self.fake_ssh("echo hostname github.com")
        self.assertEqual(core.github_owner_repo("ssh://git@Git-work/Org/Repo"), ("Org", "Repo"))
        self.assertEqual(self.ssh_calls(), ["-G -l git Git-work"])

    def test_alias_resolving_elsewhere(self):
        self.fake_ssh("echo hostname gitlab.example.com")
        self.assertIsNone(core.github_owner_repo("git@Git-work:Org/Repo.git"))

    def test_ssh_nonzero_exit(self):
        self.fake_ssh("echo hostname github.com; exit 255")
        self.assertIsNone(core.github_owner_repo("git@Git-work:Org/Repo.git"))

    def test_ssh_missing(self):
        with mock.patch.dict(os.environ, {"PATH": str(self.bin)}):
            self.assertIsNone(core.github_owner_repo("git@Git-work:Org/Repo.git"))

    def test_ssh_without_hostname_line(self):
        self.fake_ssh("echo user git")
        self.assertIsNone(core.github_owner_repo("git@Git-work:Org/Repo.git"))

    def test_ssh_timeout_is_five_seconds(self):
        self.fake_ssh("exec sleep 30")
        started = __import__("time").monotonic()
        self.assertIsNone(core.github_owner_repo("git@Git-work:Org/Repo.git"))
        self.assertLess(__import__("time").monotonic() - started, 9)

    def test_unsafe_shapes_never_reach_ssh(self):
        self.fake_ssh("echo hostname github.com")
        for url in (
            "git@-oProxyCommand=x:Org/Repo.git",
            "git@.hidden:Org/Repo.git",
            "ssh://git@-bad/Org/Repo",
            "https://gitlab.com/Org/Repo.git",
            "git@Git-work:Org/Repo/extra.git",
            "",
        ):
            self.assertIsNone(core.github_owner_repo(url), url)
        self.assertEqual(self.ssh_calls(), [])

    def test_ship_values_accept_alias_origin(self):
        record = {"pr_number": 7, "review_head_sha": "a" * 40, "worktree": "/w", "base_ref": "origin/main",
                  "task_id": "t"}
        ns = mock.Mock(tier="full", prior_handoff=None)
        blocks = {"ship-tier-full": "full"}

        def run(remote):
            def fake_git(_worktree, *args):
                return remote if args[0] == "config" else "b" * 40 + "\trefs/heads/main"
            with mock.patch.object(core, "_brief_git", fake_git):
                return core._brief_ship_values(Path("/rd"), record, ns, "a" * 40, blocks, {})

        self.fake_ssh("echo hostname github.com")
        self.assertEqual(run("git@Git-work:Org/Repo.git")["pr_repo"], "Org/Repo")
        self.fake_ssh("echo hostname example.com")
        with self.assertRaises(SystemExit) as raised:
            run("git@Git-work:Org/Repo.git")
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
