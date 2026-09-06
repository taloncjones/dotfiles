#!/usr/bin/env python3
"""voice.py - a second-model voice pass for outward-facing text.

    voice.py lint    --kind K (--file F | --stdin)
    voice.py rewrite --kind K (--file F | --stdin | --pr N | --range F:A-B)
                     [--effort high|xhigh] [--dry-run] [--json]

lint applies a fixed table of mechanical checks and needs no model.
rewrite asks Codex for a rewrite, verifies invariants on the way back, and
prints a before/after report with the exact apply command. It never posts.

Exit codes: 0 nothing to change, 1 findings or a rewrite proposed, 2 error.
A run with several units (--pr gives title and body) exits with the max.
"""
import argparse
import difflib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
RULES_PATH = os.path.join(HERE, "..", "rules.md")
CODEX_MODEL = "gpt-6-astra"
TEXT_KINDS = ("pr-title", "pr-body", "pr-comment",
              "jira-title", "jira-description", "jira-comment")
ALL_KINDS = TEXT_KINDS + ("code-comment",)

ADDENDA = {
    "pr-title": "Shape: `<scope>: <summary>`, imperative mood, under 75 characters.",
    "pr-body": ("Keep the Description and Test plan sections. Keep the Jira link "
                "line at the bottom byte-for-byte."),
    "pr-comment": "Lead with the verdict. No process narration.",
    "jira-title": ("State the outcome or impact in 6-10 plain words. No codenames, "
                   "filenames, function names, error codes, or unexpanded "
                   "abbreviations."),
    "jira-description": ("Short declaratives, one meaning per word. No template "
                         "heading with nothing under it."),
    "jira-comment": "Current state first. No process narration.",
    "code-comment": ("Tighten each candidate line; never delete one. Return code "
                     "and protected lines exactly as given."),
}


class VoiceError(Exception):
    """Fatal, user-facing; main() prints it and exits 2."""


# --- lint: table of mechanical rules, no model -----------------------------

EMOJI_RE = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\uFE0F]")
# The trailer pattern is built from two fragments so this file never holds
# the phrase the repo's attribution guards look for.
_TRAILER = "co-authored" + "-by:"
ATTRIBUTION_RES = [
    re.compile(r"^" + _TRAILER + r".*\b(claude|anthropic|copilot|chatgpt|gpt|codex|openai)\b",
               re.I | re.M),
    re.compile(r"generated (by|with)\b.*\b(claude|anthropic|copilot|chatgpt|gpt|codex|openai|ai)\b",
               re.I),
    re.compile(r"\b(written by ai|ai-generated)\b", re.I),
]
FILLER_WORDS = ("comprehensive", "robust", "seamless", "leverage", "delve",
                "streamline", "it is worth noting", "in order to")
FILLER_RES = [re.compile(r"\b" + re.escape(w) + r"\b", re.I) for w in FILLER_WORDS]
FILLER_RES.append(re.compile(r"(?:^|\n|\. )(Ensures?)\b"))
HEDGE_WORDS = ("might", "may want to", "it seems", "should probably")
HEDGE_RES = [re.compile(r"\b" + re.escape(w) + r"\b", re.I) for w in HEDGE_WORDS]
HEADING_RE = re.compile(r"^#{1,6} \S.*$")
TITLE_TOKEN_RES = (
    ("filename", re.compile(r"\b\w+\.(?:py|sh|rs|md|json|yml|yaml|toml|js|ts)\b")),
    ("function call", re.compile(r"\w+\(\)")),
    ("identifier", re.compile(r"\b\w+_\w+\b|::")),
    ("code", re.compile(r"\b(?:0x[0-9A-Fa-f]+|E\d{3,})\b")),
)
PR_TITLE_RE = re.compile(r"^[a-z][a-z0-9/_-]*: \S")


def lint_emoji(kind, text):
    return ["emoji: U+%04X" % ord(m.group()) for m in EMOJI_RE.finditer(text)]


def lint_attribution(kind, text):
    out = []
    for rx in ATTRIBUTION_RES:
        for m in rx.finditer(text):
            out.append("attribution: " + m.group().strip())
    return out


def lint_filler(kind, text):
    out = []
    for rx in FILLER_RES:
        for m in rx.finditer(text):
            word = m.group(1) if m.groups() else m.group()
            out.append("filler: " + word.strip())
    return out


def lint_hedge(kind, text):
    out = []
    for rx in HEDGE_RES:
        for m in rx.finditer(text):
            out.append("hedge: " + m.group().strip())
    return out


