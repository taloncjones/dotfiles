"""Git proofs behind the co-review carry-forward marker and the delta tier."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _load_review():
    spec = importlib.util.spec_from_file_location(
        "co_review_review", Path(__file__).with_name("review.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_review = _load_review()
ProofError = _review.ReviewError
commit = _review.full_commit
# Literal pathspecs and forced flags: a repo's diff driver, textconv filter or
# rename detection must not change what the proofs compare.
_DIFF = (
    "--literal-pathspecs", "-c", "core.quotePath=true", "diff",
    "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
)


def _rev_list(repo: Path, *args: str) -> list[str]:
    return _review.text_git(repo, "rev-list", *args).split()


def _names(repo: Path, old: str, new: str, paths: list[str] | None = None) -> list[str]:
    raw = _review.git(repo, *_DIFF, "--name-only", "-z", old, new, "--", *(paths or []))
    return [name for name in raw.decode("utf-8", "surrogateescape").split("\0") if name]


def _body(repo: Path, old: str, new: str, path: str) -> list[str] | None:
    """Ordered +/- hunk lines of one file's diff; None for a binary diff."""
    text = _review.git(repo, *_DIFF, old, new, "--", path).decode("utf-8", "surrogateescape")
    lines: list[str] = []
    in_hunk = False
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            in_hunk = False
        elif line.startswith("@@"):
            in_hunk = True
        elif not in_hunk:
            if line.startswith(("Binary files ", "GIT binary patch")):
                return None
        elif line[:1] in ("+", "-"):
            lines.append(line)
    return lines


def _modes(repo: Path, old: str, new: str, path: str) -> tuple[str, str]:
    """Old and new mode of one file's diff (type included); empty when the mode is unchanged."""
    raw = _review.git(repo, *_DIFF, "--raw", "-z", old, new, "--", path)
    fields = raw.decode("utf-8", "surrogateescape").split(" ", 2)
    if len(fields) < 3 or fields[0].lstrip(":") == fields[1]:
        return ("", "")
    return (fields[0].lstrip(":"), fields[1])


def carry_forward(repo: Path, gated_head: str, head: str, upstream: str) -> dict:
    """Prove head differs from gated_head only by merges of upstream (spec R3-R5)."""
    record = {
        "pass": False, "reasons": [], "prior_head": None, "head": None,
        "upstream": upstream, "base": None, "old_base": None, "new_base": None,
        "proofs": [],
    }
    reasons, proofs = record["reasons"], record["proofs"]

    def proof(name: str, argv: list[str], output: list[str]) -> list[str]:
        proofs.append({"name": name, "argv": ["git", *argv], "output": output})
        return output

    try:
        gated, current, base = (commit(repo, ref) for ref in (gated_head, head, upstream))
        record.update(prior_head=gated, head=current, base=base)
        argv = ["rev-list", f"{current}..{gated}"]
        if proof("ancestry", argv, _rev_list(repo, *argv[1:])):
            reasons.append(f"gated head {gated} is not an ancestor of {current}")
        argv = ["rev-list", "--no-merges", f"{base}..{current}"]
        now = proof("commits-head", argv, _rev_list(repo, *argv[1:]))
        argv = ["rev-list", "--no-merges", f"{base}..{gated}"]
        then = set(proof("commits-gated", argv, _rev_list(repo, *argv[1:])))
        added = [sha for sha in now if sha not in then]
        if added:
            reasons.append("branch-authored commits since the gated head: " + " ".join(added))
        old_base = _review.text_git(repo, "merge-base", base, gated)
        new_base = _review.text_git(repo, "merge-base", base, current)
        record.update(old_base=old_base, new_base=new_base)
        own = proof("branch-files", ["diff", "--name-only", old_base, gated],
                    _names(repo, old_base, gated))
        # Also check files upstream touched: a merge keeping the branch side
        # leaves them equal to the gated version yet drops upstream's hunks.
        moved = _names(repo, gated, current, own) if own else []
        upstream_moved = _names(repo, old_base, new_base, own) if own else []
        changed = sorted(set(moved) | set(upstream_moved))
        proof("changed-branch-files", ["diff", "--name-only", gated, current, "--", *own], moved)
        for path in changed:
            upstream_now = _body(repo, gated, current, path)
            upstream_ref = _body(repo, old_base, new_base, path)
            own_then = _body(repo, old_base, gated, path)
            own_now = _body(repo, new_base, current, path)
            same_upstream = (
                upstream_now is not None and upstream_now == upstream_ref
                and _modes(repo, gated, current, path) == _modes(repo, old_base, new_base, path)
            )
            same_own = (
                own_then is not None and own_then == own_now
                and _modes(repo, old_base, gated, path) == _modes(repo, new_base, current, path)
            )
            proof(f"hunks {path}", ["diff", gated, current, "--", path],
                  [f"upstream-equal: {str(same_upstream).lower()}",
                   f"branch-equal: {str(same_own).lower()}"])
            if None in (upstream_now, upstream_ref, own_then, own_now):
                reasons.append(f"{path}: binary change")
            elif not same_upstream:
                reasons.append(f"{path}: hunk or mode change since the gated head is not upstream's")
            elif not same_own:
                reasons.append(f"{path}: branch hunks or mode changed")
        scope = proof("scope", ["diff", "--name-only", new_base, current],
                      _names(repo, new_base, current))
        extra = sorted(set(scope) - set(own))
        if extra:
            reasons.append("files outside the branch's own set: " + ", ".join(extra))
    except ProofError as error:
        reasons.append(f"git proof failed: {error}")
    record["pass"] = not reasons
    return record


def delta_range(repo: Path, anchor: str, head: str) -> dict:
    """Facts about anchor..head the delta tier checks (spec R15 steps 4-6)."""
    start, end = commit(repo, anchor), commit(repo, head)
    return {
        "anchor": start,
        "head": end,
        "ancestor": not _rev_list(repo, f"{end}..{start}"),
        "merges": _rev_list(repo, "--merges", f"{start}..{end}"),
        "diff": _review.git(repo, *_DIFF, "--binary", start, end),
    }


def derive_anchor(repo: Path, gated_head: str, head: str) -> str:
    """The merge M in gated..head with no merge in M..head, else gated (spec [D6])."""
    gated, end = commit(repo, gated_head), commit(repo, head)
    for merge in _rev_list(repo, "--merges", f"{gated}..{end}"):
        if not _rev_list(repo, "--merges", f"{merge}..{end}"):
            return merge
    return gated
