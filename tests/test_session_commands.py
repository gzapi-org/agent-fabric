#!/usr/bin/env python3
"""Every fabric command a session is told to run runs without an approval.

The harness asks before any command carrying a shell expansion, whatever
the permission mode or rules (the owner, 2026-09-26: no approval for any
fabric script or executable). So a session-facing text names a command
from runtime/claude-code/commands.json, never `$AGENT_FABRIC_ROOT/...`;
every such command is a real executable; and a wrapper that runs another
command is never allowed outright.
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = json.load(open(os.path.join(ROOT, "runtime", "claude-code", "commands.json"), encoding="utf-8"))
# An expansion used as a path: `$AGENT_FABRIC_ROOT/...` or `${AGENT_FABRIC_ROOT}/...`.
# A sentence that warns against it names the variable without a path after it.
EXPANDED_PATH = re.compile(r"\$\{?AGENT_FABRIC_ROOT\}?/")

# The texts a session reads and runs commands from.
SESSION_FACING = (
    glob.glob(os.path.join(ROOT, "communication", "gzcoord", "skills", "*", "SKILL.md"))
    + [os.path.join(ROOT, "policies", "subagent-dispatch", "SKILL.md")]
    + glob.glob(os.path.join(ROOT, "projects", "*", "integration", "gzcoord", "CLAUDE*.md"))
    + glob.glob(os.path.join(ROOT, "identities", "prompt", "*.md"))
    + [os.path.join(ROOT, "CLAUDE.md")]
)


def test_every_command_is_an_executable_with_a_shebang() -> None:
    for name, rel in DOC["commands"].items():
        path = os.path.join(ROOT, rel)
        assert os.path.isfile(path), (name, rel)
        assert os.access(path, os.X_OK), f"{rel} is not executable; `{name}` on PATH would not run"
        with open(path, "rb") as fh:
            assert fh.read(2) == b"#!", f"{rel} has no shebang; `{name}` on PATH would not run"


def test_a_wrapper_that_runs_another_command_is_never_allowed() -> None:
    assert set(DOC.get("not_allowed", {})) <= set(DOC["commands"]), DOC.get("not_allowed")
    assert {"fabric-lease", "fabric-host"} <= set(DOC.get("not_allowed", {})), \
        "fabric-lease runs the command after --, fabric-host runs any command on a host: an allow rule would allow everything"


def test_no_session_facing_text_runs_a_command_through_an_expansion() -> None:
    hits = []
    for path in SESSION_FACING:
        with open(path, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                if EXPANDED_PATH.search(line):
                    hits.append(f"{os.path.relpath(path, ROOT)}:{n}: {line.strip()[:100]}")
    assert not hits, "a session told to run these would be asked every time:\n" + "\n".join(hits)


def test_the_watch_the_hook_prescribes_is_a_bare_command() -> None:
    sys.path.insert(0, os.path.join(ROOT, "runtime", "claude-code", "hooks"))
    src = open(os.path.join(ROOT, "runtime", "claude-code", "hooks", "session-start.py"), encoding="utf-8").read()
    m = re.search(r"Monitor\(command: '([^']*)'", src)
    assert m and m.group(1).split()[0] in DOC["commands"] and "$" not in m.group(1), m and m.group(1)


def main() -> int:
    cases = [
        test_every_command_is_an_executable_with_a_shebang,
        test_a_wrapper_that_runs_another_command_is_never_allowed,
        test_no_session_facing_text_runs_a_command_through_an_expansion,
        test_the_watch_the_hook_prescribes_is_a_bare_command,
    ]
    failed = 0
    for case in cases:
        try:
            case()
            print(f"  ok   {case.__name__}")
        except AssertionError as exc:
            failed += 1
            print(f"  FAIL {case.__name__}: {exc}")
    print(f"\n{len(cases) - failed}/{len(cases)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
