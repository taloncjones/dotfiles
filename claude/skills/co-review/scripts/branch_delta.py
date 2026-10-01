"""Git proofs behind the co-review carry-forward marker and the delta tier."""

from __future__ import annotations

import importlib.util
import subprocess
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
_DIFF_BASE = (
    "--literal-pathspecs", "-c", "core.quotePath=true", "diff",
    "--no-color", "--no-ext-diff", "--no-textconv",
)
_DIFF = (*_DIFF_BASE, "--no-renames")


def _rev_list(repo: Path, *args: str) -> list[str]:
    return _review.text_git(repo, "rev-list", *args).split()


def _names(repo: Path, old: str, new: str, paths: list[str] | None = None) -> list[str]:
    raw = _review.git(repo, *_DIFF, "--name-only", "-z", old, new, "--", *(paths or []))
    return [name for name in raw.decode("utf-8", "surrogateescape").split("\0") if name]


def _follow_upstream(
    repo: Path, old_base: str, new_base: str, own: set[str]
) -> tuple[set[str], list[str]]:
    """Own names plus both sides of upstream renames touching them, and upstream-deleted own paths."""
    raw = _review.git(repo, *_DIFF_BASE, "--find-renames", "--name-status", "-z", old_base, new_base)
    fields = raw.decode("utf-8", "surrogateescape").split("\0")
    followed, deleted, index = set(own), [], 0
    while index < len(fields) and fields[index]:
        status = fields[index][0]
        width = 3 if status in "RC" else 2
        names = fields[index + 1:index + width]
        index += width
        if status == "D" and names[0] in own:
            deleted.append(names[0])
        if status in "RC" and own & set(names):
            followed.update(names)
    return followed, deleted


def _merge_tree(repo: Path, ours: str, theirs: str) -> tuple[str, list[str]]:
    """Tree of git's own merge of ours and theirs, plus its conflicted paths."""
    result = subprocess.run(
        ["git", "-C", str(repo), "merge-tree", "--write-tree", "--name-only", "-z", ours, theirs],
        capture_output=True, env=_review.git_environment(), check=False,
    )
    if result.returncode not in (0, 1):
        raise ProofError(result.stderr.decode(errors="replace").strip() or "git merge-tree failed")
    fields = result.stdout.decode("utf-8", "surrogateescape").split("\0")
    conflicted = [name for name in fields[1:] if name] if result.returncode else []
    return fields[0], conflicted


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
        branch_own = proof("branch-files", ["diff", "--name-only", old_base, gated],
                          _names(repo, old_base, gated))
        # An upstream rename moves a branch file to a name the branch diff never
        # shows; follow it so the byte-exact comparison covers the new path.
        followed, deleted = _follow_upstream(repo, old_base, new_base, set(branch_own))
        own = sorted(followed)
        for path in sorted(deleted):
            reasons.append(f"{path}: deleted upstream while the branch changes it")
        # Byte-exact: head's own paths must equal git's merge of the gated head
        # with the new base, so a moved or hand-resolved line cannot pass.
        moved = _names(repo, gated, current, own) if own else []
        proof("changed-branch-files", ["diff", "--name-only", gated, current, "--", *own], moved)
        merged, conflicted = _merge_tree(repo, gated, new_base)
        for path in sorted(set(conflicted) & set(own)):
            reasons.append(f"{path}: merging upstream conflicts with the branch")
        differs = set(_names(repo, merged, current, own)) if own else set()
        for path in sorted(set(moved) | set(_names(repo, old_base, new_base, own) if own else [])
                           | differs):
            equal = path not in differs
            proof(f"hunks {path}", ["diff", merged, current, "--", path],
                  [f"merge-equal: {str(equal).lower()}"])
            if not equal and path not in conflicted:
                reasons.append(f"{path}: differs from git's merge of the gated head and upstream")
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
