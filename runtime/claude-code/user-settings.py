#!/usr/bin/env python3
"""runtime/claude-code/user-settings.py — the fabric's keys in a login's
Claude Code user settings, written by bootstrap.sh on every account.

    user-settings.py <settings.json> [--dry-run]
    user-settings.py --help

User scope reaches every session of the login whatever directory it is
launched from, so this is where a setting the fabric wants on every
agent goes. Every other key is kept as read. Prints one line in the
installer's shape (+ = -) and exits 0.

The keys, and why each is here:

`attribution` {commit "", pr "", sessionUrl false}. Claude Code builds
an attribution reminder from this key and injects it as a system
reminder on the first turn and again after every model switch, outside
any launch prompt — a `--system-prompt-file` does not remove it (read
back on 2.1.276, docs/live-checks/2026-09-18-attribution-reminder-off.md).
With no key set the reminder asks for a `Co-Authored-By:` trailer and a
"Generated with" footer, which policies/ban_generated_by_attribution.sh
refuses after the fact. An empty string hides each (the harness's own
schema: "Empty string hides attribution"), and with both hidden the
harness sends the opposite reminder — do not add attribution lines.
`sessionUrl` false drops the `Claude-Session:` trailer a web or Remote
Control session would add. The guard stays as the fence. The deprecated
`includeCoAuthoredBy` said the same thing; the key replaces it.

`showThinkingSummaries` true and `verbose` true (the owner, 2026-09-20):
an agent's session is read by the person operating the fleet, not only
by the agent — the thinking summaries and the full tool output are what
lets a stalled or misdirected session be seen for what it is from its
terminal, rather than reconstructed afterwards from a transcript.
"""
from __future__ import annotations

import json
import os
import sys

ATTRIBUTION = {"commit": "", "pr": "", "sessionUrl": False}
TOP_LEVEL = {"showThinkingSummaries": True, "verbose": True}


class Unreadable(Exception):
    """The file exists and is not a JSON object: refused, never overwritten."""


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        raise Unreadable(f"{path}: {exc}") from exc
    if not isinstance(data, dict):
        raise Unreadable(f"{path}: not a JSON object")
    return data


def save(path: str, data: dict) -> None:
    tmp = f"{path}.agent-fabric.tmp"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def settled(doc: dict) -> bool:
    current = doc.get("attribution") if isinstance(doc.get("attribution"), dict) else {}
    return (all(current.get(k) == v for k, v in ATTRIBUTION.items())
            and "includeCoAuthoredBy" not in doc
            and all(doc.get(k) == v for k, v in TOP_LEVEL.items()))


def main(argv: list[str]) -> int:
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    args = [a for a in argv if a != "--dry-run"]
    dry = "--dry-run" in argv
    # An unknown flag is refused, never taken for the path: `--help` once
    # wrote the fabric's keys to a file of that name in the caller's cwd.
    if len(args) != 1 or args[0].startswith("-"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = args[0]
    try:
        doc = load(path)
    except Unreadable as exc:
        # One line in the installer's shape, so bootstrap can count the
        # account as NOT settled instead of reading an empty stdout as
        # "unchanged" — a traceback did exactly that.
        print(f"  !  {exc} — fabric user settings NOT written", file=sys.stderr)
        return 1
    if settled(doc):
        print(f"  =  {path} fabric user settings")
        return 0
    if dry:
        print(f"  +  {path} fabric user settings (would write)")
        return 0
    current = doc.get("attribution") if isinstance(doc.get("attribution"), dict) else {}
    doc["attribution"] = {**current, **ATTRIBUTION}
    doc.pop("includeCoAuthoredBy", None)
    doc.update(TOP_LEVEL)
    save(path, doc)
    print(f"  +  {path} fabric user settings")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
