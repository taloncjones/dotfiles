#!/usr/bin/env python3
"""todos_dashboard.py - render this repo's todo board to one HTML file.

Invoked as `todos.sh dashboard [--open] [--online] [--out PATH]
[--completed N]`; see claude/skills/todos/SKILL.md ("Dashboard").

Reads, never writes: .todos/{pending,completed,research}/ and the herdr
task records under TODOS_STATE_ROOT (default
${CLAUDE_CONFIG_DIR:-~/.claude}/herdr-orch). Dependency state comes from
todos.sh's own resolver (`_depends` / `_normalize_ref` / `_resolve`), so
there is one resolver. The only write is the output file, default
${TODOS_DASHBOARD_DIR:-${XDG_STATE_HOME:-~/.local/state}/dotfiles/dashboard}/<repo_slug>.html,
written to a sibling temp file and renamed into place.
"""
import argparse
import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TODOS_SH = Path(os.environ.get("TODOS_DASHBOARD_TODOS_SH") or HERE / "todos.sh")
TODOS_DIRNAME = ".todos"
SUMMARY_LEN = 140
RESEARCH_SUMMARY_LEN = 200
MAX_LINKS = 5
DEFAULT_COMPLETED = 10
SATISFIED = ("done", "merged")
IN_FLIGHT_STATUSES = ("kickoff", "in-progress", "blocked", "review-dispatched",
                      "changes-requested", "reviewed")
URL_RE = re.compile(r"https?://[^\s<>()\[\]\"']+")
PR_URL_RE = re.compile(r"^https?://github\.com/[^/]+/[^/]+/pull/(\d+)")
ARTIFACT_URL_RE = re.compile(r"^https?://claude\.ai/(code/)?artifacts/")
PRIORITY_WEIGHT = {"high": "0", "med": "1", "low": "2"}


