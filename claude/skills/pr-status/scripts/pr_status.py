#!/usr/bin/env python3
"""pr_status.py - one row per open PR: head, CI, co-review, bench, body, waiting on.

Read-only: runs gh reads, reads herdr task records and the reconcile config.
See ../SKILL.md for the contract.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import types
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ under claude/hooks

CLAUDE_DIR = Path(__file__).resolve().parents[3]
PR_FIELDS = ("number,title,url,state,headRefName,headRefOid,isDraft,reviewDecision,"
             "reviewRequests,statusCheckRollup,body,commits")
RUN_FIELDS = "databaseId,headSha,status,conclusion,createdAt,url"
DONE_STATUSES = frozenset({"merged", "abandoned", "failed"})
CI_IGNORED = frozenset({"SKIPPED", "NEUTRAL"})
AUDIT_RE = re.compile(r"^<!-- co-review-audit head=(?P<sha>[0-9a-f]{40}) run=(?P<run>\S+) -->$")
CHECKED_RE = re.compile(r"^\s*- \[[xX]\] (?P<text>.*)$")
UNCHECKED_RE = re.compile(r"^\s*- \[ \]")
EVIDENCE_RE = re.compile(r"\b(run|stand|uat|evidence)\b", re.IGNORECASE)
LINK_RE = re.compile(r"\[(?P<label>[^\]]+)\]\((?P<url>[^)\s]+)\)")
HEX_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
PLACEHOLDERS = ("<run link>", "<n>")
HEADER = ("PR", "Head", "CI", "Co-review at head", "Bench / UAT", "Body current", "Draft", "Waiting on")
CELL_KEYS = ("pr", "head", "ci", "co_review", "bench", "body", "draft", "waiting_on")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MARKER_RE = _load("pr_status_gate", CLAUDE_DIR / "skills" / "co-review" / "scripts" / "pr_ready_gate.py").MARKER_RE


def is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def md(text):
    return str(text).replace("\r", " ").replace("\n", " ").replace("|", "\\|")


def pr_link(repo, number, url=None):
    return f"[#{number}]({url or f'https://github.com/{repo}/pull/{number}'})"


def pr_cell(pr, prefix):
    lead = f"{prefix} " if prefix else ""
    return f"{lead}{pr_link(None, pr['number'], pr['url'])} {md(pr['title'])}"


def head_cell(pr):
    sha = pr["headRefOid"]
    repo_url = pr["url"].rsplit("/pull/", 1)[0]
    return f"[{sha[:9]}]({repo_url}/commit/{sha})"


def ci_state(rollup):
    """(failing names, pending count, passing count) from statusCheckRollup."""
    failing, pending, passing = [], 0, 0
    for entry in rollup if isinstance(rollup, list) else []:
        entry = entry if isinstance(entry, dict) else {}
        if entry.get("__typename") == "StatusContext":
            state = entry.get("state")
            if state == "SUCCESS":
                passing += 1
            elif state in ("FAILURE", "ERROR"):
                failing.append(md(entry.get("context") or "?"))
            else:
                pending += 1
        elif entry.get("status") != "COMPLETED":
            pending += 1
        elif entry.get("conclusion") in CI_IGNORED:
            continue
        elif entry.get("conclusion") == "SUCCESS":
            passing += 1
        else:
            failing.append(md(entry.get("name") or "?"))
    return failing, pending, passing


def ci_cell(failing, pending, passing):
    if failing:
        return f"{len(failing)} failing: {', '.join(failing)}"
    if pending:
        return f"{pending} pending"
    return "green" if passing else "no checks"


def markers(comments, login):
    """Trusted co-review markers, oldest first."""
    found = []
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        user = comment.get("user")
        if not isinstance(user, dict) or user.get("login") != login:
            continue
        first = str(comment.get("body") or "").split("\n", 1)[0].strip()
        base = {"id": comment.get("id"), "url": comment.get("html_url"),
                "created_at": str(comment.get("created_at") or "")}
        match = MARKER_RE.match(first)
        if match:
            found.append({**base, "sha": match["sha"], "kind": "round",
                          "verdict": match["verdict"], "round": int(match["round"])})
            continue
        match = AUDIT_RE.match(first)
        if match:
            found.append({**base, "sha": match["sha"], "kind": "audit", "verdict": "APPROVE", "round": None})
    found.sort(key=lambda m: (m["created_at"], m["id"] if is_count(m["id"]) else 0))
    return found


def co_review(found, head):
    """(state, cell); state is approve, changes, stale or none."""
    at_head = [m for m in found if m["sha"] == head]
    if at_head:
        m = at_head[-1]
        label = f"r{m['round']} {m['verdict']}" if m["kind"] == "round" else "audit APPROVE"
        return m["verdict"].lower(), f"{label} ([{m['id']}]({m['url']}))"
    if found:
        m = found[-1]
        label = f"r{m['round']}" if m["kind"] == "round" else "audit"
        return "stale", f"stale ({label} at {m['sha'][:9]})"
    return "none", "none"


def run_link(run):
    return f"[{run.get('databaseId')}]({run.get('url')})"


def bench(runs, head):
    """(ok, cell) from one branch's bench workflow runs."""
    runs = sorted((r for r in runs if isinstance(r, dict)),
                  key=lambda r: str(r.get("createdAt") or ""), reverse=True)
    at_head = next((r for r in runs if r.get("headSha") == head), None)
    if at_head is None:
        ok, parts = False, ["none at head"]
    elif at_head.get("status") == "completed":
        ok = at_head.get("conclusion") == "success"
        parts = [f"{at_head.get('conclusion')} {run_link(at_head)}"]
    else:
        ok, parts = False, [f"{at_head.get('status')} {run_link(at_head)}"]
    parts += [f"{r.get('status')} {run_link(r)}" for r in runs
              if r is not at_head and r.get("status") != "completed"]
    return ok, ", ".join(parts)