def lint_empty_heading(kind, text):
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        if not HEADING_RE.match(line):
            continue
        body = []
        for later in lines[i + 1:]:
            if HEADING_RE.match(later):
                break
            body.append(later)
        if not any(b.strip() for b in body):
            out.append("empty-heading: " + line.strip())
    return out


def lint_title_shape(kind, text):
    title = text.strip()
    out = []
    if kind == "jira-title":
        words = title.split()
        if len(words) > 12:
            out.append("title-shape: %d words, over 12" % len(words))
        if len(words) < 4:
            out.append("title-shape: %d words, under 4" % len(words))
        for label, rx in TITLE_TOKEN_RES:
            m = rx.search(title)
            if m:
                out.append("title-shape: %s %s" % (label, m.group()))
    elif kind == "pr-title":
        if not PR_TITLE_RE.match(title):
            out.append("title-shape: missing <scope>: prefix")
        if len(title) >= 75:
            out.append("title-shape: %d chars, 75 or more" % len(title))
    return out


LINT_RULES = (lint_emoji, lint_attribution, lint_filler, lint_hedge,
              lint_empty_heading, lint_title_shape)


def lint_text(kind, text):
    findings = []
    for rule in LINT_RULES:
        findings.extend(rule(kind, text))
    return findings


# --- CLI -------------------------------------------------------------------

def read_input(args):
    if getattr(args, "file", None):
        with open(args.file, encoding="utf-8") as f:
            return f.read()
    if getattr(args, "stdin", False):
        return sys.stdin.read()
    raise VoiceError("give one of --file, --stdin, --pr, or --range")


def check_kind(kind):
    if kind not in ALL_KINDS:
        raise VoiceError("unknown kind %r; kinds: %s" % (kind, ", ".join(ALL_KINDS)))


def cmd_lint(args):
    check_kind(args.kind)
    text = read_input(args)
    findings = lint_text(args.kind, text)
    for f in findings:
        print(f)
    return 1 if findings else 0


# --- rewrite: prompt, Codex call, invariants, report -----------------------

INVARIANT_EXTRACTORS = {
    "url": re.compile(r"https?://\S+"),
    "jira-key": re.compile(r"\b[A-Z][A-Z0-9]+-[0-9]+\b"),
    "fence": re.compile(r"```.*?```", re.S),
    "inline": re.compile(r"`[^`\n]+`"),
}
INVARIANTS_BY_KIND = {
    "pr-title": ("url", "jira-key"),
    "jira-title": ("url", "jira-key"),
    "pr-comment": ("url", "jira-key", "fence"),
    "jira-comment": ("url", "jira-key", "fence"),
    "pr-body": ("url", "jira-key", "fence", "inline"),
    "jira-description": ("url", "jira-key", "fence", "inline"),
    "code-comment": (),
}


def read_rules():
    with open(RULES_PATH, encoding="utf-8") as f:
        return f.read()


def invariants_text(kind):
    names = INVARIANTS_BY_KIND[kind]
    if kind == "code-comment":
        return "Every line whose status is code or protected comes back byte-identical."
    return "Copy byte-for-byte every: %s." % ", ".join(names)


def build_prompt(kind, text, rows=None):
    parts = [read_rules().rstrip("\n"), "",
             "=== KIND: %s ===" % kind, ADDENDA[kind], "",
             "=== INVARIANTS ===", invariants_text(kind), "",
             "=== OUTPUT ==="]
    if kind == "code-comment":
        parts += ['Return JSON: {"lines": [{"n": <line number>, "text": <line>}], '
                  '"changes": [{"before": ..., "after": ..., "rule": ...}]} with '
                  "exactly one entry per input line, in order.", "",
                  "=== LINES ==="]
        parts += ["%d|%s|%s" % (n, status, line) for n, status, line, _ in rows]
    else:
        parts += ['Return JSON: {"rewritten": <the full text>, '
                  '"changes": [{"before": ..., "after": ..., "rule": ...}]}.', "",
                  "=== TEXT ===", text]
    prompt = "\n".join(parts)
    # Text ends the prompt; do not add a newline the input did not have, or
    # the model's faithful copy diffs against the input at EOF.
    return prompt if prompt.endswith("\n") else prompt + "\n"


