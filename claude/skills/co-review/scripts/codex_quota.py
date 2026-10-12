#!/usr/bin/env python3
"""Codex usage-limit marker and automatic-substitute selector for co-review.

The marker records a limit window for the summary line only. No gate decision
reads it; `substitutes` reads this gate's own probe files.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

MAX_RESET = timedelta(days=8)
DEFAULT_RESET = timedelta(hours=1)
FAILED_STATUSES = ("error", "unparseable")
SEAT_FILES = ("codex.runtime.json", "breaker.runtime.json")
EXPECTED_PROBES = {
    "full": (
        "probe-codex-reviewer.json",
        "probe-codex-skeptic.json",
        "probe-claude-reviewer.json",
        "probe-claude-skeptic.json",
    ),
    "light": ("probe-codex-reviewer.json", "probe-claude-skeptic.json"),
}
SEAT_PROBES = {
    "codex": "probe-codex-reviewer.json",
    "breaker": "probe-codex-skeptic.json",
}
MARKER_FIELDS = {"v", "observed_at", "reset_at", "reset_source", "notice", "source", "scope_id"}
MONTHS = {m: i for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), 1)}
RESET_AT_RE = re.compile(
    r"try again at ([A-Za-z]{3})[A-Za-z]* (\d{1,2})(?:st|nd|rd|th)?, (\d{4})"
    r"(?: (\d{1,2}):(\d{2}) ?(AM|PM))?", re.IGNORECASE)
RESET_IN_RE = re.compile(r"try again in (\d+) (minute|hour|day)s?", re.IGNORECASE)


def _usage_limit_refusal(text):
    # Same loader pattern as gate_report._load_runner; the detector lives in the runner.
    path = Path(__file__).resolve().parents[3] / "hooks" / "agent_runtime.py"
    spec = importlib.util.spec_from_file_location("co_review_agent_runtime", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.usage_limit_refusal(text)


def default_state_file() -> Path:
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "dotfiles" / "co-review" / "codex-quota.json"


def _utc(value: datetime) -> datetime:
    return value.astimezone(timezone.utc).replace(microsecond=0)


def _now(arg: str | None) -> datetime:
    return _utc(datetime.fromisoformat(arg)) if arg else _utc(datetime.now(timezone.utc))


def parse_reset(notice: str, observed_at: datetime) -> tuple[datetime, str]:
    """Return (reset_at, source); an unusable reset falls back to one hour."""
    reset, source = None, "default"
    match = RESET_AT_RE.search(notice)
    if match and match.group(1).lower() in MONTHS:
        month, day, year, hour, minute, ampm = match.groups()
        hour_24 = 0
        if hour is not None:
            hour_24 = int(hour) % 12 + (12 if ampm.upper() == "PM" else 0)
        try:
            # A naive datetime is read as local time; TZ is honored.
            reset = _utc(datetime(int(year), MONTHS[month.lower()], int(day), hour_24, int(minute or 0)))
            source = "at"
        except ValueError:
            reset = None
    else:
        match = RESET_IN_RE.search(notice)
        if match:
            unit = {"minute": "minutes", "hour": "hours", "day": "days"}[match.group(2).lower()]
            reset = observed_at + timedelta(**{unit: int(match.group(1))})
            source = "in"
    if reset is None or not observed_at < reset <= observed_at + MAX_RESET:
        return observed_at + DEFAULT_RESET, "default"
    return reset, source


def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _limit_notice(result) -> str | None:
    """Return the first usage-limit error of a failed Codex result, else None."""
    if result.get("status") not in FAILED_STATUSES:
        return None
    errors = result.get("errors")
    if not isinstance(errors, list):
        return None
    return next((e for e in errors if _usage_limit_refusal(e)), None)


def _write_marker(path: Path, marker: dict) -> None:
    created = not path.parent.exists()
    path.parent.mkdir(parents=True, exist_ok=True)
    if created:
        path.parent.chmod(0o700)
    handle, temp = tempfile.mkstemp(dir=path.parent, prefix=".codex-quota.", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(marker, out, sort_keys=True)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def _decisive(paths: list[Path]) -> list[tuple[Path, str | None, dict]]:
    """Codex results that are a success (notice None) or a usage-limit failure."""
    found = []
    for path in paths:
        result = _read_json(path)
        if not isinstance(result, dict) or result.get("runtime") != "codex":
            continue
        if result.get("status") == "success":
            found.append((path, None, result))
        elif (notice := _limit_notice(result)) is not None:
            found.append((path, notice, result))
    return found


def _marker_valid(marker) -> bool:
    if not isinstance(marker, dict) or set(marker) != MARKER_FIELDS:
        return False
    try:
        datetime.fromisoformat(marker["reset_at"])
        datetime.fromisoformat(marker["observed_at"])
    except (TypeError, ValueError):
        return False
    return True


def cmd_check(args) -> int:
    state = Path(args.state_file) if args.state_file else default_state_file()
    out = {"valid": False, "expired": False, "marker": None, "state_file": str(state)}
    if state.exists():
        marker = _read_json(state)
        if not _marker_valid(marker):
            state.unlink(missing_ok=True)
        elif datetime.fromisoformat(marker["reset_at"]) <= _now(args.now):
            state.unlink(missing_ok=True)
            out["expired"] = True
        else:
            out.update(valid=True, marker=marker)
    print(json.dumps(out, sort_keys=True))
    return 0


def cmd_record(args) -> int:
    state = Path(args.state_file) if args.state_file else default_state_file()
    run_dir = Path(args.run_dir)
    seats = _decisive([run_dir / name for name in SEAT_FILES])
    group = seats or _decisive(
        sorted(run_dir.glob("probe-codex-*.json")) + sorted(run_dir.glob("*.codex-attempt.json")))
    action = "unchanged"
    if any(notice is None for _, notice, _ in group):
        if state.exists():
            state.unlink()
            action = "cleared"
    elif group:
        candidates = []
        for path, notice, result in group:
            observed = _utc(datetime.fromtimestamp(path.stat().st_mtime, timezone.utc))
            reset, source = parse_reset(notice, observed)
            candidates.append((reset, {
                "v": 1,
                "observed_at": observed.isoformat(),
                "reset_at": reset.isoformat(),
                "reset_source": source,
                "notice": notice[:300],
                "source": path.name,
                "scope_id": result.get("scope_id"),
            }))
        _write_marker(state, max(candidates, key=lambda c: c[0])[1])
        action = "wrote"
    marker = _read_json(state) if state.exists() else None
    print(json.dumps({"action": action, "marker": marker, "state_file": str(state)}, sort_keys=True))
    return 0


def _refuse(reason: str) -> int:
    print(reason, file=sys.stderr)
    return 1


def cmd_substitutes(args) -> int:
    expected = EXPECTED_PROBES.get(args.cls)
    if expected is None:
        return _refuse(f"class {args.cls} has no Codex probe to substitute")
    run_dir = Path(args.run_dir)
    for name in expected:
        if not (run_dir / name).is_file():
            return _refuse(f"expected probe {name} is missing")
    if any(run_dir.glob("*.codex-attempt.json")):
        return _refuse("a codex-attempt file already exists; run a fresh gate")
    allowed = {SEAT_PROBES["codex"]}
    if args.cls == "full":
        allowed.add(SEAT_PROBES["breaker"])
    failed = []
    for path in sorted(run_dir.glob("probe-*.json")):
        result = _read_json(path)
        if not isinstance(result, dict) or result.get("status") != "success":
            failed.append((path.name, result))
    if not failed:
        return _refuse("no probe failed")
    for name, result in failed:
        if name not in allowed:
            return _refuse(f"failed probe {name} is not a substitutable Codex probe")
        if not (isinstance(result, dict) and result.get("runtime") == "codex"
                and result.get("result") is None and _limit_notice(result) is not None):
            return _refuse(f"failed probe {name} is not a Codex usage-limit failure")
    names = {name for name, _ in failed}
    print(" ".join(seat for seat, probe in SEAT_PROBES.items() if probe in names))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("--state-file")
    check.add_argument("--now")
    check.set_defaults(func=cmd_check)
    record = sub.add_parser("record")
    record.add_argument("--run-dir", required=True)
    record.add_argument("--state-file")
    record.add_argument("--now")
    record.set_defaults(func=cmd_record)
    subs = sub.add_parser("substitutes")
    subs.add_argument("--run-dir", required=True)
    subs.add_argument("--class", dest="cls", required=True)
    subs.set_defaults(func=cmd_substitutes)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
