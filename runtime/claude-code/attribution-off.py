#!/usr/bin/env python3
"""runtime/claude-code/attribution-off.py — the harness's commit and PR
attribution switched off at its source, in a login's user settings.

    attribution-off.py <settings.json> [--dry-run]

Claude Code builds an attribution reminder from the `attribution`
settings key and injects it as a system reminder on the first turn and
again after every model switch, outside any launch prompt — a
`--system-prompt-file` does not remove it (read back on 2.1.276,
docs/live-checks/2026-09-18-attribution-reminder-off.md). With no key
set the reminder asks for a `Co-Authored-By:` trailer and a "Generated
with" footer, which policies/ban_generated_by_attribution.sh refuses
after the fact. An empty string hides each (the harness's own schema:
"Empty string hides attribution"), and with both hidden the harness
sends the opposite reminder — do not add attribution lines. `sessionUrl`
false drops the `Claude-Session:` trailer a web or Remote Control
session would add. User scope, so it reaches every session of the
login whatever directory it is launched from; the guard stays as the
fence. Every other key is kept as read. Prints one line in the
installer's shape (+ = -) and exits 0.
"""
from __future__ import annotations

import json
import os
import sys

WANT = {"commit": "", "pr": "", "sessionUrl": False}


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    return data if isinstance(data, dict) else {}


def save(path: str, data: dict) -> None:
    tmp = f"{path}.agent-fabric.tmp"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main(argv: list[str]) -> int:
    args = [a for a in argv if a != "--dry-run"]
    dry = "--dry-run" in argv
    if len(args) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = args[0]
    doc = load(path)
    current = doc.get("attribution") if isinstance(doc.get("attribution"), dict) else {}
    # The deprecated switch says the same thing; the current key replaces it.
    if all(current.get(k) == v for k, v in WANT.items()) and "includeCoAuthoredBy" not in doc:
        print(f"  =  {path} attribution off")
        return 0
    if dry:
        print(f"  +  {path} attribution off (would write)")
        return 0
    doc["attribution"] = {**current, **WANT}
    doc.pop("includeCoAuthoredBy", None)
    save(path, doc)
    print(f"  +  {path} attribution off")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
