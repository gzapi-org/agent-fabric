#!/usr/bin/env python3
"""tests/test_review_brief.py — the review constitution and the brief.

The reviewer's whole system prompt is runtime/claude-code/agents/
code-review.md, paid on every dispatch; the brief is what the dispatcher
puts in `prompt`. What holds still here: the agent file's frontmatter
(the pin rewrite, the tools allow-list, the Bash fence) is exactly what
the guards and install-agent-files.sh expect; the body stays under its
size cap and carries every section the design names; and the brief's
headings, once there is a renderer, are the ones the constitution says
it reads.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
AGENT = os.path.join(ROOT, "runtime", "claude-code", "agents", "code-review.md")
SIZE_CAP = 12 * 1024

# The headings a rendered brief carries; the constitution names each.
BRIEF_HEADINGS = ["Mode", "Repository", "Range", "Objective", "Requirements", "Invariants",
                  "Compatibility", "Threat model", "Scope", "Out of scope", "Lenses", "Previous findings"]
# The report sections the constitution requires, in order.
REPORT_SECTIONS = ["Findings on the change", "Pre-existing problems", "Risks (unproven)", "Brief notes"]


def read_agent() -> tuple[str, str]:
    text = open(AGENT, encoding="utf-8").read()
    assert text.startswith("---\n"), "no frontmatter"
    end = text.index("\n---\n", 4)
    return text[4:end], text[end + 5:]


def test_frontmatter_is_what_the_guards_and_installer_expect() -> None:
    front, _ = read_agent()
    lines = front.split("\n")
    assert lines[0] == "name: code-review", lines[0]
    # install-agent-files.sh rewrites the FIRST `model:` line; the guard reads the same one.
    assert lines[2] == "model: fable", "model: fable must be the third frontmatter line (the pin rewrite hits the first model: line)"
    assert "tools: Read, Glob, Grep, Bash" in front, "the tools allow-list is the write fence"
    assert "Write" not in front.split("tools:")[1].split("\n")[0]
    assert "review-bash-guard.sh" in front and "permissionDecision" in front, "the Bash fence hook must stay in the frontmatter"
    assert re.search(r"\nmodel: ", front.split("model: fable", 1)[1]) is None, "one model: line only"


def test_body_is_under_the_cap_and_carries_every_section() -> None:
    _, body = read_agent()
    size = os.path.getsize(AGENT)
    assert size <= SIZE_CAP, f"code-review.md is {size} bytes; the cap is {SIZE_CAP} (every byte is paid on every dispatch)"
    for h in ("# Code review: the blind reviewer", "## What you are given", "## Method", "## Git: read history, change nothing",
              "## What has shipped here", "## A finding", "## Report format", "## What happens to your findings"):
        assert h in body, f"section missing: {h}"
    for section in REPORT_SECTIONS:
        assert section in body, f"report section missing: {section}"
    for heading in BRIEF_HEADINGS:
        assert heading in body, f"the constitution does not name the brief heading {heading!r}"


def test_the_incident_rules_are_still_there() -> None:
    """Each of these was bought by an incident; a rewrite may not lose one."""
    _, body = read_agent()
    for rule in ("revert test", "Quote the hunk", "in full", "One PR per dispatch", "re-review", "verify ONLY",
                 "fifty thousand tokens", "git log", "Change nothing", "--no-restore", "Never `pub\nget`",
                 "single-line mutation", "P1", "P2", "P3", "Do not pad", "six weeks from now",
                 "Feature flags that are not rollbacks", "Silent-drop", "CHECK clauses"):
        assert rule in body, f"rule lost in the rewrite: {rule!r}"


def test_the_new_rules_are_stated_once() -> None:
    _, body = read_agent()
    assert "verdict rule" in body.lower() and "Brief notes" in body
    assert "negative space" in body.lower()
    assert body.count("**Trigger**") == 1 and "**Evidence**" in body
    assert "**confirmed**" in body and "**likely**" in body and "Nothing below likely is a finding" in body
    assert "Zero findings is a\nvalid report" in body or "Zero findings is a valid report" in body


def main() -> int:
    cases = [test_frontmatter_is_what_the_guards_and_installer_expect, test_body_is_under_the_cap_and_carries_every_section,
             test_the_incident_rules_are_still_there, test_the_new_rules_are_stated_once]
    failures = 0
    for case in cases:
        try:
            case()
            print(f"  ok   {case.__name__}")
        except AssertionError as exc:
            failures += 1
            print(f"  FAIL {case.__name__}: {exc}")
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