def plan_section(body):
    """Lines of the body's '## Test plan' section."""
    lines, inside = [], False
    for line in body.splitlines():
        if line.startswith("## "):
            inside = line[3:].strip().lower() == "test plan"
        elif inside:
            lines.append(line)
    return lines


def evidence_link(plan_lines):
    for line in plan_lines:
        checked = CHECKED_RE.match(line)
        if checked and EVIDENCE_RE.search(checked["text"]):
            link = LINK_RE.search(checked["text"])
            if link:
                return f"evidence [{md(link['label'])}]({link['url']})"
    return None


def body_reasons(body, commits, head):
    reasons = []
    unchecked = sum(1 for line in plan_section(body) if UNCHECKED_RE.match(line))
    if unchecked:
        reasons.append(f"{unchecked} unchecked")
    reasons += [f"placeholder `{token}`" for token in PLACEHOLDERS if token in body]
    oids = [c.get("oid") for c in commits if isinstance(c, dict) and isinstance(c.get("oid"), str)]
    stale = []
    for token in HEX_RE.findall(body):
        if token not in stale and any(o != head and o.startswith(token) for o in oids):
            stale.append(token)
    return reasons + [f"stale sha {token}" for token in stale]


def waiting_on(facts):
    """The first matching waiting-on rule (spec R5)."""
    if facts["state"] in ("MERGED", "CLOSED"):
        return facts["state"].lower()
    if facts["ci_failing"]:
        return "CI: " + ", ".join(facts["ci_failing"])
    if facts["ci_pending"] or not facts["ci_passing"]:
        return "CI"
    if facts["co_review"] in ("none", "stale"):
        return "co-review at head"
    if facts["co_review"] == "changes":
        return "co-review findings"
    if facts["bench_ok"] is False:
        return "bench run"
    if facts["body_reasons"]:
        return "body edit"
    if facts["draft"]:
        return "undraft"
    if facts["review_decision"] in ("REVIEW_REQUIRED", "CHANGES_REQUESTED"):
        who = facts["reviewers"]
        return "approvers" + (f" ({', '.join(who)})" if who else "")
    return f"merge ({facts['authority']})"


def with_submodule(text, submodule):
    """Prefix the submodule merge step while the paired submodule PR is unmerged."""
    if submodule is None or submodule.get("state") == "MERGED":
        return text
    link = pr_link(submodule["repo"], submodule["number"], submodule.get("url"))
    return f"submodule PR {link} merge + re-pin; {text}"


def reviewers(requests):
    names = []
    for req in requests if isinstance(requests, list) else []:
        if isinstance(req, dict):
            name = req.get("login") or req.get("slug") or req.get("name")
            if name:
                names.append(md(name))
    return names


def build_row(pr, comments, runs, login, authority, prefix, submodule):
    """Rendered cells for one fetched PR; runs is None without a bench workflow."""
    head = pr["headRefOid"]
    body = str(pr.get("body") or "")
    failing, pending, passing = ci_state(pr.get("statusCheckRollup"))
    review_state, review_text = co_review(markers(comments, login), head)
    bench_ok, bench_text = (None, "n/a") if runs is None else bench(runs, head)
    evidence = evidence_link(plan_section(body))
    if evidence:
        bench_text += f"; {evidence}"
    reasons = body_reasons(body, pr.get("commits") or [], head)
    facts = {"state": pr.get("state"), "ci_failing": failing, "ci_pending": pending,
             "ci_passing": passing, "co_review": review_state, "bench_ok": bench_ok,
             "body_reasons": reasons, "draft": bool(pr.get("isDraft")),
             "review_decision": pr.get("reviewDecision"),
             "reviewers": reviewers(pr.get("reviewRequests")), "authority": authority}
    return {"pr": pr_cell(pr, prefix), "head": head_cell(pr), "ci": ci_cell(failing, pending, passing),
            "co_review": review_text, "bench": bench_text, "body": md("; ".join(reasons)) or "yes",
            "draft": "yes" if pr.get("isDraft") else "no",
            "waiting_on": with_submodule(waiting_on(facts), submodule)}


