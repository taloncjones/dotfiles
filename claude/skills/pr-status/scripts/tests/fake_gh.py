#!/usr/bin/env python3
"""Fake gh for pr_status tests: serves $FAKE_GH_DIR fixtures for the spec R10 argv shapes only."""
import json
import os
import re
import sys
from pathlib import Path

FIXTURES = Path(os.environ["FAKE_GH_DIR"])
PR_FIELDS = ("number,title,url,state,headRefName,headRefOid,isDraft,reviewDecision,"
             "reviewRequests,statusCheckRollup,body,commits")
RUN_FIELDS = "databaseId,headSha,status,conclusion,createdAt,url"


def key(text):
    return re.sub(r"[^A-Za-z0-9._-]", "_", text)


def serve(name, default=None):
    failure = FIXTURES / f"fail_{name}"
    if failure.exists():
        sys.stderr.write(failure.read_text())
        sys.exit(1)
    path = FIXTURES / name
    if path.exists():
        sys.stdout.write(path.read_text())
        sys.exit(0)
    if default is not None:
        sys.stdout.write(default)
        sys.exit(0)
    sys.stderr.write(f"fake gh: no fixture {name}\n")
    sys.exit(1)


def main(argv):
    with open(FIXTURES / "calls.log", "a") as log:
        log.write(json.dumps(argv) + "\n")
    if argv == ["api", "user", "--jq", ".login"]:
        serve("user.txt")
    if argv == ["repo", "view", "--json", "nameWithOwner"]:
        serve("repo.json")
    if argv == ["pr", "view", "--json", "number"]:
        serve("current.json")
    if len(argv) == 7 and argv[:2] == ["pr", "view"] and argv[3] == "--repo" and argv[5:] == ["--json", PR_FIELDS]:
        serve(f"pr_{key(argv[4])}_{argv[2]}.json")
    if len(argv) == 4 and argv[:3] == ["api", "--paginate", "--slurp"]:
        match = re.fullmatch(r"repos/([^/]+/[^/]+)/issues/(\d+)/comments", argv[3])
        if match:
            serve(f"comments_{key(match[1])}_{match[2]}.json", "[[]]")
    if (len(argv) == 12 and argv[:3] == ["run", "list", "--repo"] and argv[4] == "--workflow"
            and argv[6] == "--branch" and argv[8:] == ["--limit", "10", "--json", RUN_FIELDS]):
        serve(f"runs_{key(argv[3])}_{key(argv[5])}_{key(argv[7])}.json", "[]")
    sys.stderr.write(f"fake gh: unexpected call {argv}\n")
    sys.exit(97)


if __name__ == "__main__":
    main(sys.argv[1:])
