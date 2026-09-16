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

import json
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


# --- the renderer -----------------------------------------------------------
import importlib.util
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("fabric_review_brief", os.path.join(ROOT, "tools", "fabric", "review_brief.py"))
rb = importlib.util.module_from_spec(spec); spec.loader.exec_module(rb)
BIN = os.path.join(ROOT, "bin", "fabric-review")


def base_request(repo: str) -> dict:
    return {"mode": "review", "repository": repo, "range": "main..HEAD",
            "objective": "An itinerary's times are the engine's.",
            "requirements": ["A malformed engine response is an error, never an empty itinerary."],
            "invariants": ["Nothing under apps/passenger/ interprets a time zone."],
            "lenses": ["protocol"]}


def refusals(req: dict, **kw) -> list[str]:
    try:
        rb.render(req, **kw)
    except rb.RequestError as exc:
        return exc.problems
    return []


def test_render_carries_every_heading_once_and_the_named_lenses(tmp: str) -> None:
    repo = os.path.join(tmp, "repo"); os.makedirs(os.path.join(repo, ".git"))
    out = rb.render(base_request(repo))
    for h in BRIEF_HEADINGS:
        if h == "Previous findings":
            assert f"## {h}" not in out, "a review carries no previous findings"
        else:
            assert out.count(f"\n## {h}\n") == 1, f"heading {h} not exactly once:\n{out}"
    assert out.startswith("# Review brief (agent-fabric review brief v1)\n## Mode\nreview\n")
    assert "### general\n" in out and "### protocol\n" in out, "general is always on; the named lens is inlined"
    assert rb.lenses()["protocol"]["body"] in out, "the lens body is inlined, not referenced"
    assert "## Threat model\n(none stated)\n" in out, "an empty field is rendered as absent, never dropped"
    assert "model:" not in out, "a brief carries no routing configuration"
    assert out == rb.render(base_request(repo)), "not byte-stable"
    assert "## Brief notes" not in out, "no flagged rationale when there is none"


def test_every_refusal_names_its_field(tmp: str) -> None:
    repo = os.path.join(tmp, "repo2"); os.makedirs(os.path.join(repo, ".git"))
    ok = base_request(repo)
    assert refusals(ok) == [], refusals(ok)
    cases = {
        "mode": ({**ok, "mode": "audit"}, "mode: 'audit'"),
        "unknown key": ({**ok, "invariant": ["x"]}, "invariant: not a request field (did you mean invariants?)"),
        "both range and diff": ({**ok, "diff": os.path.join(tmp, "x.diff")}, "range / diff: exactly one"),
        "neither range nor diff": ({k: v for k, v in ok.items() if k != "range"}, "range / diff: exactly one"),
        "bad range": ({**ok, "range": "main HEAD"}, "range: 'main HEAD' is not base..head"),
        "no repository": ({k: v for k, v in ok.items() if k != "repository"}, "repository: required"),
        "not a working copy": ({**ok, "repository": tmp}, "is not a git working copy"),
        "unknown lens": ({**ok, "lenses": ["general", "vibes"]}, "lenses: 'vibes' is not a lens"),
        "objective missing": ({k: v for k, v in ok.items() if k != "objective"}, "objective: required on a review"),
        "previous findings on a review": ({**ok, "previous_findings": "/nope"}, "previous_findings: only on a re-review"),
        "re-review without previous findings": ({**ok, "mode": "re-review"}, "previous_findings: required on a re-review"),
        "list where a value is due": ({**ok, "objective": ["a", "b"]}, "objective: must be one value"),
        "value where a list is due": ({**ok, "requirements": "one"}, "requirements: must be a list"),
    }
    for label, (req, needle) in cases.items():
        probs = refusals(req)
        assert any(needle in p for p in probs), f"{label}: expected {needle!r} in {probs}"


def test_the_rationale_lint_refuses_verdicts_and_passes_facts(tmp: str) -> None:
    repo = os.path.join(tmp, "repo3"); os.makedirs(os.path.join(repo, ".git"))
    ok = base_request(repo)
    verdicts = ["The executor correctly abstracts the host.", "This fixes the PATH bug.", "The worker ensures the token never leaks.",
                "The change is safe.", "The bug was a missing lock.", "I think the dangerous part is the retry.",
                "We suspect the merge path.", "The change adds a transport abstraction.",
                "Retries are bounded. Because the caller loops.", "It should be fine now."]
    for v in verdicts:
        probs = refusals({**ok, "objective": v})
        assert any("objective:" in p and "state what must be true" in p for p in probs), f"verdict passed: {v!r} -> {probs}"
        probs = refusals({**ok, "requirements": [v]})
        assert any(p.startswith("requirements:") for p in probs), f"verdict in a list passed: {v!r}"
    facts = ["A secret never appears in argv.", "Same-host behaviour must remain supported.", "Contracts 1.1.0 clients keep working.",
             "The coordinator and the agent may be on different hosts.", "A malformed reply is an error, never an empty result.",
             "Nothing under apps/ interprets a time zone because-of-clock is not a word here"]
    for f in facts[:-1]:
        assert refusals({**ok, "objective": f}) == [], f"a fact was refused: {f!r}"
    # --allow-rationale renders, flagged under Brief notes
    out = rb.render({**ok, "objective": "This fixes the PATH bug."}, allow_rationale=True)
    assert "## Brief notes (dispatcher-asserted, not facts)" in out and "- objective: This fixes the PATH bug." in out


