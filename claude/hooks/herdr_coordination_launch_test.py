import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core


class HeadlessAccountTests(unittest.TestCase):
    def test_selected_account_reaches_mechanical_and_think_children(self):
        cases = (
            ("personal", "personal", False, "work", None, "same", 0),
            ("personal-quota", "work", True, "work", None, "same", 0),
            ("work", "work", False, None, ".claude-work", "same", 0),
            ("custom", "work", False, "custom", "custom-config", "same", 0),
            ("wrong-clone", "work", False, None, None, "clone", 2),
            ("same-origin-clone", "work", False, None, None, "same-origin", 2),
            ("protected-linked", "work", False, None, None, "personal-linked", 2),
            (
                "external-linked",
                "work",
                False,
                None,
                ".claude-work",
                "external-linked",
                0,
            ),
            ("personal-linked-quota", "work", True, "work", None, "personal-linked", 0),
        )
        for (
            label,
            owner,
            personal,
            inherited,
            expected_config,
            layout,
            expected_rc,
        ) in cases:
            with self.subTest(account=label), tempfile.TemporaryDirectory() as tmp:
                home = Path(tmp).resolve()
                repo = home / "Git" / owner / "project"
                repo.mkdir(parents=True)
                bindir = home / "bin"
                bindir.mkdir()
                log = home / "child.json"
                fake = bindir / "claude"
                keys = (
                    "CLAUDE_CONFIG_DIR",
                    "CODEX_HOME",
                    "CLAUDE_PERSONAL_ONLY",
                    "WORKFLOW_PERSONAL_ACCOUNT",
                    "FIXTURE_UNRELATED",
                )
                fake.write_text(
                    f"#!{sys.executable}\nimport json,os,sys\n"
                    f"json.dump({{k:os.environ.get(k) for k in {keys!r}}},"
                    f"open({str(log)!r},'w'))\n"
                    "sys.stdin.read()\n"
                    "print(json.dumps({'type':'result','subtype':'success'}))\n"
                )
                fake.chmod(0o700)
                env = {
                    k: v
                    for k, v in os.environ.items()
                    if not k.startswith("GIT_")
                    and k
                    not in (
                        "CLAUDE_CONFIG_DIR",
                        "CODEX_HOME",
                        "CLAUDE_PERSONAL_ONLY",
                        "WORKFLOW_PERSONAL_ACCOUNT",
                        "CLAUDE_WORK_TREE",
                        "CLAUDE_WORK_CONFIG_DIR",
                    )
                }
                env.update(
                    HOME=str(home),
                    PATH=str(bindir) + os.pathsep + env["PATH"],
                    GIT_CONFIG_GLOBAL="/dev/null",
                    GIT_CONFIG_NOSYSTEM="1",
                    HERDR_COORDINATION_ROOT=str(home / "registry"),
                    FIXTURE_UNRELATED="preserved",
                )
                if inherited:
                    env["CLAUDE_CONFIG_DIR"] = str(
                        home
                        / (".claude-work" if inherited == "work" else "custom-config")
                    )
                with patch.dict(os.environ, env, clear=True):
                    subprocess.run(["git", "init", "-q", str(repo)], check=True)
                    subprocess.run(
                        [
                            "git",
                            "-C",
                            str(repo),
                            "-c",
                            "user.name=Test",
                            "-c",
                            "user.email=test@example.invalid",
                            "-c",
                            "commit.gpgsign=false",
                            "-c",
                            "core.hooksPath=/dev/null",
                            "commit",
                            "-qm",
                            "base",
                            "--allow-empty",
                        ],
                        check=True,
                    )
                    child = repo
                    origin = "https://example.invalid/fixture/project.git"
                    if layout != "same":
                        child = (
                            home / "external"
                            if layout == "external-linked"
                            else home / "Git" / "personal" / "child"
                        )
                        if layout.endswith("linked"):
                            subprocess.run(
                                [
                                    "git",
                                    "-C",
                                    str(repo),
                                    "worktree",
                                    "add",
                                    "--detach",
                                    str(child),
                                ],
                                check=True,
                                capture_output=True,
                            )
                        else:
                            subprocess.run(
                                [
                                    "git",
                                    "clone",
                                    "--quiet",
                                    "--local",
                                    str(repo),
                                    str(child),
                                ],
                                check=True,
                            )
                        if layout == "same-origin":
                            subprocess.run(
                                [
                                    "git",
                                    "-C",
                                    str(repo),
                                    "remote",
                                    "add",
                                    "origin",
                                    origin,
                                ],
                                check=True,
                            )
                            subprocess.run(
                                [
                                    "git",
                                    "-C",
                                    str(child),
                                    "remote",
                                    "set-url",
                                    "origin",
                                    origin,
                                ],
                                check=True,
                            )
                    context = core.repository_context(repo)
                    child_context = core.repository_context(child)
                    slug = core.repo_slug(
                        origin if layout == "same-origin" else "", context["common_dir"]
                    )
                    scope = core.account_scope(repo, "claude", personal=personal)
                    rd = Path(scope["account_root"]) / "herdr-orch" / slug
                    (rd / "tasks").mkdir(parents=True)
                    (rd / "think").mkdir()
                    brief = rd / "tasks" / "brief.txt"
                    brief.write_text("fixture task")
                    tid = "think-triage-20260908170000"
                    (rd / "think" / f"{tid}.question.md").write_text("fixture question")
                    common = [
                        "--repo-slug",
                        slug,
                        "--repo-path",
                        str(repo),
                        "--runtime",
                        "claude",
                    ]
                    if personal:
                        common.append("--personal")
                    self.assertEqual(
                        core.main(
                            [
                                "claim-owner",
                                *common,
                                "--session",
                                "fixture",
                                "--host",
                                "fixture",
                                "--pid",
                                str(os.getpid()),
                            ]
                        ),
                        0,
                    )
                    commands = (
                        [
                            "run-mech",
                            *common,
                            "--task-id",
                            "td-route",
                            "--workspace",
                            "w1",
                            "--agent",
                            "mech-td-route",
                            "--launch-id",
                            "mech-td-route-1",
                            "--model",
                            "haiku",
                            "--worktree",
                            str(child),
                            "--base-sha",
                            child_context["head"],
                            "--brief-file",
                            str(brief),
                            "--max-turns",
                            "5",
                            "--max-budget-usd",
                            "0.5",
                            "--timeout-secs",
                            "60",
                        ],
                        [
                            "run-think",
                            *common,
                            "--session",
                            "fixture",
                            "--fence",
                            "1",
                            "--think-id",
                            tid,
                            "--kind",
                            "triage",
                            "--model",
                            "opus",
                            "--effort",
                            "high",
                            "--cwd",
                            str(child),
                            "--max-turns",
                            "5",
                            "--max-budget-usd",
                            "1",
                            "--timeout-secs",
                            "60",
                        ],
                    )
                    before = dict(os.environ)
                    for command in commands:
                        with self.subTest(command=command[0]):
                            if expected_rc:
                                for artifact in (
                                    log,
                                    rd / "tasks" / "td-route.spend.jsonl",
                                    rd / "tasks" / "td-route.done.json",
                                    rd / "think" / f"{tid}.launch.json",
                                    rd / "think" / f"{tid}.answer.json",
                                ):
                                    artifact.unlink(missing_ok=True)
                            try:
                                result = core.main(command)
                            except SystemExit as exc:
                                result = exc.code
                            self.assertEqual(result, expected_rc)
                            if expected_rc:
                                self.assertFalse(log.exists())
                                self.assertFalse(
                                    (rd / "tasks" / "td-route.spend.jsonl").exists()
                                )
                                self.assertFalse(
                                    (rd / "tasks" / "td-route.done.json").exists()
                                )
                                self.assertFalse(
                                    (rd / "think" / f"{tid}.launch.json").exists()
                                )
                                self.assertEqual(dict(os.environ), before)
                                continue
                            self.assertEqual(
                                json.loads(log.read_text()),
                                {
                                    "CLAUDE_CONFIG_DIR": (
                                        str(home / expected_config)
                                        if expected_config
                                        else None
                                    ),
                                    "CODEX_HOME": str(home / ".codex"),
                                    "CLAUDE_PERSONAL_ONLY": None,
                                    "WORKFLOW_PERSONAL_ACCOUNT": (
                                        "1" if expected_config is None else None
                                    ),
                                    "FIXTURE_UNRELATED": "preserved",
                                },
                            )
                            self.assertEqual(dict(os.environ), before)

    def test_direct_headless_consumers_refuse_mismatched_checkout_before_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            selected = home / "Git" / "work" / "selected"
            actual = home / "Git" / "personal" / "actual"
            bindir = home / "bin"
            bindir.mkdir()
            marker = home / "child-started"
            fake = bindir / "claude"
            fake.write_text(
                f"#!{sys.executable}\nfrom pathlib import Path\n"
                f"Path({str(marker)!r}).touch()\n"
                'print(\'{"type":"result","subtype":"success"}\')\n'
            )
            fake.chmod(0o700)
            environment = {
                "HOME": str(home),
                "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "HERDR_COORDINATION_ROOT": str(home / "registry"),
            }
            with patch.dict(os.environ, environment, clear=True):
                for repo in (selected, actual):
                    repo.mkdir(parents=True)
                    subprocess.run(["git", "init", "-q", str(repo)], check=True)
                context = core.repository_context(selected)
                scope = core.account_scope(selected, "claude")
                rd = Path(scope["account_root"]) / "herdr-orch" / "fixture"
                (rd / "tasks").mkdir(parents=True)
                args = SimpleNamespace(
                    worktree=str(actual),
                    task_id="td-direct",
                    workspace="w1",
                    agent="mech-td-direct",
                    launch_id="mech-td-direct-1",
                    model="haiku",
                    max_turns=5,
                    max_budget_usd=0.5,
                    timeout_secs=60,
                    base_sha="a" * 40,
                )
                token = core._PAYLOAD_SELECTION.set(
                    {"context": context, "scope": scope}
                )
                try:
                    calls = (
                        lambda: core.run_headless([str(fake)], actual, "", 5),
                        lambda: core.run_mech(rd, args, "fixture", 5),
                    )
                    for call in calls:
                        with self.subTest(call=call):
                            marker.unlink(missing_ok=True)
                            with self.assertRaisesRegex(ValueError, "repository"):
                                call()
                            self.assertFalse(marker.exists())
                            self.assertEqual(list((rd / "tasks").iterdir()), [])
                finally:
                    core._PAYLOAD_SELECTION.reset(token)

    def test_unselected_headless_call_preserves_legacy_environment(self):
        argv = [
            sys.executable,
            "-c",
            (
                "import json,os;print(json.dumps({'type':'result','subtype':'success',"
                "'result':os.environ.get('CLAUDE_CONFIG_DIR')}))"
            ),
        ]
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": tmp}),
        ):
            token = core._PAYLOAD_SELECTION.set(None)
            try:
                subtype, result, code = core.run_headless(argv, tmp, "", 5)
            finally:
                core._PAYLOAD_SELECTION.reset(token)
            self.assertEqual((subtype, result["result"], code), ("success", tmp, 0))


if __name__ == "__main__":
    unittest.main()