def die(msg):
    print(f"todos: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"todos: {msg}", file=sys.stderr)


def esc(s):
    return html.escape(str(s), quote=True)


def safe_href(url):
    """Only http(s) URLs become links; anything else renders as text."""
    return url if re.match(r"^https?://", url) else ""


def git(args, cwd=None):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def repo_slug(remote_url, common_dir=None):
    # Mirrors herdr_orch_core.repo_slug (pinned by the dashboard test suite).
    if remote_url:
        u = remote_url.strip()
        u = re.sub(r"\.git\Z", "", u)
        u = re.sub(r"\A[a-z]+://", "", u)
        u = re.sub(r"\A[^@]+@", "", u)
        norm = re.sub(r"[^a-z0-9]+", "-", u.lower()).strip("-")
        h = hashlib.sha256(remote_url.strip().encode()).hexdigest()[:8]
        return f"{norm}-{h}"
    h = hashlib.sha256(str(Path(common_dir).resolve()).encode()).hexdigest()[:8]
    return f"local-{h}"


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def frontmatter(text):
    """Return (scalars, lists, body). Reads only the first --- block.

    scalars: first `key: value` per key, quotes stripped (frontmatter_value).
    lists: `key:` followed by `  - item` lines (depends_list / files).
    """
    lines = text.split("\n")
    scalars, lists, body_start = {}, {}, 0
    seen = set()
    if lines and lines[0].strip() == "---":
        current = None
        i = 1
        while i < len(lines):
            line = lines[i]
            if line.strip() == "---":
                body_start = i + 1
                break
            if line.startswith("  - ") and current is not None:
                lists.setdefault(current, []).append(unquote(line[4:]))
            else:
                current = None
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$", line)
                if m:
                    key, val = m.group(1), m.group(2)
                    first = key not in seen
                    seen.add(key)
                    if val == "":
                        # A blank first value claims the key (frontmatter_value
                        # returns the first line, blank or not); its list items
                        # are still collected only for the first occurrence.
                        current = key if first else None
                        if first:
                            lists[key] = []
                    elif first:
                        scalars[key] = unquote(val)
            i += 1
        else:
            body_start = len(lines)
    return scalars, lists, "\n".join(lines[body_start:])


def problem_summary(body):
    in_problem = False
    for line in body.split("\n"):
        if line.startswith("## Problem"):
            in_problem = True
            continue
        if in_problem and line.startswith("## "):
            return ""
        if in_problem and line.strip():
            return line.strip()[:SUMMARY_LEN]
    return ""


def first_body_line(body):
    for line in body.split("\n"):
        if line.strip():
            return line.strip()[:RESEARCH_SUMMARY_LEN]
    return ""


def body_links(body):
    seen, out = set(), []
    for m in URL_RE.finditer(body):
        url = m.group(0).rstrip(".,;")
        if url in seen:
            continue
        seen.add(url)
        pr = PR_URL_RE.match(url)
        if pr:
            label = f"PR #{pr.group(1)}"
        elif ARTIFACT_URL_RE.match(url):
            label = "artifact"
        else:
            label = re.sub(r"^https?://", "", url).split("/")[0]
        out.append((label, url))
        if len(out) >= MAX_LINKS:
            break
    return out


class Resolver:
    """One todos.sh call per distinct ref, results memoised for the run.

    Offline by default (TODOS_OFFLINE=1 in the child env); --online removes
    TODOS_OFFLINE from the child env even when the caller exported it.
    """

    def __init__(self, root, online):
        self.root = root
        self.env = dict(os.environ)
        if online:
            self.env.pop("TODOS_OFFLINE", None)
        else:
            self.env["TODOS_OFFLINE"] = "1"
        self.norm_cache, self.state_cache = {}, {}

    def _call(self, verb, arg):
        try:
            r = subprocess.run(["bash", str(TODOS_SH), verb, arg], cwd=self.root,
                               env=self.env, capture_output=True, text=True)
        except OSError:
            return 1, ""
        return r.returncode, r.stdout.strip()

    def depends(self, path):
        """-> (items, ok). ok is False when _depends itself failed."""
        rc, out = self._call("_depends", str(path))
        if rc != 0:
            return [], False
        return [l for l in out.split("\n") if l.strip()], True

    def normalize(self, raw):
        if raw not in self.norm_cache:
            rc, out = self._call("_normalize_ref", raw)
            self.norm_cache[raw] = out if rc == 0 and out else None
        return self.norm_cache[raw]

    def state(self, ref):
        if ref not in self.state_cache:
            rc, out = self._call("_resolve", ref)
            self.state_cache[ref] = out if rc == 0 and out else "unknown"
        return self.state_cache[ref]

    def resolve_all(self, path, basename):
        """-> list of (ref_text, state) in file order."""
        items, ok = self.depends(path)
        if not ok:
            return [("depends_on", "unreadable")]
        out = []
        for raw in items:
            ref = self.normalize(raw)
            if ref is None:
                out.append((raw, "invalid"))
            elif ref == f"todo:{basename}":
                out.append((ref, "self"))
            else:
                out.append((ref, self.state(ref)))
        return out


def read_json(path):
    """-> (dict|None, unreadable: bool). Missing file is (None, False)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None, False
    except (OSError, ValueError, UnicodeDecodeError):
        return None, True
    if not isinstance(data, dict):
        return None, True
    return data, False


def field(d, key):
    """String value of d[key] when it is a str or int; blank otherwise."""
    v = d.get(key)
    if isinstance(v, bool):
        return ""
    if isinstance(v, (str, int)):
        return str(v)
    return ""


def herdr_status(tasks_dir, basename):
    """Read-only view of tasks/td-<basename>.{json,review.json,done.json}.

    The task record is authoritative for status and the live worker. The
    review record is shown as-is only when its reviewed_head_sha equals the
    record's review_head_sha, else tagged stale; the done record only when
    its phase and agent both equal the live worker's (herdr reuses one
    workspace across phases, so workspace_id proves nothing), else stale.
    """
    task_id = f"td-{basename}"
    rec, bad = read_json(tasks_dir / f"{task_id}.json")
    if rec is None and not bad:
        return None
    st = {"task_id": task_id, "status": "", "phase": "", "role": "", "model": "",
          "agent": "", "workspace_id": "", "branch": "", "review_head_sha": "",
          "review_outcome": "", "review": "", "review_stale": False,
          "blocking_count": "", "findings_ref": "", "done_outcome": "",
          "done_phase": "", "done_stale": False, "unreadable": bad}
    if rec is not None:
        for k in ("status", "branch", "review_head_sha", "review_outcome"):
            st[k] = field(rec, k)
        workers = rec.get("workers")
        if isinstance(workers, list) and workers and isinstance(workers[-1], dict):
            w = workers[-1]
            for k in ("phase", "role", "model", "agent", "workspace_id"):
                st[k] = field(w, k)
    else:
        st["status"] = "unreadable"
    rev, bad = read_json(tasks_dir / f"{task_id}.review.json")
    if rev is not None:
        st["review"] = field(rev, "outcome") or "unknown"
        st["blocking_count"] = field(rev, "blocking_count")
        st["findings_ref"] = field(rev, "findings_ref")
        st["review_stale"] = not st["review_head_sha"] or field(rev, "reviewed_head_sha") != st["review_head_sha"]
    elif bad:
        st["review"] = "unreadable"
    done, bad = read_json(tasks_dir / f"{task_id}.done.json")
    if done is not None:
        st["done_outcome"] = field(done, "outcome")
        st["done_phase"] = field(done, "phase")
        st["done_stale"] = not (st["phase"] and st["agent"]
                                and field(done, "phase") == st["phase"]
                                and field(done, "agent") == st["agent"])
    elif bad:
        st["done_outcome"] = "unreadable"
    return st


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        warn(f"skipping unreadable file: {path} ({e.strerror})")
        return None


def load_todo(path, resolver, tasks_dir, pending):
    text = read_text(path)
    if text is None:
        return None
    scalars, lists, body = frontmatter(text)
    basename = path.stem
    t = {
        "basename": basename,
        "path": path,
        "title": scalars.get("title") or basename,
        "created": scalars.get("created", ""),
        "area": scalars.get("area", ""),
        "priority": scalars.get("priority", ""),
        "due": scalars.get("due", ""),
        "surface": scalars.get("surface", ""),
        "maturity": scalars.get("maturity", ""),
        "tier": scalars.get("tier", ""),
        "files": lists.get("files", []),
        "summary": problem_summary(body),
        "links": body_links(body),
        "deps": resolver.resolve_all(path, basename) if pending else [],
        "herdr": herdr_status(tasks_dir, basename),
    }
    t["blocked"] = any(state not in SATISFIED for _, state in t["deps"])
    h = t["herdr"]
    t["in_flight"] = bool(pending and h and h["status"] in IN_FLIGHT_STATUSES)
    return t


def load_dir(d, resolver, tasks_dir, pending):
    if not d.is_dir():
        return []
    out = []
    for p in sorted(d.glob("*.md")):
        t = load_todo(p, resolver, tasks_dir, pending)
        if t is not None:
            out.append(t)
    return out


def open_sort_key(t):
    pw = PRIORITY_WEIGHT.get(t["priority"], "3")
    if t["due"]:
        return ("0" + t["due"] + pw, t["basename"])
    return ("1" + pw + (t["created"] or "9999-99-99"), t["basename"])


def load_research(research_dir, known_basenames):
    entries = []
    if not research_dir.is_dir():
        return entries
    for p in sorted(research_dir.rglob("*.md")):
        text = read_text(p)
        if text is None:
            continue
        scalars, _, body = frontmatter(text)
        task = scalars.get("task", "")
        task_base = task[3:] if task.startswith("td-") else task
        entries.append({
            "rel": p.relative_to(research_dir).as_posix(),
            "path": p,
            "title": scalars.get("title") or p.name,
            "created": scalars.get("created", ""),
            "kind": scalars.get("kind", ""),
            "task": task,
            "task_anchor": task_base if task_base in known_basenames else "",
            "artifact": scalars.get("artifact", ""),
            "summary": first_body_line(body),
        })
    dated = [e for e in entries if e["created"]]
    undated = [e for e in entries if not e["created"]]
    dated.sort(key=lambda e: e["rel"])
    dated.sort(key=lambda e: e["created"], reverse=True)
    undated.sort(key=lambda e: e["rel"])
    return dated + undated


# --- rendering -------------------------------------------------------------

CSS = """
:root {
  --ground: #f7f6f2; --ink: #1f2a24; --muted: #6b746e; --accent: #2f6f5e;
  --rule: #d9ddd7; --blocked: #b3541e; --merged: #3b6ea5; --inflight: #8a6d1f;
  --chip: #ebeae4;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #171b19; --ink: #e8ece9; --muted: #9aa39d; --accent: #7fbfa8;
    --rule: #2c332f; --blocked: #e0895a; --merged: #7fa9d8; --inflight: #d1b25a;
    --chip: #232927;
  }
}
:root[data-theme="dark"] {
  --ground: #171b19; --ink: #e8ece9; --muted: #9aa39d; --accent: #7fbfa8;
  --rule: #2c332f; --blocked: #e0895a; --merged: #7fa9d8; --inflight: #d1b25a;
  --chip: #232927;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--ground); color: var(--ink);
  font: 15px/1.45 "Avenir Next", "Segoe UI", system-ui, sans-serif; }
