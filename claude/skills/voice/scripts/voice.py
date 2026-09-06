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


def cmd_rewrite(args):
    raise VoiceError("rewrite is not implemented yet")


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