def test_re_review_inlines_the_previous_report_and_names_the_new_range(tmp: str) -> None:
    repo = os.path.join(tmp, "repo4"); os.makedirs(os.path.join(repo, ".git"))
    prev = os.path.join(tmp, "findings.md")
    open(prev, "w").write("## Findings on the change\n1. P2 likely — apps/x.py:10 ...\n")
    req = {"mode": "re-review", "repository": repo, "range": "3f2c1a0..9b7e44d", "previous_findings": prev}
    out = rb.render(req)
    assert "## Mode\nre-review\n" in out and "## Range\n3f2c1a0..9b7e44d\n" in out
    assert "## Previous findings\n" in out and "1. P2 likely — apps/x.py:10" in out, "the previous report is inlined verbatim"
    assert "answering each by number" in out
    assert "## Objective\n(none stated)" in out, "a re-review needs no objective"
    assert out.count("### ") == 1, "only general unless a lens is named"


def test_the_yaml_subset_and_the_cli(tmp: str) -> None:
    repo = os.path.join(tmp, "repo5"); os.makedirs(os.path.join(repo, ".git"))
    req = os.path.join(tmp, "req.yaml")
    open(req, "w").write(f"""# comment
mode: review   # a trailing comment
repository: {repo}
range: main..HEAD
objective: >-
  An itinerary's times are
  the engine's.
requirements:
  - "A malformed engine response is an error."
  - Plain item
compatibility: [ "Contracts 1.1.0 clients keep working (#746)", 'quoted' ]
threat_model: []
lenses: [protocol, security]
""")
    doc = rb.parse_request(open(req).read())
    assert doc["objective"] == "An itinerary's times are the engine's." and doc["requirements"] == ["A malformed engine response is an error.", "Plain item"]
    assert doc["mode"] == "review", "a trailing comment is not part of the value"
    assert doc["compatibility"] == ["Contracts 1.1.0 clients keep working (#746)", "quoted"], "a # inside a quoted string is text (a PR number)" and doc["threat_model"] == [] and doc["lenses"] == ["protocol", "security"]
    r = subprocess.run([BIN, "check", req], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("ok: review of main..HEAD"), r.stdout + r.stderr
    r = subprocess.run([BIN, "brief", req], capture_output=True, text=True)
    assert r.returncode == 0 and "### security" in r.stdout and "### protocol" in r.stdout, r.stderr
    open(req, "a").write("invariant: [x]\n")
    r = subprocess.run([BIN, "brief", req], capture_output=True, text=True)
    assert r.returncode == 2 and "invariant: not a request field (did you mean invariants?)" in r.stderr, r.stderr
    assert r.stdout == "", "a refused request renders nothing"
    r = subprocess.run([BIN, "lenses"], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("cleanup") and "general" in r.stdout
    # JSON is accepted as is
    r = subprocess.run([BIN, "check", "-"], input=json.dumps({"mode": "review", "repository": repo, "range": "a..b", "objective": "x must hold"}),
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_the_readme_example_renders_as_documented(tmp: str) -> None:
    """The README shows a request and its rendered head; both are the
    renderer's output, so the README cannot drift from the tool."""
    readme = open(os.path.join(ROOT, "runtime", "claude-code", "review", "README.md"), encoding="utf-8").read()
    m = re.search(r"```yaml\n(.*?)```", readme, re.S)
    assert m, "the README carries no yaml example"
    req = rb.parse_request(m.group(1).replace("/home/user/projects/gzapp", tmp))
    os.makedirs(os.path.join(tmp, ".git"), exist_ok=True)
    out = rb.render(req)
    head = re.search(r"```markdown\n(.*?)```", readme, re.S)
    assert head, "the README carries no rendered example"
    expected = head.group(1).replace("/home/user/projects/gzapp", tmp)
    assert out.startswith(expected.split("## Lenses")[0]), "the README's rendered example differs from the renderer's output"


def main() -> int:
    cases = [test_frontmatter_is_what_the_guards_and_installer_expect, test_body_is_under_the_cap_and_carries_every_section,
             test_the_incident_rules_are_still_there, test_the_new_rules_are_stated_once,
             test_render_carries_every_heading_once_and_the_named_lenses, test_every_refusal_names_its_field,
             test_the_rationale_lint_refuses_verdicts_and_passes_facts, test_re_review_inlines_the_previous_report_and_names_the_new_range,
             test_the_yaml_subset_and_the_cli, test_the_readme_example_renders_as_documented]
    failures = 0
    tmp = tempfile.mkdtemp()
    for case in cases:
        try:
            case(tmp) if case.__code__.co_argcount else case()
            print(f"  ok   {case.__name__}")
        except AssertionError as exc:
            failures += 1
            print(f"  FAIL {case.__name__}: {exc}")
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