def error_row(repo, number, prefix, message):
    row = dict.fromkeys(CELL_KEYS, "?")
    row["pr"] = f"{prefix} {pr_link(repo, number)}" if prefix else pr_link(repo, number)
    row["waiting_on"] = f"error: {md(message)}"
    return row


def markdown(rows):
    lines = ["| " + " | ".join(HEADER) + " |", "|" + " --- |" * len(HEADER)]
    lines += ["| " + " | ".join(row[key] for key in CELL_KEYS) + " |" for row in rows]
    return "\n".join(lines)


def load_core():
    """herdr_orch_core, or None when it cannot be imported."""
    try:
        return _load("pr_status_core", CLAUDE_DIR / "hooks" / "herdr_orch_core.py")
    except (Exception, SystemExit):
        return None


def cwd_slug(core, cwd):
    try:
        return core._context_slug(core.repository_context(cwd))
    except (Exception, SystemExit):
        return None


def herdr_tasks_dir(core, cwd, slug):
    """The cwd repo's herdr tasks dir, or None when the repo is not herdr-managed."""
    try:
        core.select_payload(types.SimpleNamespace(repo_path=cwd, runtime="claude", personal=False,
                                                  repo_slug=slug))
        tasks = core.repo_dir(slug) / "tasks"
        return tasks if tasks.is_dir() else None
    except (Exception, SystemExit):
        return None


def submodule_ref(value):
    if (isinstance(value, dict) and isinstance(value.get("repo"), str)
            and REPO_RE.fullmatch(value["repo"]) and is_count(value.get("number"))):
        return {"repo": value["repo"], "number": value["number"]}
    return None


def herdr_prs(core, tasks_dir):
    """[(pr number, submodule ref or None)] for task records still in flight."""
    found = []
    for path in core.task_record_files(tasks_dir):
        try:
            rec = json.loads(core.read_payload_text(path))
        except (OSError, ValueError) as exc:
            print(f"[WARNING] pr-status: skipped {path.name}: {exc}", file=sys.stderr)
            continue
        if not isinstance(rec, dict):
            print(f"[WARNING] pr-status: skipped {path.name}: not an object", file=sys.stderr)
            continue
        if rec.get("status") in DONE_STATUSES:
            continue
        number = rec.get("pr_number") if rec.get("pr_number") is not None else rec.get("pr")
        if is_count(number):
            found.append((number, submodule_ref(rec.get("submodule_pr"))))
    return found


def merge_authority(core, cwd, slug):
    if core is None or slug is None:
        return "human"
    try:
        return "director" if core.merge_authority(slug, cwd)["authority"] == "director" else "human"
    except (Exception, SystemExit):
        return "human"


class GhError(Exception):
    """One gh read failed; the message is its first stderr line."""


class GhMissing(Exception):
    """gh is not on PATH."""