main { max-width: 1200px; margin: 0 auto; padding: 32px 24px 64px; }
h1 { font-size: 26px; font-weight: 600; margin: 0 0 4px; text-wrap: balance; }
h2 { font-size: 13px; font-weight: 600; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--muted); margin: 40px 0 12px; }
.meta { color: var(--muted); font-variant-numeric: tabular-nums; }
.counts { display: flex; gap: 32px; margin: 16px 0 0; }
.counts b { font-size: 28px; font-weight: 600; font-variant-numeric: tabular-nums; }
.counts span { display: block; color: var(--muted); font-size: 13px;
  letter-spacing: 0.06em; text-transform: uppercase; }
.wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th { text-align: left; font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase;
  color: var(--muted); font-weight: 600; padding: 8px 12px; border-bottom: 1px solid var(--rule); }
td { padding: 10px 12px; border-bottom: 1px solid var(--rule); vertical-align: top; }
tr[data-state="blocked"] td:first-child { box-shadow: inset 3px 0 0 var(--blocked); }
.name { font-weight: 600; }
.mono { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 12.5px; }
.sub { color: var(--muted); font-size: 12.5px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
.chip { display: inline-block; border-radius: 999px; padding: 1px 8px; font-size: 12px;
  background: var(--chip); color: var(--ink); }
.chip.prio-high { background: var(--blocked); color: var(--ground); }
.pill { display: inline-block; border-radius: 999px; padding: 1px 8px; font-size: 12px;
  font-weight: 600; color: var(--ground); background: var(--muted); }
.pill.merged { background: var(--merged); }
.pill.in-flight { background: var(--inflight); }
.pill.unreadable { background: var(--blocked); }
.dep { display: block; white-space: nowrap; }
.dep.ok { color: var(--muted); }
.dep.bad { color: var(--blocked); }
.dates { font-variant-numeric: tabular-nums; white-space: nowrap; }
a { color: var(--accent); }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.empty { color: var(--muted); font-style: italic; }
ul.research { list-style: none; padding: 0; margin: 0; }
ul.research li { padding: 12px 0; border-bottom: 1px solid var(--rule); }
"""


def chip(text, cls=""):
    # cls is always a literal from this file, never user data; escaped anyway.
    return f'<span class="chip {esc(cls)}">{esc(text)}</span>' if text else ""


def render_herdr(h):
    if h is None:
        return ""
    status = h["status"]
    if status == "merged":
        cls = "merged"
    elif status == "unreadable":
        cls = "unreadable"
    elif status in IN_FLIGHT_STATUSES:
        cls = "in-flight"
    else:
        cls = "other"
    parts = [f'<span class="pill {cls}">{esc(status or "recorded")}</span>']
    line = " ".join(x for x in (h["phase"], h["role"], h["model"]) if x)
    if line:
        parts.append(f'<div class="sub">{esc(line)}</div>')
    if h["review"]:
        bc = f" ({esc(h['blocking_count'])} blocking)" if h["blocking_count"] != "" else ""
        stale = " (stale)" if h["review_stale"] and h["review"] != "unreadable" else ""
        parts.append(f'<div class="sub">review {esc(h["review"])}{bc}{stale}</div>')
    elif h["review_outcome"]:
        parts.append(f'<div class="sub">review {esc(h["review_outcome"])}</div>')
    if h["done_outcome"]:
        stale = " (stale)" if h["done_stale"] and h["done_outcome"] != "unreadable" else ""
        parts.append(f'<div class="sub">done {esc(h["done_outcome"])} {esc(h["done_phase"])}{stale}</div>')
    return "".join(parts)


def render_links(links):
    return " ".join(f'<a href="{esc(u)}">{esc(label)}</a>' for label, u in links)


def render_todo_cell(t):
    prio_cls = f"prio-{t['priority']}" if t["priority"] in PRIORITY_WEIGHT else ""
    chips = [chip(t["area"]), chip(t["priority"], prio_cls),
             chip(t["maturity"]), chip(t["tier"])]
    chips = "".join(c for c in chips if c)
    out = [f'<div class="name">{esc(t["title"])}</div>',
           f'<div class="sub mono">{esc(t["basename"])}</div>']
    if t["summary"]:
        out.append(f'<div class="sub">{esc(t["summary"])}</div>')
    if chips:
        out.append(f'<div class="chips">{chips}</div>')
    return "".join(out)


def render_open(todos):
    if not todos:
        return '<p class="empty">No open todos.</p>'
    rows = []
    for t in todos:
        state = "blocked" if t["blocked"] else "open"
        status = t["herdr"]["status"] if t["herdr"] else ""
        deps = "".join(
            f'<span class="dep {"ok" if s in SATISFIED else "bad"} mono">{esc(r)} ({esc(s)})</span>'
            for r, s in t["deps"])
        dates = esc(t["created"]) + (f'<br>due {esc(t["due"])}' if t["due"] else "")
        rows.append(
            f'<tr id="todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}" '
            f'data-state="{state}" data-task-status="{esc(status)}">'
            f'<td>{render_todo_cell(t)}</td><td class="dates">{dates}</td>'
            f'<td>{deps}</td><td>{render_herdr(t["herdr"])}</td>'
            f'<td>{render_links(t["links"])}</td></tr>')
    return ('<div class="wrap"><table><thead><tr><th>Todo</th><th>Created / due</th>'
            '<th>Depends on</th><th>Herdr</th><th>Links</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def render_completed(todos):
    if not todos:
        return '<p class="empty">Nothing completed yet.</p>'
    rows = []
    for t in todos:
        status = t["herdr"]["status"] if t["herdr"] else ""
        rows.append(
            f'<tr id="todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}" '
            f'data-task-status="{esc(status)}">'
            f'<td>{render_todo_cell(t)}</td><td class="dates">{esc(t["created"])}</td>'
            f'<td>{render_herdr(t["herdr"])}</td><td>{render_links(t["links"])}</td></tr>')
    return ('<div class="wrap"><table><thead><tr><th>Todo</th><th>Created</th>'
            '<th>Herdr</th><th>Links</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def render_research(entries):
    if not entries:
        return ('<p class="empty">No research reports. Save durable notes under '
                '.todos/research/ (see the todos skill).</p>')
    items = []
    for e in entries:
        bits = [f'<a href="{esc(e["path"].as_uri())}" class="name">{esc(e["title"])}</a>',
                f'<span class="meta"> {esc(e["created"] or "undated")}</span>']
        if e["kind"]:
            bits.append(" " + chip(e["kind"]))
        if e["task_anchor"]:
            bits.append(f' <a href="#todo-{esc(e["task_anchor"])}" class="mono">{esc(e["task"])}</a>')
        elif e["task"]:
            bits.append(f' <span class="mono">{esc(e["task"])}</span>')
        if e["artifact"]:
            href = safe_href(e["artifact"])
            if href:
                bits.append(f' <a href="{esc(href)}">artifact</a>')
            else:
                bits.append(f' <span class="sub">artifact: {esc(e["artifact"])}</span>')
        if e["summary"]:
            bits.append(f'<div class="sub">{esc(e["summary"])}</div>')
        items.append(f'<li data-research="{esc(e["rel"])}">{"".join(bits)}</li>')
    return '<ul class="research">' + "".join(items) + "</ul>"


def render_page(repo_name, branch, stamp, open_todos, completed, research, show_completed):
    n_open = len(open_todos)
    n_blocked = sum(1 for t in open_todos if t["blocked"])
    n_flight = sum(1 for t in open_todos if t["in_flight"])
    completed_html = ""
    if show_completed:
        completed_html = "<h2>Completed</h2>" + render_completed(completed)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(repo_name)} board</title>
<style>{CSS}</style>
</head>
<body>
<main>
<h1>{esc(repo_name)} board</h1>
<div class="meta">generated {esc(stamp)} on <span class="mono">{esc(branch)}</span>.
Static page: rerun <span class="mono">todos.sh dashboard</span> and reload to refresh.</div>
<div class="counts">
<div><b data-count="open">{n_open}</b><span>open</span></div>
<div><b data-count="blocked">{n_blocked}</b><span>blocked</span></div>
<div><b data-count="in-flight">{n_flight}</b><span>in-flight</span></div>
</div>
<h2>Open</h2>
{render_open(open_todos)}
{completed_html}
<h2>Research</h2>
{render_research(research)}
</main>
</body>
</html>
"""


# --- main -------------------------------------------------------------------

def default_out_dir():
    d = os.environ.get("TODOS_DASHBOARD_DIR")
    if d:
        return Path(d)
    state = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(state) / "dotfiles" / "dashboard"


def default_state_root():
    d = os.environ.get("TODOS_STATE_ROOT")
    if d:
        return Path(d)
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(cfg) / "herdr-orch"


def is_within(path, parent):
    """True when the real path of `path` is `parent` or inside it."""
    try:
        Path(os.path.realpath(path)).relative_to(Path(os.path.realpath(parent)))
        return True
    except ValueError:
        return False


def guard_out_path(out, protected):
    """Refuse to write under .todos/ or the state root, through symlinks too."""
    probe = out if out.exists() else out.parent
    for label, p in protected:
        if is_within(probe, p):
            die(f"refusing to write the dashboard under {label}: {out}")


def open_file(path):
    """Best-effort, detached: never waited on, never touches stdout."""
    opener = os.environ.get("TODOS_DASHBOARD_OPENER") or ("open" if sys.platform == "darwin" else "xdg-open")
    try:
        subprocess.Popen([opener, str(path)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        warn(f"cannot open {path}: {opener}: {e.strerror or e}")


USAGE = "usage: todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]"


class Parser(argparse.ArgumentParser):
    def error(self, message):
        die(f"{message} ({USAGE})")


def parse_args(argv):
    p = Parser(prog="todos.sh dashboard", add_help=True)
    p.add_argument("--open", action="store_true")
    p.add_argument("--online", action="store_true")
    p.add_argument("--out")
    p.add_argument("--completed", type=int, default=DEFAULT_COMPLETED)
    args = p.parse_args(argv)
    if args.completed < 0:
        die("--completed needs a non-negative integer")
    return args


def visibility_warning(root):
    """Warn when .todos/ is neither git-ignored nor tracked (research would commit)."""
    rc, _ = git(["check-ignore", "-q", TODOS_DIRNAME], cwd=root)
    if rc == 0:
        return
    rc, out = git(["ls-files", "--", TODOS_DIRNAME], cwd=root)
    if rc == 0 and out:
        return
    warn(f"{TODOS_DIRNAME}/ is neither git-ignored nor tracked; run `todos.sh init` "
         "before saving research there")


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    rc, root = git(["rev-parse", "--show-toplevel"])
    if rc != 0 or not root:
        die("not inside a git repository")
    root = Path(root)
    rc, remote = git(["remote", "get-url", "origin"], cwd=root)
    if rc != 0:
        remote = ""
    _, common = git(["rev-parse", "--git-common-dir"], cwd=root)
    slug = repo_slug(remote, common_dir=root / common if common else root)
    _, branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root)

    todos_dir = root / TODOS_DIRNAME
    state_root = default_state_root()
    tasks_dir = state_root / slug / "tasks"
    out = Path(args.out) if args.out else default_out_dir() / f"{slug}.html"
    out = out if out.is_absolute() else Path.cwd() / out
    guard_out_path(out, [(f"{TODOS_DIRNAME}/", todos_dir), ("the herdr state root", state_root)])

    if todos_dir.is_dir():
        visibility_warning(root)
    resolver = Resolver(root, args.online)
    pending = load_dir(todos_dir / "pending", resolver, tasks_dir, True)
    completed = load_dir(todos_dir / "completed", resolver, tasks_dir, False)
    pending.sort(key=open_sort_key)
    completed.sort(key=lambda t: (t["created"], t["basename"]), reverse=True)
    completed = completed[:args.completed]
    known = {t["basename"] for t in pending} | {t["basename"] for t in completed}
    research = load_research(todos_dir / "research", known)

    stamp = os.environ.get("TODOS_DASHBOARD_NOW") or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    page = render_page(root.name, branch, stamp, pending, completed, research, args.completed > 0)

    tmp = out.with_name(out.name + f".tmp.{os.getpid()}")
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        # O_EXCL|O_NOFOLLOW: a planted file or symlink at the temp name fails
        # here instead of being followed; nothing is written through it.
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(page)
        os.replace(tmp, out)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"cannot write {out}: {e.strerror or e}")
    print(out)
    if args.open:
        open_file(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
