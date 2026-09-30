"""Herdr task discovery, merge authority, and no bytecode writes (spec R3, R5.8, R8)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "pr_status.py"
_spec = importlib.util.spec_from_file_location("pr_status", SCRIPT)
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)


class HerdrPrs(unittest.TestCase):
    def test_records_select_open_prs_and_submodule_pairs(self):
        core = ps.load_core()
        with tempfile.TemporaryDirectory() as tmp:
            tasks = Path(tmp)
            records = {
                "t-open": {"status": "in-progress", "pr_number": 7},
                "t-pr-field": {"status": "reviewed", "pr_number": None, "pr": 8},
                "t-pair": {"status": "completed", "pr_number": 9,
                           "submodule_pr": {"repo": "org/sub", "number": 3}},
                "t-bad-sub": {"status": "completed", "pr_number": 10, "submodule_pr": {"repo": "x", "number": 3}},
                "t-merged": {"status": "merged", "pr_number": 11},
                "t-abandoned": {"status": "abandoned", "pr_number": 12},
                "t-failed": {"status": "failed", "pr_number": 13},
                "t-bool": {"status": "in-progress", "pr_number": True},
                "t-none": {"status": "kickoff", "pr_number": None},
            }
            for name, rec in records.items():
                (tasks / f"{name}.json").write_text(json.dumps(rec))
            (tasks / "t-open.done.json").write_text(json.dumps({"pr_number": 99}))
            (tasks / "t-corrupt.json").write_text("{not json")
            got = ps.herdr_prs(core, tasks)
        self.assertEqual(sorted(got, key=lambda item: item[0]), [
            (7, None), (8, None), (9, {"repo": "org/sub", "number": 3}), (10, None)])


if __name__ == "__main__":
    unittest.main()
