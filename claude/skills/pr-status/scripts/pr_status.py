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
