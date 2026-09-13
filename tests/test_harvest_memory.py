#!/usr/bin/env python3
"""Behavioural tests for tools/roles/harvest_memory.py.

Stdlib only; run as `python3 test_harvest_memory.py`. NOT pytest-collectable:
every case takes a `tmp: str`, which pytest would try to resolve as a fixture.

Each case builds a throwaway memory directory and runs the REAL script over
it. The cases that matter most are the REFUSALS: this writes into a shared
repository, so a memory it cannot classify must stop the drain rather than
land somewhere plausible.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "fabric", "harvest_memory.py")
# The claim classes come from the schema the assembler validates against,
# never from a copy in this file: a copy is what drifted and let `index`
# through.
with open(os.path.join(ROOT, "identities", "schemas", "claims.schema.json"), encoding="utf-8") as _fh:
    SCHEMA_CLASSES = tuple(
        json.load(_fh)["properties"]["claims"]["items"]["properties"]["class"]["enum"])


def write_memory(d: str, name: str, mtype: str, body: str = "the fact",
                 roles_class: str | None = None, description: str = "d") -> None:
    extra = f"\n  roles_class: {roles_class}" if roles_class else ""
    with open(os.path.join(d, f"{name}.md"), "w", encoding="utf-8") as fh:
        fh.write(f"---\nname: {name}\ndescription: {description}\n"
                 f"metadata:\n  type: {mtype}{extra}\n---\n\n{body}\n")


def run(mem: str, out: str, *extra: str):
    return subprocess.run(
        [sys.executable, TOOL, "--role", "architect-cto", "--memory", mem,
         "--out", out, *extra],
        capture_output=True, text=True)


def claims_of(out: str) -> list[dict]:
    with open(os.path.join(out, "claims", "architect-cto.json"), encoding="utf-8") as fh:
        return json.load(fh)["claims"]


def test_role_knowledge_is_opt_in(tmp: str) -> None:
    """A memory reaches the shared corpus only if it says so. Nothing is
    inferred from `type`: memory has four types, .roles/ has nine classes,
    and `project` alone covers both live threads and durable constraints."""
    mem, out = os.path.join(tmp, "m1"), os.path.join(tmp, "o1")
    os.makedirs(mem)
    write_memory(mem, "opted-in", "feedback", roles_class="workflow")
    write_memory(mem, "not-opted-in", "feedback")
    assert run(mem, out).returncode == 0
    got = {c["topic"]: c["class"] for c in claims_of(out)}
    assert got == {"opted-in": "workflow"}, got


def test_the_class_is_taken_verbatim_not_mapped(tmp: str) -> None:
    """Every class a claim may take must survive, or the vocabulary is
    silently narrower than .roles/ actually uses. The set is the schema's,
    read from it rather than restated, because a restated copy drifted."""
    mem, out = os.path.join(tmp, "m1b"), os.path.join(tmp, "o1b")
    os.makedirs(mem)
    for klass in SCHEMA_CLASSES:
        write_memory(mem, f"m-{klass}", "project", roles_class=klass)
    assert run(mem, out).returncode == 0
    got = {c["class"] for c in claims_of(out)}
    assert got == set(SCHEMA_CLASSES), got


def test_a_generated_class_is_refused(tmp: str) -> None:
    """`index` is produced BY the assembler from the other slices, so it is
    not a class a claim can take: accepting one aborts assembly with
    KeyError: 'index' after slices have already been written. The schema
    enum is the authority, and it does not list it."""
    assert "index" not in SCHEMA_CLASSES, SCHEMA_CLASSES
    mem, out = os.path.join(tmp, "m1gen"), os.path.join(tmp, "o1gen")
    os.makedirs(mem)
    write_memory(mem, "m-index", "project", roles_class="index")
    r = run(mem, out)
    assert r.returncode == 1, r.returncode
    assert "index" in r.stderr, r.stderr


def test_a_skipped_memory_is_named_not_counted(tmp: str) -> None:
    """An omission you can see beats a wrong filing you cannot. A count
    tells you something was left out; the name tells you whether it should
    have been."""
    mem, out = os.path.join(tmp, "m1c"), os.path.join(tmp, "o1c")
    os.makedirs(mem)
    write_memory(mem, "forgot-to-say", "feedback")
    r = run(mem, out)
    assert r.returncode == 0
    assert "forgot-to-say.md" in r.stdout, r.stdout


def test_an_unfamiliar_type_is_not_an_obstacle(tmp: str) -> None:
    """Types are not consulted, so a memory type invented after this was
    written costs nothing. The old design refused the whole drain on one."""
    mem, out = os.path.join(tmp, "m3"), os.path.join(tmp, "o3")
    os.makedirs(mem)
    write_memory(mem, "novel", "some-future-type", roles_class="workflow")
    r = run(mem, out)
    assert r.returncode == 0, r.stderr
    assert [c["topic"] for c in claims_of(out)] == ["novel"]


def test_a_user_memory_needs_no_special_case(tmp: str) -> None:
    """User memories describe the PERSON and this writes into a shared
    repo. Under opt-in they are excluded by simply not opting in — no
    type-specific rule, and nothing of them reaches the output."""
    mem, out = os.path.join(tmp, "m3b"), os.path.join(tmp, "o3b")
    os.makedirs(mem)
    write_memory(mem, "who-they-are", "user", body="prefers terse answers")
    write_memory(mem, "real", "feedback", roles_class="workflow")
    assert run(mem, out).returncode == 0
    assert [c["topic"] for c in claims_of(out)] == ["real"]
    dumped = open(os.path.join(out, "observations.jsonl"), encoding="utf-8").read()
    assert "prefers terse answers" not in dumped, \
        "a user memory reached the observations file"


def test_hand_authored_classes_are_refused(tmp: str) -> None:
    """lint.py exempts charter and recall from derived_from, which is what
    marks them hand-authored. A derived claim must not enter there."""
    for klass in ("charter", "recall"):
        mem = os.path.join(tmp, f"m5{klass}")
        out = os.path.join(tmp, f"o5{klass}")
        os.makedirs(mem)
        write_memory(mem, "x", "feedback", roles_class=klass)
        r = run(mem, out)
        assert r.returncode == 1, f"{klass} was accepted"
        assert "hand-authored" in r.stderr, r.stderr


def test_unknown_override_class_is_refused(tmp: str) -> None:
    mem, out = os.path.join(tmp, "m6"), os.path.join(tmp, "o6")
    os.makedirs(mem)
    write_memory(mem, "x", "feedback", roles_class="not-a-class")
    r = run(mem, out)
    assert r.returncode == 1
    assert "not-a-class" in r.stderr


def test_index_file_is_not_a_memory(tmp: str) -> None:
    """MEMORY.md is the index and has no frontmatter. Treating it as a
    memory would file the whole table of contents as a claim."""
    mem, out = os.path.join(tmp, "m7"), os.path.join(tmp, "o7")
    os.makedirs(mem)
    with open(os.path.join(mem, "MEMORY.md"), "w", encoding="utf-8") as fh:
        fh.write("- [A](a.md) — hook\n- [B](b.md) — hook\n")
    write_memory(mem, "real", "feedback", roles_class="workflow")
    assert run(mem, out).returncode == 0
    assert [c["topic"] for c in claims_of(out)] == ["real"]


def test_content_hash_follows_the_fact_not_the_file(tmp: str) -> None:
    """Evidence ids must be stable across a rename and must change when the
    fact changes, or a re-drain either duplicates a claim or silently keeps
    a stale one."""
    mem, out = os.path.join(tmp, "m8"), os.path.join(tmp, "o8")
    os.makedirs(mem)
    write_memory(mem, "one", "feedback", body="the original fact", roles_class="workflow")
    assert run(mem, out).returncode == 0
    first = claims_of(out)[0]["evidence"][0]

    # Same name and body, different filename: same evidence.
    os.rename(os.path.join(mem, "one.md"), os.path.join(mem, "renamed.md"))
    out2 = os.path.join(tmp, "o8b")
    assert run(mem, out2).returncode == 0
    assert claims_of(out2)[0]["evidence"][0] == first, "a rename changed the id"

    # Same name, rewritten body: different evidence.
    write_memory(mem, "one", "feedback", body="a rewritten fact", roles_class="workflow")
    os.remove(os.path.join(mem, "renamed.md"))
    out3 = os.path.join(tmp, "o8c")
    assert run(mem, out3).returncode == 0
    assert claims_of(out3)[0]["evidence"][0] != first, "a rewrite kept the id"


def test_wikilinks_become_citations(tmp: str) -> None:
    mem, out = os.path.join(tmp, "m9"), os.path.join(tmp, "o9")
    os.makedirs(mem)
    write_memory(mem, "linked", "feedback", roles_class="workflow",
                 body="see [[other-fact]] and [[third-fact]] and [[other-fact]]")
    assert run(mem, out).returncode == 0
    # An OBJECT keyed by kind, because assemble.py calls .values() on this
    # field; a bare list aborts the run part-way through writing slices.
    # The kind is `memories`: a memory slug is not an artifact reference.
    assert claims_of(out)[0]["citations"] == {
        "memories": ["other-fact", "third-fact"]}, \
        "citations are not an object of deduplicated, sorted wikilinks"


def test_a_memory_without_links_omits_citations(tmp: str) -> None:
    """An empty object, never an empty list: assemble.py's `or {}` hides a
    list only while it is empty, so the list shape would survive here and
    fail on the first memory that actually links to something."""
    mem, out = os.path.join(tmp, "m9b"), os.path.join(tmp, "o9b")
    os.makedirs(mem)
    write_memory(mem, "lonely", "feedback", roles_class="workflow",
                 body="no links here")
    assert run(mem, out).returncode == 0
    assert claims_of(out)[0]["citations"] == {}, claims_of(out)[0]["citations"]


def test_dry_run_writes_nothing(tmp: str) -> None:
    mem, out = os.path.join(tmp, "m10"), os.path.join(tmp, "o10")
    os.makedirs(mem)
    write_memory(mem, "a", "feedback", roles_class="workflow")
    r = run(mem, out, "--dry-run")
    assert r.returncode == 0
    assert not os.path.exists(out), "--dry-run created the output directory"


def test_missing_memory_dir_exits_two(tmp: str) -> None:
    r = run(os.path.join(tmp, "nope"), os.path.join(tmp, "o11"))
    assert r.returncode == 2, r.returncode
    assert "no memory directory" in r.stderr


def test_assemble_gets_the_files_it_requires(tmp: str) -> None:
    """assemble.py opens references.json unconditionally and reads
    observations for provenance; a drain missing either is unusable."""
    mem, out = os.path.join(tmp, "m12"), os.path.join(tmp, "o12")
    os.makedirs(mem)
    write_memory(mem, "a", "feedback", roles_class="workflow")
    assert run(mem, out).returncode == 0
    for required in ("references.json", "observations.jsonl",
                     os.path.join("claims", "architect-cto.json")):
        assert os.path.exists(os.path.join(out, required)), required
    obs = [json.loads(l) for l in
           open(os.path.join(out, "observations.jsonl"), encoding="utf-8") if l.strip()]
    assert obs and {"content_hash", "agent", "host", "project", "working_copy"} <= set(obs[0]), obs[:1]
    # Who learned it is the login, stamped by the resolver; where is a label.
    login = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
    assert obs[0]["agent"] == login, obs[0]
    assert "clone_id" not in obs[0]
    # The claim's evidence must point AT an observation, or the slice's
    # derived_from cites nothing that exists.
    assert claims_of(out)[0]["evidence"][0] == obs[0]["content_hash"]


def test_the_assembler_actually_consumes_the_drain(tmp: str) -> None:
    """The one assertion that would have caught three separate defects.
    Every earlier check here looks at filenames and shapes; none ran the
    consumer, and the consumer aborted on this output in three different
    ways -- a references.json read as a role payload, a citations list
    where an object was required, and a class with no slice file."""
    assemble = os.path.join(os.path.dirname(TOOL), "assemble.py")
    if not os.path.exists(assemble):
        return                                   # not a harvester failure
    mem, out = os.path.join(tmp, "m13"), os.path.join(tmp, "o13")
    os.makedirs(mem)
    # A memory of every class, and one carrying a wikilink: the citation
    # shape is only exercised when the list is non-empty.
    for klass in SCHEMA_CLASSES:
        write_memory(mem, f"c-{klass}", "project", roles_class=klass)
    write_memory(mem, "z-linked", "project", roles_class="workflow",
                 body="See [[c-workflow]] for the rest.")
    assert run(mem, out).returncode == 0
    r = subprocess.run(
        [sys.executable, assemble,
         "--claims", os.path.join(out, "claims"), "--drain", out,
         "--out", os.path.join(tmp, "assembled13"), "--stamp", "2026-01-01"],
        capture_output=True, text=True)
    assert r.returncode == 0, f"assemble failed: {r.stdout}\n{r.stderr}"
    # and the declared telemetry reached it, rather than printing "?"
    assert "admitted=" in r.stdout and "admitted=?" not in r.stdout, r.stdout


def main() -> int:
    cases = [
        test_role_knowledge_is_opt_in,
        test_the_class_is_taken_verbatim_not_mapped,
        test_a_generated_class_is_refused,
        test_a_skipped_memory_is_named_not_counted,
        test_an_unfamiliar_type_is_not_an_obstacle,
        test_a_user_memory_needs_no_special_case,
        test_hand_authored_classes_are_refused,
        test_unknown_override_class_is_refused,
        test_index_file_is_not_a_memory,
        test_content_hash_follows_the_fact_not_the_file,
        test_wikilinks_become_citations,
        test_a_memory_without_links_omits_citations,
        test_dry_run_writes_nothing,
        test_missing_memory_dir_exits_two,
        test_assemble_gets_the_files_it_requires,
        test_the_assembler_actually_consumes_the_drain,
    ]
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for case in cases:
            try:
                case(tmp)
                print(f"  ok   {case.__name__}")
            except AssertionError as exc:
                print(f"  FAIL {case.__name__}: {exc}", file=sys.stderr)
                failures += 1
    print()
    print(f"{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