def schema_for(kind):
    change = {"type": "object",
              "properties": {"before": {"type": "string"},
                             "after": {"type": "string"},
                             "rule": {"type": "string"}},
              "required": ["before", "after", "rule"],
              "additionalProperties": False}
    if kind == "code-comment":
        line = {"type": "object",
                "properties": {"n": {"type": "integer"}, "text": {"type": "string"}},
                "required": ["n", "text"], "additionalProperties": False}
        props = {"lines": {"type": "array", "items": line},
                 "changes": {"type": "array", "items": change}}
    else:
        props = {"rewritten": {"type": "string"},
                 "changes": {"type": "array", "items": change}}
    return {"type": "object", "properties": props,
            "required": list(props), "additionalProperties": False}


def run_codex(prompt, kind, effort, workdir):
    scratch = tempfile.mkdtemp(prefix="scratch.", dir=workdir)
    prompt_path = os.path.join(workdir, "prompt.txt")
    schema_path = os.path.join(workdir, "schema.json")
    last_path = os.path.join(workdir, "last.json")
    log_path = os.path.join(workdir, "codex.log")
    with open(prompt_path, "w", encoding="utf-8") as f:
        f.write(prompt)
    with open(schema_path, "w") as f:
        json.dump(schema_for(kind), f)
    cmd = [os.environ.get("VOICE_CODEX_BIN", "codex"), "exec", "-",
           "-m", CODEX_MODEL,
           "-c", 'model_reasoning_effort="%s"' % effort,
           "-c", 'approval_policy="never"',
           "-c", 'sandbox_mode="read-only"',
           "-C", scratch, "--skip-git-repo-check", "--ephemeral",
           "--output-schema", schema_path, "-o", last_path]
    with open(prompt_path, "rb") as pin, open(log_path, "wb") as log:
        rc = subprocess.call(cmd, stdin=pin, stdout=log, stderr=subprocess.STDOUT)
    if rc != 0:
        raise VoiceError("codex exited %d; log: %s" % (rc, log_path))
    try:
        with open(last_path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise VoiceError("codex output is not JSON (%s); log: %s" % (e, log_path))
    if not isinstance(data, dict) or not isinstance(data.get("changes"), list):
        raise VoiceError("codex output missing changes; log: %s" % log_path)
    for c in data["changes"]:
        if not all(isinstance(c.get(k), str) for k in ("before", "after", "rule")):
            raise VoiceError("codex change entry malformed; log: %s" % log_path)
    return data


def check_invariants(kind, before, after):
    """Each protected token must survive with its exact multiset intact: same
    count, byte-identical text. A superstring (DOT-42 -> DOT-420) or a dropped
    duplicate both show up as the original token's count falling in `after`."""
    missing = []
    for name in INVARIANTS_BY_KIND[kind]:
        before_counts = Counter(INVARIANT_EXTRACTORS[name].findall(before))
        after_counts = Counter(INVARIANT_EXTRACTORS[name].findall(after))
        for token, count in before_counts.items():
            if after_counts.get(token, 0) < count:
                missing.append("%s %s" % (name, token))
    return missing


def normalize(text):
    return "\n".join(line.rstrip() for line in text.rstrip().splitlines())


def make_report(kind, target, text, lint, after=None, changes=None,
                protected=None, apply=None, status=None):
    if status is None:
        status = "unchanged" if normalize(after) == normalize(text) else "changed"
    diff = ""
    if status == "changed":
        diff = "".join(difflib.unified_diff(
            text.splitlines(True), after.splitlines(True), "before", "after"))
        if diff and not diff.endswith("\n"):
            diff += "\n"
    return {"kind": kind, "target": target, "status": status, "lint": lint,
            "before": text, "after": after if after is not None else text,
            "diff": diff, "changes": changes or [], "protected": protected or [],
            "apply": apply if status == "changed" else None}


def report_text(r):
    head = "%d changes" % len(r["changes"]) if r["status"] == "changed" else r["status"]
    lines = ["VOICE %s %s: %s" % (r["kind"], r["target"], head)]
    if r["lint"]:
        lines.append("Lint:")
        lines += ["  " + f for f in r["lint"]]
    if r["status"] == "changed":
        lines.append(r["diff"].rstrip("\n"))
        lines.append("Changes:")
        for i, c in enumerate(r["changes"], 1):
            lines.append('  %d. %s: "%s" -> "%s"' % (i, c["rule"], c["before"], c["after"]))
    if r["protected"]:
        lines.append("Protected (left alone):")
        lines += ["  " + p for p in r["protected"]]
    if r["apply"]:
        lines.append("Apply with:")
        lines += ["  " + a for a in r["apply"].splitlines()]
    return "\n".join(lines) + "\n"


def run_text_unit(kind, target, text, args, workdir, apply=None):
    lint = lint_text(kind, text)
    if not text.strip():
        return make_report(kind, target, text, lint, status="empty")
    prompt = build_prompt(kind, text)
    if args.dry_run:
        sys.stdout.write(prompt)
        return make_report(kind, target, text, lint, status="dry-run")
    unit_dir = tempfile.mkdtemp(prefix="unit.", dir=workdir)
    data = run_codex(prompt, kind, args.effort, unit_dir)
    after = data.get("rewritten")
    if not isinstance(after, str):
        raise VoiceError("codex output missing rewritten; log: %s"
                         % os.path.join(unit_dir, "codex.log"))
    missing = check_invariants(kind, text, after)
    if missing:
        raise VoiceError("invariant violated: " + "; ".join(missing))
    return make_report(kind, target, text, lint, after, data["changes"],
                       apply=apply or "paste the after block")


def fetch_pr(number):
    gh = os.environ.get("VOICE_GH_BIN", "gh")
    cmd = [gh, "pr", "view", str(number), "--json", "title,body"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        raise VoiceError("gh pr view failed to start: %s" % e)
    if proc.returncode != 0:
        raise VoiceError("gh pr view %d failed: %s" % (number, proc.stderr.strip()))
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        raise VoiceError("gh pr view %d returned non-JSON output" % number)
    return data.get("title") or "", data.get("body") or ""


def pr_units(number, args, workdir):
    title, body = fetch_pr(number)
    body_path = os.path.join(workdir, "pr-%d-body.md" % number)
    title_report = run_text_unit("pr-title", "PR #%d title" % number, title, args, workdir,
                                 apply="gh pr edit %d --title <after>" % number)
    if title_report["status"] == "changed":
        title_report["apply"] = "gh pr edit %d --title %s" % (
            number, shlex.quote(title_report["after"].strip()))
    body_report = run_text_unit("pr-body", "PR #%d body" % number, body, args, workdir,
                                apply="gh pr edit %d --body-file %s" % (number, body_path))
    if body_report["status"] == "changed":
        with open(body_path, "w", encoding="utf-8") as f:
            f.write(body_report["after"])
    return [title_report, body_report]


# --- range unit: code-comment with load-bearing protection -----------------

RANGE_RE = re.compile(r"^(.+):(\d+)-(\d+)$")
DEF_RE = re.compile(r"^\s*(?:async\s+)?(?:def|class)\s+(\w+)")
COMMENT_PREFIXES = ("#", "//", "/*", "*")
MIN_REFERENCE_LEN = 12


def parse_range(spec):
    m = RANGE_RE.match(spec or "")
    if not m:
        raise VoiceError("--range must be FILE:A-B")
    return m.group(1), int(m.group(2)), int(m.group(3))


def repo_root(path):
    # realpath everywhere: on macOS mktemp gives /var/... while git reports
    # /private/var/..., and grep echoes whichever root it was handed. One
    # canonical form keeps the self-exclusion below and the relpath in the
    # reason strings consistent.
    proc = subprocess.run(["git", "-C", os.path.dirname(os.path.realpath(path)),
                           "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        return os.path.realpath(proc.stdout.strip())
    return os.path.dirname(os.path.realpath(path))


def grep_files(needle, root, exclude_path):
    """Fixed-string, recursive, file names only; drops exclude_path itself."""
    proc = subprocess.run(["grep", "-rIlF", "--exclude-dir=.git", "--", needle, root],
                          capture_output=True, text=True)
    skip = os.path.realpath(exclude_path)
    hits = [h for h in proc.stdout.splitlines() if os.path.realpath(h) != skip]
    return sorted(hits)


def referenced_elsewhere(text, root, path):
    needle = text.strip().lstrip("#/* ").strip().rstrip('"').strip()
    if len(needle) < MIN_REFERENCE_LEN:
        return None
    hits = grep_files(needle, root, path)
    if hits:
        return "referenced elsewhere (%s)" % os.path.relpath(hits[0], root)
    return None


def docstring_displayed(owner, root, path):
    if not owner:
        return None
    for needle in (owner + ".__doc__", "getdoc(" + owner, owner + ".doc"):
        hits = grep_files(needle, root, path)
        if hits:
            return "docstring displayed (%s in %s)" % (needle, os.path.relpath(hits[0], root))
    return None


def classify_range(path, start, end):
    path = os.path.realpath(path)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    if start < 1 or end > len(lines) or start > end:
        raise VoiceError("range %d-%d out of bounds for %s (%d lines)"
                         % (start, end, path, len(lines)))
    root = repo_root(path)
    rows = []
    in_doc = False
    owner = None
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        m = DEF_RE.match(line)
        if m:
            owner = m.group(1)
        is_doc = False
        if in_doc:
            is_doc = True
            if '"""' in stripped:
                in_doc = False
        elif stripped.startswith('"""'):
            is_doc = True
            if stripped.count('"""') < 2:
                in_doc = True
        if not (start <= n <= end):
            continue
        if is_doc:
            reason = docstring_displayed(owner, root, path) or referenced_elsewhere(line, root, path)
        elif stripped.startswith(COMMENT_PREFIXES):
            reason = referenced_elsewhere(line, root, path)
        else:
            rows.append((n, "code", line, ""))
            continue
        if reason:
            rows.append((n, "protected", line, reason))
        else:
            rows.append((n, "candidate", line, ""))
    return rows


def run_range_unit(path, start, end, args, workdir):
    rows = classify_range(path, start, end)
    text = "\n".join(line for _, _, line, _ in rows) + "\n"
    target = "%s:%d-%d" % (path, start, end)
    lint = lint_text("code-comment", text)
    protected = ["%s:%d  protected: %s" % (os.path.basename(path), n, reason)
                 for n, status, _, reason in rows if status == "protected"]
    if not any(status == "candidate" for _, status, _, _ in rows):
        return make_report("code-comment", target, text, lint, protected=protected,
                           status="unchanged")
    prompt = build_prompt("code-comment", text, rows)
    if args.dry_run:
        sys.stdout.write(prompt)
        return make_report("code-comment", target, text, lint, status="dry-run")
    unit_dir = tempfile.mkdtemp(prefix="unit.", dir=workdir)
    data = run_codex(prompt, "code-comment", args.effort, unit_dir)
    got = data.get("lines")
    if not isinstance(got, list) or [g.get("n") for g in got] != [n for n, _, _, _ in rows]:
        raise VoiceError("codex returned lines that do not match %d-%d; log: %s"
                         % (start, end, os.path.join(unit_dir, "codex.log")))
    new_lines = []
    replacements = []
    for (n, status, line, _), g in zip(rows, got):
        new = g.get("text")
        if not isinstance(new, str):
            raise VoiceError("codex line %d is not a string" % n)
        if status != "candidate" and new != line:
            raise VoiceError("invariant violated: line %d changed (%s)" % (n, status))
        if new != line:
            replacements.append("replace line %d with: %s" % (n, new))
        new_lines.append(new)
    after = "\n".join(new_lines) + "\n"
    return make_report("code-comment", target, text, lint, after, data["changes"],
                       protected=protected, apply="\n".join(replacements))


STATUS_RC = {"dry-run": 0, "empty": 0, "unchanged": 0, "changed": 1}


def emit(reports, args):
    if args.as_json:
        json.dump(reports, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif not args.dry_run:
        for r in reports:
            sys.stdout.write(report_text(r))
    return max(STATUS_RC[r["status"]] for r in reports)


def cmd_rewrite(args):
    workdir = tempfile.mkdtemp(prefix="voice.")
    if args.pr is not None:
        return emit(pr_units(args.pr, args, workdir), args)
    if args.line_range:
        if args.kind != "code-comment":
            raise VoiceError("--range requires --kind code-comment")
        path, start, end = parse_range(args.line_range)
        return emit([run_range_unit(path, start, end, args, workdir)], args)
    check_kind(args.kind)
    if args.kind == "code-comment":
        raise VoiceError("code-comment needs --range FILE:A-B")
    text = read_input(args)
    target = args.file if args.file else "stdin"
    reports = [run_text_unit(args.kind, target, text, args, workdir)]
    return emit(reports, args)


def parse_args(argv):
    p = argparse.ArgumentParser(prog="voice.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("lint", "rewrite"):
        sp = sub.add_parser(name)
        sp.add_argument("--kind", default=None)
        sp.add_argument("--file")
        sp.add_argument("--stdin", action="store_true")
        if name == "rewrite":
            sp.add_argument("--pr", type=int)
            sp.add_argument("--range", dest="line_range",
                            help="FILE:A-B, code-comment only")
            sp.add_argument("--effort", choices=("high", "xhigh"), default="high")
            sp.add_argument("--dry-run", action="store_true")
            sp.add_argument("--json", dest="as_json", action="store_true")
    args = p.parse_args(argv)
    if args.kind is None and not (args.cmd == "rewrite" and args.pr is not None):
        p.error("%s requires --kind" % args.cmd)
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        if args.cmd == "lint":
            return cmd_lint(args)
        return cmd_rewrite(args)
    except VoiceError as e:
        sys.stderr.write("voice: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