def gh(*args):
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120)
    except FileNotFoundError as exc:
        raise GhMissing("gh not found on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise GhError(f"gh {' '.join(args[:2])} timed out") from exc
    if proc.returncode != 0:
        lines = proc.stderr.strip().splitlines()
        raise GhError(lines[0] if lines else f"gh {' '.join(args[:2])} exited {proc.returncode}")
    return proc.stdout


def gh_json(*args):
    text = gh(*args)
    try:
        return json.loads(text)
    except ValueError as exc:
        raise GhError(f"gh {' '.join(args[:2])}: invalid JSON") from exc


def bench_workflows(path):
    """{owner/name: workflow file} from every block's bench_workflows key."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {}
    found = {}
    for block in data.values() if isinstance(data, dict) else []:
        mapping = block.get("bench_workflows") if isinstance(block, dict) else None
        if isinstance(mapping, dict):
            found.update({k: v for k, v in mapping.items() if isinstance(v, str) and v})
    return found


def config_path(explicit):
    if explicit:
        return Path(explicit)
    roots = [Path(os.environ["CLAUDE_CONFIG_DIR"])] if os.environ.get("CLAUDE_CONFIG_DIR") else []
    roots += [Path.home() / ".claude", Path.home() / ".claude-work"]
    for root in roots:
        path = root / "reconcile" / "projects.json"
        if path.is_file():
            return path
    return None


def current_repo():
    try:
        name = gh_json("repo", "view", "--json", "nameWithOwner").get("nameWithOwner")
    except (GhError, AttributeError):
        return None
    return name if isinstance(name, str) and REPO_RE.fullmatch(name) else None


def current_branch_pr():
    try:
        number = gh_json("pr", "view", "--json", "number").get("number")
    except (GhError, AttributeError):
        return None
    return number if is_count(number) else None


def fetch(repo, number, workflow):
    """(pr, comments, runs) for one PR; raises GhError."""
    pr = gh_json("pr", "view", str(number), "--repo", repo, "--json", PR_FIELDS)
    if not isinstance(pr, dict) or not isinstance(pr.get("headRefOid"), str):
        raise GhError(f"gh pr view {number}: unexpected JSON")
    pages = gh_json("api", "--paginate", "--slurp", f"repos/{repo}/issues/{number}/comments")
    comments = [c for page in pages if isinstance(page, list) for c in page] if isinstance(pages, list) else []
    runs = None
    if workflow:
        runs = gh_json("run", "list", "--repo", repo, "--workflow", workflow, "--branch",
                       str(pr.get("headRefName") or ""), "--limit", "10", "--json", RUN_FIELDS)
        runs = runs if isinstance(runs, list) else []
    return pr, comments, runs


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="pr_status.py", description="Table every open PR and what it waits on.")
    parser.add_argument("numbers", nargs="*", type=int, metavar="PR")
    parser.add_argument("--repo", help="owner/name for the listed PR numbers")
    parser.add_argument("--bench-workflow", help="bench workflow file for the primary repo")
    parser.add_argument("--config", help="reconcile projects.json with bench_workflows")
    parser.add_argument("--markdown", action="store_true", help="print the Markdown table only")
    args = parser.parse_args(argv)
    if args.repo and not args.numbers:
        parser.error("--repo needs PR numbers")
    if args.repo and not REPO_RE.fullmatch(args.repo):
        parser.error("--repo must be owner/name")
    if any(n <= 0 for n in args.numbers):
        parser.error("PR numbers must be positive")
    if args.config:
        try:
            data = json.loads(Path(args.config).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = None
        if not isinstance(data, dict):
            parser.error(f"--config is not a readable JSON object: {args.config}")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        login = gh("api", "user", "--jq", ".login").strip()
    except (GhError, GhMissing) as exc:
        print(f"[X] pr-status: {exc}", file=sys.stderr)
        return 2
    cwd = os.getcwd()
    cwd_repo = current_repo()
    primary = args.repo or cwd_repo
    if not primary:
        print("[X] pr-status: no --repo and the current directory has no GitHub repo", file=sys.stderr)
        return 2
    core = load_core()
    slug = cwd_slug(core, cwd) if core else None
    targets = []  # (repo, number, explicit, submodule ref)
    if args.numbers:
        targets = [(primary, n, True, None) for n in args.numbers]
    else:
        tasks_dir = herdr_tasks_dir(core, cwd, slug) if slug else None
        for number, sub in herdr_prs(core, tasks_dir) if tasks_dir else []:
            targets.append((primary, number, False, sub))
            if sub:
                targets.append((sub["repo"], sub["number"], False, None))
        number = current_branch_pr()
        if number:
            targets.append((primary, number, False, None))
    seen, unique = set(), []
    for target in targets:
        if target[:2] not in seen:
            seen.add(target[:2])
            unique.append(target)
    unique.sort(key=lambda t: (t[0] != primary, t[0], t[1]))
    config = config_path(args.config)
    workflows = bench_workflows(config) if config else {}
    authority = merge_authority(core, cwd, slug)
    fetched = {}
    for repo, number, _explicit, _sub in unique:
        workflow = args.bench_workflow if (repo == primary and args.bench_workflow) else workflows.get(repo)
        try:
            fetched[(repo, number)] = fetch(repo, number, workflow)
        except GhError as exc:
            fetched[(repo, number)] = exc
    rows, errors = [], []
    for repo, number, explicit, sub in unique:
        prefix = None if repo == primary else repo.split("/", 1)[1]
        result = fetched[(repo, number)]
        if isinstance(result, GhError):
            rows.append({"repo": repo, "number": number, **error_row(repo, number, prefix, str(result))})
            errors.append(f"{repo}#{number}: {result}")
            continue
        pr, comments, runs = result
        if not explicit and pr.get("state") != "OPEN":
            continue
        submodule = None
        if sub:
            sub_result = fetched.get((sub["repo"], sub["number"]))
            sub_pr = sub_result[0] if isinstance(sub_result, tuple) else {}
            submodule = {**sub, "state": sub_pr.get("state"), "url": sub_pr.get("url")}
        row_authority = authority if repo == cwd_repo else "human"
        rows.append({"repo": repo, "number": number,
                     **build_row(pr, comments, runs, login, row_authority, prefix, submodule)})
    if args.markdown:
        print(markdown(rows))
    else:
        print(json.dumps({"repo": primary, "rows": rows, "errors": errors}, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
