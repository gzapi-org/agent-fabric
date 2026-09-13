#!/usr/bin/env python3
"""Behavioural tests for tools/roles/assemble.py and tools/roles/lint.py.

Stdlib only; runnable as `python3 test_assemble.py` or under pytest.

The assembler's value is that it is boring: distillers judge, and this puts
the results in the same place every time. So the cases here are about the
properties that make a drain reviewable — identical claims producing an
identical tree, an index that cannot drift from the files beside it, a
slice that splits before it grows past what a session can afford to load —
plus the two refusals that must never be silent: content that should not be
committed, and knowledge quietly duplicated into two roles that will
disagree later.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSEMBLE = os.path.join(ROOT, "tools", "fabric", "assemble.py")
LINT = os.path.join(ROOT, "tools", "fabric", "lint.py")
SCHEMA_DIR = os.path.join(ROOT, "identities", "schemas")

OBSERVATIONS = [
    {"content_hash": "h1", "clone_id": "clone-aaa", "host": "hostA"},
    {"content_hash": "h2", "clone_id": "clone-bbb", "host": "hostB"},
    {"content_hash": "h3", "clone_id": None, "host": "hostA"},
]
REFERENCES = {
    "h1": {"adrs": ["ADR-054"], "prs": ["#428"]},
    "h2": {"migrations": ["migration-007"]},
}


def claims(role: str, items: list[dict]) -> dict:
    return {"role": role, "telemetry": {"observations_in": 10, "admitted": len(items),
                                        "rejected": 3}, "claims": items}


def build(tmp: str, claim_files: dict[str, dict]) -> tuple[str, str, str]:
    drain = os.path.join(tmp, "drain")
    claims_dir = os.path.join(tmp, "claims")
    out = os.path.join(tmp, "roles")
    os.makedirs(drain, exist_ok=True)
    os.makedirs(claims_dir, exist_ok=True)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(drain, "references.json"), "w", encoding="utf-8") as fh:
        json.dump(REFERENCES, fh)
    with open(os.path.join(drain, "observations.jsonl"), "w", encoding="utf-8") as fh:
        for row in OBSERVATIONS:
            fh.write(json.dumps(row) + "\n")
    for role, payload in claim_files.items():
        with open(os.path.join(claims_dir, f"{role}.json"), "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    return drain, claims_dir, out


def run_assemble(drain: str, claims_dir: str, out: str, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, ASSEMBLE, "--claims", claims_dir, "--drain", drain,
         "--out", out, "--stamp", "2026-01-01", *extra],
        capture_output=True, text=True,
    )


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def test_places_claims_and_writes_provenance(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "ble", "title": "Advertisements are one-way",
         "body": "A passive beacon emits and never listens.", "evidence": ["h1", "h2"],
         "citations": {"adrs": ["ADR-054"]}},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr
    slice_path = os.path.join(out, "alpha", "domain.md")
    text = read(slice_path)
    assert "role: alpha" in text and "class: domain" in text
    assert "derived_from:" in text and "- h1" in text
    # Provenance must name the clones, so a claim stays traceable after the
    # source store is gone.
    assert "clone-aaa" in text and "clone-bbb" in text
    assert "ADR-054" in text


def test_unresolved_origin_is_stated_not_invented(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "x", "body": "b", "evidence": ["h3"]},
    ])})
    run_assemble(drain, claims_dir, out)
    assert "unresolved" in read(os.path.join(out, "alpha", "domain.md"))


def test_index_lists_every_slice(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "First", "body": "b", "evidence": ["h1"]},
        {"class": "domain", "topic": "two", "title": "Second", "body": "b", "evidence": ["h1"]},
        {"class": "workflow", "topic": "how", "title": "Third", "body": "b", "evidence": ["h2"]},
    ])})
    run_assemble(drain, claims_dir, out)
    index = read(os.path.join(out, "alpha", "INDEX.md"))
    assert "domain/one.md" in index and "domain/two.md" in index
    assert "workflow.md" in index
    # The description is the retrieval cue: without it the index is a file
    # listing, and a session has no basis for choosing what to open.
    assert "First" in index and "Third" in index


def test_index_banner_names_which_sections_load_when(tmp: str) -> None:
    # The banner sits above a section list whose FIRST entry (charter) and
    # `workflow` entry are both tier 1. A blanket "everything below loads on
    # demand" was therefore false, and false in the direction that matters:
    # a session that believes workflow is cued does not read it until
    # something has already gone wrong.
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "workflow", "topic": "how", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    index = read(os.path.join(out, "alpha", "INDEX.md"))
    assert "Tier 1" in index, index
    assert "loads at activation" in index, index
    assert "Everything below loads on demand" not in index, index


def test_committed_indexes_carry_the_banner_the_assembler_emits(tmp: str) -> None:
    """The committed tree must match what a drain would write.

    INDEX.md is generated, so the banner exists in two places: this
    assembler, and ten committed files. Nothing else compares them — and a
    generator that disagrees with the tree beside it is exactly the defect
    that stranded the tier-1 workflow slices, one level up.
    """
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "workflow", "topic": "how", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    generated = read(os.path.join(out, "alpha", "INDEX.md"))

    # The banner is the block between the H1 and the first section heading.
    body = generated.split("# alpha — knowledge index\n", 1)[1]
    banner = body.split("\n## ", 1)[0].strip()
    assert banner, generated

    # The committed project indexes: memory/projects/<project>/<role>/INDEX.md.
    roles_dir = os.path.join(ROOT, "memory", "projects", "gzapp")
    committed = sorted(
        os.path.join(roles_dir, d, "INDEX.md") for d in os.listdir(roles_dir)
        if os.path.isfile(os.path.join(roles_dir, d, "INDEX.md")))
    assert committed, "no committed role indexes found"
    for path in committed:
        assert banner in read(path), (
            f"{os.path.relpath(path, roles_dir)} does not carry the assembler's "
            f"current banner — regenerate it or revert the generator:\n{banner}")


def test_drain_report_carries_the_watermark_forward(tmp: str) -> None:
    """The committed record must answer "since when" for the next drain.

    The watermark was written only into the drain directory's
    harvest-report.json, which is temporary. Losing it meant the next cycle
    had nothing but the stamp date to work back from, by hand, per store.
    """
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    with open(os.path.join(drain, "harvest-report.json"), "w", encoding="utf-8") as fh:
        json.dump({"host": "boxA", "database": "/home/someone/.claude-mem/claude-mem.db",
                   "since_watermark": 1000, "next_watermark": 2500,
                   "counts": {"provisional_agent": 0, "in_scope": 7}}, fh)
    run_assemble(drain, claims_dir, out)
    report = json.loads(read(os.path.join(out, "last-drain-report.json")))

    # .get throughout: a missing key must fail this test with a readable
    # message, not raise KeyError and abort the whole suite behind it.
    assert report.get("watermarks") == {"boxA": 2500}, report.get("watermarks")
    harvest = report.get("harvest") or {}
    assert harvest.get("next_watermark") == 2500, harvest
    assert harvest.get("since_watermark") == 1000, harvest
    assert harvest.get("host") == "boxA", harvest
    # An absolute path into somebody's home must not be committed.
    assert "database" not in harvest, harvest
    assert "/home/someone" not in read(os.path.join(out, "last-drain-report.json"))


def test_drain_report_records_unattributable_rows(tmp: str) -> None:
    # A row that resolves to no clone is reported provisional and never
    # guessed — but nothing downstream read the tally, so a drain in which
    # every row was unattributable landed looking exactly like a clean one.
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    with open(os.path.join(drain, "harvest-report.json"), "w", encoding="utf-8") as fh:
        json.dump({"host": "boxA", "since_watermark": 0, "next_watermark": 9,
                   "counts": {"provisional_agent": 41, "in_scope": 41}}, fh)
    run_assemble(drain, claims_dir, out)
    report = json.loads(read(os.path.join(out, "last-drain-report.json")))
    harvest = report.get("harvest") or {}
    assert harvest.get("provisional_agent") == 41, harvest
    assert harvest.get("in_scope") == 41, harvest


def test_drain_report_tolerates_a_drain_with_no_harvest_report(tmp: str) -> None:
    # A hand-built drain directory is legitimate — the assembler must not
    # require the harvester to have run, only benefit from it when it did.
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr
    report = json.loads(read(os.path.join(out, "last-drain-report.json")))
    assert report.get("harvest", "MISSING") is None, report.get("harvest", "MISSING")
    assert report.get("watermarks", "MISSING") == {}, report.get("watermarks", "MISSING")


def test_unattributable_rows_warn_loudly_but_do_not_fail_the_drain(tmp: str) -> None:
    """Provisional bindings are reported, never guessed — and never a gate.

    Gating would refuse valid knowledge over a registry gap the assembler
    cannot fix: a clone mints its own id, so it cannot be minted from here.
    """
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    with open(os.path.join(drain, "harvest-report.json"), "w", encoding="utf-8") as fh:
        json.dump({"host": "boxA", "since_watermark": 0, "next_watermark": 9,
                   "counts": {"provisional_agent": 41, "in_scope": 60}}, fh)
    proc = run_assemble(drain, claims_dir, out)

    assert proc.returncode == 0, "an unattributable row is knowledge, not a failure"
    assert "PROVISIONAL BINDINGS" in proc.stderr, proc.stderr
    assert "41 of 60" in proc.stderr, proc.stderr
    # The remedy has to be in the message: it is not doable from here.
    assert "agent-map" in proc.stderr, proc.stderr


def test_a_fully_attributed_drain_says_nothing_about_bindings(tmp: str) -> None:
    # A warning that fires on a clean drain is noise, and noise is how a real
    # one gets ignored.
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    with open(os.path.join(drain, "harvest-report.json"), "w", encoding="utf-8") as fh:
        json.dump({"host": "boxA", "since_watermark": 0, "next_watermark": 9,
                   "counts": {"provisional_agent": 0, "in_scope": 60}}, fh)
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr
    assert "PROVISIONAL" not in proc.stderr, proc.stderr


def test_output_is_byte_stable(tmp: str) -> None:
    payload = {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
        {"class": "solution", "topic": "two", "title": "U", "body": "b", "evidence": ["h2"]},
    ])}
    drain, claims_dir, out = build(tmp, payload)
    run_assemble(drain, claims_dir, out)
    first = {}
    for dirpath, _dirs, files in os.walk(out):
        for name in files:
            p = os.path.join(dirpath, name)
            first[p] = read(p)
    run_assemble(drain, claims_dir, out)
    for path, before in first.items():
        assert read(path) == before, f"{path} differs between identical runs"


def test_slice_splits_when_it_exceeds_budget(tmp: str) -> None:
    big = "x " * 3000  # comfortably past a small budget
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "big", "title": "A", "body": big, "evidence": ["h1"]},
        {"class": "domain", "topic": "big", "title": "B", "body": big, "evidence": ["h2"]},
    ])})
    run_assemble(drain, claims_dir, out, "--budget", "500")
    files = sorted(os.listdir(os.path.join(out, "alpha", "domain")))
    assert len(files) >= 2, f"expected a split, got {files}"


def test_budget_accounts_for_what_merge_mode_carries(tmp: str) -> None:
    """Each drain split its OWN claims correctly, then merge mode added every
    earlier section back underneath.

    So a slice crept past the budget across cycles while no single run ever
    looked wrong — until the mandatory lint budget check failed on a tree
    nobody had touched. The split has to size the combined old-and-new body.
    """
    big = "y " * 900
    first = {"alpha": claims("alpha", [
        {"class": "domain", "topic": "grow", "title": "First", "body": big,
         "evidence": ["h1"]},
    ])}
    drain, claims_dir, out = build(tmp, first)
    run_assemble(drain, claims_dir, out, "--budget", "500")

    # A second, separately-small drain into the SAME topic.
    second = claims("alpha", [
        {"class": "domain", "topic": "grow", "title": "Second", "body": big,
         "evidence": ["h2"]},
    ])
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(second, fh)
    proc = run_assemble(drain, claims_dir, out, "--budget", "500")
    assert proc.returncode == 0, proc.stderr

    # Whichever layout it chose, no single slice may exceed the budget.
    limit = 500 * 4
    oversized = []
    for dirpath, _dirs, files in os.walk(os.path.join(out, "alpha")):
        for name in files:
            if not name.endswith(".md") or name == "INDEX.md":
                continue
            full = os.path.join(dirpath, name)
            size = len(read(full))
            if size > limit * 1.5:      # generous: frontmatter is not free
                oversized.append((os.path.relpath(full, out), size))
    assert not oversized, f"a slice grew past its budget across drains: {oversized}"

    # And both drains' content still exists somewhere.
    everything = ""
    for dirpath, _dirs, files in os.walk(os.path.join(out, "alpha")):
        for name in files:
            everything += read(os.path.join(dirpath, name))
    assert "First" in everything and "Second" in everything, \
        "carrying must not be traded away for staying inside budget"


def test_claim_owned_by_two_roles_is_stored_once(tmp: str) -> None:
    shared_claim = {"class": "domain", "topic": "observability",
                    "title": "Dashboards are shared", "body": "One metrics stack serves both.",
                    "evidence": ["h1"], "shared_with": ["beta"]}
    drain, claims_dir, out = build(tmp, {
        "alpha": claims("alpha", [shared_claim]),
        "beta": claims("beta", [
            {"class": "workflow", "topic": "own", "title": "Own", "body": "b", "evidence": ["h2"]},
        ]),
    })
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr
    shared_path = os.path.join(out, "shared", "domain-observability.md")
    assert os.path.exists(shared_path), "a multi-owner claim belongs in shared/"
    assert not os.path.exists(os.path.join(out, "alpha", "domain.md")), \
        "it must not also be copied into the owning role"
    for role in ("alpha", "beta"):
        index = read(os.path.join(out, role, "INDEX.md"))
        assert "shared/domain-observability.md" in index, f"{role} must point at the shared slice"


def test_shared_claims_reach_every_owner_crossref(tmp: str) -> None:
    """A multi-owner claim is routed OUT of per_role and into shared, and the
    citation graph iterated per_role alone.

    So every observation, ADR, PR and migration edge behind shared knowledge
    was missing from both owners' crossref.json. INDEX.md pointed at the
    shared slice correctly, which is what made it invisible: only a
    citation-graph query could see it, and it silently under-reported.
    """
    shared_claim = {"class": "domain", "topic": "observability",
                    "title": "Dashboards are shared", "body": "One metrics stack serves both.",
                    "evidence": ["h1"], "shared_with": ["beta"]}
    drain, claims_dir, out = build(tmp, {
        "alpha": claims("alpha", [shared_claim]),
        "beta": claims("beta", [
            {"class": "workflow", "topic": "own", "title": "Own", "body": "b", "evidence": ["h2"]},
        ]),
    })
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    # h1 carries ADR-054 and PR #428 per the fixture, so BOTH owners must be
    # able to answer "what backs my knowledge of ADR-054".
    for role in ("alpha", "beta"):
        with open(os.path.join(out, role, "crossref.json"), encoding="utf-8") as fh:
            index = json.load(fh)["index"]
        assert "ADR-054" in index.get("adrs", {}), \
            f"{role} crossref lost the shared claim's ADR edge: {index}"
        node = index["adrs"]["ADR-054"]
        assert "h1" in node["observations"], node
        assert any("observability" in sl for sl in node["slices"]), node


def test_crossref_maps_artifacts_to_slices(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    with open(os.path.join(out, "alpha", "crossref.json"), encoding="utf-8") as fh:
        doc = json.load(fh)
    entry = doc["index"]["adrs"]["ADR-054"]
    assert entry["observations"] == ["h1"]
    assert entry["slices"] == ["domain:one"]


def test_merge_mode_preserves_earlier_drains(tmp: str) -> None:
    """The second drain renders only what it admitted. Writing that alone
    would delete what the first drain learned, so prior sections are carried
    forward and their provenance unions."""
    first = {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Learned in cycle one",
         "body": "The original finding.", "evidence": ["h1"]},
    ])}
    drain, claims_dir, out = build(tmp, first)
    run_assemble(drain, claims_dir, out)

    second = claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Learned in cycle two",
         "body": "A later, unrelated finding.", "evidence": ["h2"]},
    ])
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(second, fh)
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    text = read(os.path.join(out, "alpha", "domain.md"))
    assert "Learned in cycle one" in text, "the earlier drain's claim was destroyed"
    assert "Learned in cycle two" in text, "the new claim is missing"
    assert "- h1" in text and "- h2" in text, "provenance must union across drains"


def test_index_keeps_slices_this_drain_did_not_touch(tmp: str) -> None:
    """Merge mode rewrites only the slices a claim touched. The index is the
    ONLY thing a session reads before deciding what to load, so an index built
    from just this run's writes silently retires every untouched slice. On the
    first drain everything is written and this cannot be seen; the second drain
    dropped 101 entries across ten roles before it was caught."""
    first = {"alpha": claims("alpha", [
        {"class": "domain", "topic": "kept", "title": "Learned in cycle one",
         "body": "b", "evidence": ["h1"]},
    ])}
    drain, claims_dir, out = build(tmp, first)
    run_assemble(drain, claims_dir, out)
    assert "domain.md" in read(os.path.join(out, "alpha", "INDEX.md"))

    second = claims("alpha", [
        {"class": "workflow", "topic": "fresh", "title": "Learned in cycle two",
         "body": "b", "evidence": ["h2"]},
    ])
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(second, fh)
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    index = read(os.path.join(out, "alpha", "INDEX.md"))
    assert "workflow.md" in index, "the new slice is missing from the index"
    assert "domain.md" in index, "an untouched slice vanished from the index"


def test_a_title_containing_a_newline_is_not_truncated(tmp: str) -> None:
    """`text.strip() != text` catches only leading and trailing whitespace, so
    an interior newline is written raw. parse_frontmatter then keeps the first
    line and silently drops the rest — and the index entry for that slice would
    differ depending on whether a drain touched it, since the write path has the
    full title and the on-disk scan reads only the truncated one."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "first line\nsecond line",
         "body": "b", "evidence": ["h1", "h2"]},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    text = read(os.path.join(out, "alpha", "domain.md"))
    meta = text.split("---")[1]
    desc = [l for l in meta.splitlines() if l.startswith("description:")]
    assert len(desc) == 1, f"description spilled across lines: {meta}"
    assert "second line" in desc[0], "the tail of the title was dropped from frontmatter"
    assert "second line" in read(os.path.join(out, "alpha", "INDEX.md"))


def test_a_class_never_gets_both_a_flat_file_and_a_directory(tmp: str) -> None:
    """switch.py takes the directory branch and skips the flat file, so a class
    holding both has an unreachable half — at tier 1 that silently retires
    knowledge the index promises loads at activation. The layout must follow the
    TREE, not this drain's topic count, or a class that has already split gains a
    flat file the moment a later drain touches exactly one topic in it."""
    first = {"alpha": claims("alpha", [
        {"class": "workflow", "topic": "aaa", "title": "A", "body": "b", "evidence": ["h1"]},
        {"class": "workflow", "topic": "bbb", "title": "B", "body": "b", "evidence": ["h2"]},
    ])}
    drain, claims_dir, out = build(tmp, first)
    run_assemble(drain, claims_dir, out)
    assert os.path.isdir(os.path.join(out, "alpha", "workflow")), "expected a split class"

    second = claims("alpha", [
        {"class": "workflow", "topic": "aaa", "title": "A again", "body": "b", "evidence": ["h3"]},
    ])
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(second, fh)
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    flat = os.path.join(out, "alpha", "workflow.md")
    assert not os.path.exists(flat), "a split class gained an unreachable flat file"
    assert "A again" in read(os.path.join(out, "alpha", "workflow", "aaa.md"))


def test_a_hash_shaped_like_a_number_survives_the_frontmatter(tmp: str) -> None:
    """Content hashes are hex, so some are digits plus an `e` —
    `23258632804400e6` is a valid hash and a valid YAML float. Emitted bare it
    reads back as 2.3e+19 and the hash is gone. One reached a committed slice
    and lint caught it only as a type error on derived_from."""
    tricky = "23258632804400e6"
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b",
         "evidence": [tricky, "1234567890123456", "1.5", "true"]},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    text = read(os.path.join(out, "alpha", "domain.md"))
    assert f'"{tricky}"' in text, "a number-shaped hash was emitted unquoted"

    # Only the derived_from list: `origin:` renders nested mappings, not scalars.
    meta = text.split("---")[1].splitlines()
    start = next(i for i, l in enumerate(meta) if l.strip() == "derived_from:")
    for line in meta[start + 1:]:
        item = line.strip()
        if not item.startswith("- "):
            break
        assert item[2:].startswith('"'), f"unquoted ambiguous scalar: {item}"


def test_carried_full_scope_survives_a_domain_only_drain(tmp: str) -> None:
    """`knowledge_scope` was computed from the CURRENT drain's claims alone.

    A cycle contributing only domain-only claims to a slice that already
    held a full-scope section relabelled the whole file `domain-only` while
    the system-specific text was still in it — defeating the cross-project
    boundary the field draws. `full` has to win over anything carried.
    """
    first = {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "System specific finding",
         "body": "How this deployment wires it.", "evidence": ["h1"],
         "knowledge_scope": "full"},
    ])}
    drain, claims_dir, out = build(tmp, first)
    run_assemble(drain, claims_dir, out)
    path = os.path.join(out, "alpha", "domain.md")
    assert "knowledge_scope: full" in read(path), read(path)

    second = claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Transferable finding",
         "body": "True of the field generally.", "evidence": ["h2"],
         "knowledge_scope": "domain-only"},
    ])
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(second, fh)
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    text = read(path)
    assert "System specific finding" in text, "the full-scope section is still carried"
    assert "knowledge_scope: full" in text, \
        "a carried full-scope section must keep the file full-scope:\n" + text


def test_merge_target_strengthens_instead_of_appending(tmp: str) -> None:
    """Naming an existing heading replaces that section rather than adding a
    near-duplicate beside it — what keeps a long-lived file dense."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "The finding",
         "body": "First statement of it.", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(claims("alpha", [
            {"class": "domain", "topic": "one", "title": "The finding",
             "merge_target": "The finding",
             "body": "Sharper statement, with the extra evidence.",
             "evidence": ["h2"]},
        ]), fh)
    run_assemble(drain, claims_dir, out)
    text = read(os.path.join(out, "alpha", "domain.md"))
    assert text.count("## The finding") == 1, "merge_target must not duplicate the section"
    assert "Sharper statement" in text
    assert "First statement" not in text, "the strengthened claim replaces the old text"


def test_duplicate_title_keeps_both_claims(tmp: str) -> None:
    """Replacement is opt-in through merge_target. Overwriting on a bare title
    match made it implicit and silent — a drain deleting a finding nobody asked
    it to touch."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "The first claim.", "evidence": ["h1"]},
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "A genuinely different second claim.", "evidence": ["h2"]},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr
    text = read(os.path.join(out, "alpha", "domain.md"))
    assert "The first claim." in text, "the earlier claim was silently discarded"
    assert "A genuinely different second claim." in text
    assert "TITLE COLLISIONS" in proc.stderr, "the collision must be reported, not hidden"


def test_carried_sections_keep_their_citation_edges(tmp: str) -> None:
    """A preserved section still cites its ADRs and PRs, so rebuilding the
    graph from this drain alone would break every lookup into it."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Cycle one",
         "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(claims("alpha", [
            {"class": "solution", "topic": "two", "title": "Cycle two",
             "body": "b", "evidence": ["h2"]},
        ]), fh)
    run_assemble(drain, claims_dir, out)
    with open(os.path.join(out, "alpha", "crossref.json"), encoding="utf-8") as fh:
        index = json.load(fh)["index"]
    assert "ADR-054" in index.get("adrs", {}), "the first drain's edge was lost"
    assert "migration-007" in index.get("migrations", {}), "the second drain's edge is missing"


def test_carried_evidence_keeps_its_origin(tmp: str) -> None:
    """A hash in derived_from with no matching origin is an audit trail that
    breaks exactly when the observation store has been cleared."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Cycle one",
         "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(claims("alpha", [
            {"class": "domain", "topic": "one", "title": "Cycle two",
             "body": "b", "evidence": ["h2"]},
        ]), fh)
    run_assemble(drain, claims_dir, out)
    text = read(os.path.join(out, "alpha", "domain.md"))
    assert "- h1" in text and "- h2" in text
    assert "clone-aaa" in text, "the carried hash lost the clone that produced it"
    assert "clone-bbb" in text, "the new hash lost its origin"


def test_collision_is_reported_on_every_run(tmp: str) -> None:
    """An unresolved collision must keep appearing. Reporting it only the
    first time made the drain report differ between identical runs and hid a
    still-unresolved collision from every later drain."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "First.", "evidence": ["h1"]},
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "Second.", "evidence": ["h2"]},
    ])})
    run_assemble(drain, claims_dir, out)
    first = read(os.path.join(out, "last-drain-report.json"))
    run_assemble(drain, claims_dir, out)
    second = read(os.path.join(out, "last-drain-report.json"))
    assert first == second, "the drain report must be identical for identical input"
    assert json.loads(second)["title_collisions"], \
        "an unresolved collision must still be reported on later drains"


def test_collision_survives_a_drain_with_an_empty_delta(tmp: str) -> None:
    """An empty delta for a slice is a valid outcome, and both colliding
    sections stay on disk through it. Deriving the warning from the current
    batch let it go quiet exactly then — an unresolved collision that stops
    being reported reads as one that was resolved."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "First.", "evidence": ["h1"]},
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "Second.", "evidence": ["h2"]},
    ])})
    run_assemble(drain, claims_dir, out)
    assert json.loads(read(os.path.join(out, "last-drain-report.json")))["title_collisions"]

    # A later drain that admits nothing for this slice — and touches a
    # different one entirely.
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(claims("alpha", [
            {"class": "workflow", "topic": "elsewhere", "title": "Unrelated",
             "body": "b", "evidence": ["h2"]},
        ]), fh)
    run_assemble(drain, claims_dir, out)

    text = read(os.path.join(out, "alpha", "domain.md"))
    assert "## Same title" in text and "## Same title (2)" in text, \
        "both sections must still be on disk"
    still = json.loads(read(os.path.join(out, "last-drain-report.json")))["title_collisions"]
    assert still, "the unresolved collision must still be reported"


def test_merge_target_clears_the_collision_it_resolves(tmp: str) -> None:
    """A collision leaves "X" and "X (2)" and records "X" so the drain
    report can ask for a merge_target.

    Naming it rewrote "X" alone: "X (2)" stayed in the body forever and
    the recorded collision was unioned forward on every later drain — so
    the remedy the report prescribes could never clear the report.
    """
    first = {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Shared title",
         "body": "The first finding.", "evidence": ["h1"]},
        {"class": "domain", "topic": "one", "title": "Shared title",
         "body": "A DIFFERENT second finding.", "evidence": ["h2"]},
    ])}
    drain, claims_dir, out = build(tmp, first)
    run_assemble(drain, claims_dir, out)
    path = os.path.join(out, "alpha", "domain.md")
    text = read(path)
    assert "Shared title (2)" in text, "precondition: the collision happened"
    assert "collisions:" in text, "precondition: it was recorded"

    # The prescribed remedy.
    second = claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Shared title",
         "merge_target": "Shared title",
         "body": "Both findings, consolidated.", "evidence": ["h1", "h2"]},
    ])
    with open(os.path.join(claims_dir, "alpha.json"), "w", encoding="utf-8") as fh:
        json.dump(second, fh)
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr

    text = read(path)
    assert "Both findings, consolidated." in text, text
    assert "Shared title (2)" not in text, \
        "the suffixed section survived its own consolidation:\n" + text
    assert "collisions:" not in text, \
        "the collision is still reported after being resolved:\n" + text


def test_collision_scan_ignores_authored_documents(tmp: str) -> None:
    """An authored document may use `X` and `X (2)` as ordinary headings.
    Reporting those as an assembler collision would be wrong, and the
    merge_target it suggests could not fix them — nothing generated them."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Fine", "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)          # creates the role directory
    # A charter (authored, class not generated) and a plain readme.
    with open(os.path.join(out, "alpha", "charter.md"), "w", encoding="utf-8") as fh:
        fh.write("---\nrole: alpha\nclass: charter\ndescription: d\n"
                 "tier: 1\ndistilled_at: 2026-01-01\n---\n\n"
                 "## Scope\n\ntext\n\n## Scope (2)\n\nmore text\n")
    with open(os.path.join(out, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("# Roles\n\n## Layout\n\ntext\n\n## Layout (2)\n\nmore\n")

    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stderr
    report = json.loads(read(os.path.join(out, "last-drain-report.json")))
    assert report["title_collisions"] == [], \
        f"authored headings must not be reported: {report['title_collisions']}"


def test_authored_headings_are_not_mistaken_for_collisions(tmp: str) -> None:
    """An authored document may legitimately carry "X" and "X (2)". Inferring
    a collision from heading shape reported one where nothing collided, and
    told the reader to set merge_target on a file that has no claims."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Ordinary", "body": "b",
         "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    with open(os.path.join(out, "alpha", "charter.md"), "w", encoding="utf-8") as fh:
        fh.write("---\nrole: alpha\nclass: charter\ndescription: authored\n"
                 "tier: 1\ndistilled_at: 2026-01-01\n---\n\n"
                 "## Phase one\n\ntext\n\n## Phase one (2)\n\nmore text\n")
    run_assemble(drain, claims_dir, out)
    report = json.loads(read(os.path.join(out, "last-drain-report.json")))
    assert report["title_collisions"] == [], \
        f"authored headings were reported as a collision: {report['title_collisions']}"


def test_a_collision_slice_passes_lint(tmp: str) -> None:
    """Whatever the assembler writes, the schema must permit. `collisions` was
    added to the frontmatter without being added to the template schema, so
    the first real collision would have failed CI lint — turning a warning
    that is deliberately advisory into a merge blocker."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "First.", "evidence": ["h1"]},
        {"class": "domain", "topic": "one", "title": "Same title",
         "body": "Second.", "evidence": ["h2"]},
    ])})
    run_assemble(drain, claims_dir, out)
    assert "collisions:" in read(os.path.join(out, "alpha", "domain.md")), \
        "the collision should have been recorded in the slice"
    if os.path.isdir(SCHEMA_DIR):
        import shutil
        shutil.copytree(SCHEMA_DIR, os.path.join(out, "schema"), dirs_exist_ok=True)
    proc = subprocess.run([sys.executable, LINT, "--roles", out], capture_output=True, text=True)
    assert proc.returncode == 0, \
        f"lint rejected what the assembler wrote:\n{proc.stderr}"


def test_quoted_titles_survive_repeated_drains(tmp: str) -> None:
    """Frontmatter must round-trip. A value with punctuation is written
    JSON-quoted; reading it back by stripping the outer quotes left the
    escapes behind, so a unioned field returned slightly more escaped each
    cycle and grew a fresh entry every drain, without bound."""
    quoted = 'The "quoted" finding'
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": quoted,
         "body": "First.", "evidence": ["h1"]},
        {"class": "domain", "topic": "one", "title": quoted,
         "body": "Second — a different claim under the same title.",
         "evidence": ["h2"]},
    ])})
    run_assemble(drain, claims_dir, out)
    first = read(os.path.join(out, "alpha", "domain.md"))
    assert first.count("collisions:") == 1
    entries_first = first.count(quoted.replace('"', '\\"'))

    run_assemble(drain, claims_dir, out)
    second = read(os.path.join(out, "alpha", "domain.md"))
    assert second == first, "a repeated drain must not rewrite the slice"
    assert second.count(quoted.replace('"', '\\"')) == entries_first, \
        "the collision entry multiplied across drains"
    assert "\\\\" not in second, "escaping accumulated in the frontmatter"


def test_domain_only_evidence_may_only_support_a_domain_claim(tmp: str) -> None:
    """Sibling-project evidence is transferable knowledge about a FIELD.

    Filed as `solution` it becomes an as-of-dated assertion about what THIS
    system implements; as `workflow` or `rationale`, about how this team
    works. The schema accepted the combination and the assembler wrote it in
    with only an in-body disclaimer — prose a reader may skim, not a
    boundary. And nothing loaded the schema at all, so it enforced nothing.
    """
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "solution", "topic": "wiring", "title": "Borrowed",
         "body": "How the other project wires it.", "evidence": ["h1"],
         "knowledge_scope": "domain-only"},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "domain-only" in proc.stderr, proc.stderr
    # It must refuse BEFORE writing, so a rerun is enough to recover.
    assert not os.path.exists(os.path.join(out, "alpha", "solution.md")), \
        "a rejected drain must not leave a tree behind"


def test_domain_only_evidence_is_accepted_on_a_domain_claim(tmp: str) -> None:
    """The gate must narrow the case, not delete it."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "wiring", "title": "Borrowed",
         "body": "True of the field generally.", "evidence": ["h1"],
         "knowledge_scope": "domain-only"},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert os.path.exists(os.path.join(out, "alpha", "domain.md"))


def test_hygiene_violation_fails_the_run(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "leak", "title": "T",
         "body": "This mentions Springfield, which must never reach a committed role file.",
         "evidence": ["h1"]},
    ])})
    proc = run_assemble(drain, claims_dir, out)
    assert proc.returncode == 1, "a banned term must fail the assembly"
    assert "city name" in proc.stderr


def test_non_english_slice_is_flagged_by_lint(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "it", "title": "T",
         "body": "Questo perche' la configurazione della nella cache dovrebbe essere anche molto lenta.",
         "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    if os.path.isdir(SCHEMA_DIR):
        import shutil
        shutil.copytree(SCHEMA_DIR, os.path.join(out, "schema"), dirs_exist_ok=True)
    proc = subprocess.run([sys.executable, LINT, "--roles", out], capture_output=True, text=True)
    assert proc.returncode == 1, "non-English prose must be reported"
    assert "non-English" in proc.stderr


def test_lint_detects_index_drift(tmp: str) -> None:
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b", "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    if os.path.isdir(SCHEMA_DIR):
        import shutil
        shutil.copytree(SCHEMA_DIR, os.path.join(out, "schema"), dirs_exist_ok=True)
    with open(os.path.join(out, "alpha", "solution.md"), "w", encoding="utf-8") as fh:
        fh.write("---\nrole: alpha\nclass: solution\ndescription: added by hand\n"
                 "tier: 2\ndistilled_at: 2026-01-01\nderived_from:\n  - h1\n---\n\nbody\n")
    proc = subprocess.run([sys.executable, LINT, "--roles", out], capture_output=True, text=True)
    assert proc.returncode == 1
    assert "drifted" in proc.stderr, proc.stderr


def test_scratchpad_references_are_normalized(tmp: str) -> None:
    """A session scratchpad path must not become a crossref key.

    The index is worth keeping because its keys still resolve once the
    observation buffer is gone. A path under one session's scratchpad
    resolves nowhere — and three such keys reached the repo from other
    sessions before this existed.
    """
    scratch = ("/tmp/claude-1000/-home-user-projects-gzapp-claude9/"
               "cbbf4344-dead-beef-0000-000000000000/scratchpad/probe.test.ts")
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b",
         "evidence": ["hx"]},
    ])})
    # An observation whose only cited artifact is a scratchpad file.
    with open(os.path.join(drain, "references.json"), "w", encoding="utf-8") as fh:
        json.dump({"hx": {"files": [scratch]}}, fh)
    run_assemble(drain, claims_dir, out)

    with open(os.path.join(out, "alpha", "crossref.json"), encoding="utf-8") as fh:
        files = json.load(fh)["index"].get("files", {})
    assert scratch not in files, f"raw session path survived: {sorted(files)}"
    # The digest distinguishes same-named artifacts from different
    # sessions; the readable tail is what the entry is FOR, so both halves
    # are asserted rather than the whole key.
    key = next((k for k in files if k.startswith("scratch:probe.test.ts#")), None)
    assert key is not None, sorted(files)
    assert re.fullmatch(r"scratch:probe\.test\.ts#[0-9a-f]{8}", key), key
    # The edge itself is preserved — normalizing must not drop provenance.
    assert files[key]["observations"] == ["hx"], files


def test_a_tracked_scratchpad_path_is_left_alone(tmp: str) -> None:
    """A `scratchpad/` segment means ephemeral only UNDER a session-temp
    root. `docs/scratchpad/decision.md` is a tracked file someone can
    open, and collapsing it would delete a valid repository path from the
    citation graph — the opposite of what the normalization is for."""
    tracked = "docs/scratchpad/decision.md"
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b",
         "evidence": ["hx"]},
    ])})
    with open(os.path.join(drain, "references.json"), "w", encoding="utf-8") as fh:
        json.dump({"hx": {"files": [tracked]}}, fh)
    run_assemble(drain, claims_dir, out)

    with open(os.path.join(out, "alpha", "crossref.json"), encoding="utf-8") as fh:
        files = json.load(fh)["index"].get("files", {})
    assert tracked in files, sorted(files)
    assert not any(k.startswith("scratch:") for k in files), sorted(files)


def test_same_named_temp_artifacts_stay_distinct(tmp: str) -> None:
    """Two dead paths sharing a basename are not the same artifact.
    Without a distinguishing digest both reduced to `scratch:probe.cs`
    and the assembler merged their observation lists, conflating
    unrelated provenance."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b",
         "evidence": ["ha", "hb"]},
    ])})
    with open(os.path.join(drain, "references.json"), "w", encoding="utf-8") as fh:
        json.dump({"ha": {"files": ["/tmp/run-a/probe.cs"]},
                   "hb": {"files": ["/tmp/run-b/probe.cs"]}}, fh)
    run_assemble(drain, claims_dir, out)

    with open(os.path.join(out, "alpha", "crossref.json"), encoding="utf-8") as fh:
        files = json.load(fh)["index"].get("files", {})
    keys = sorted(k for k in files if k.startswith("scratch:probe.cs#"))
    assert len(keys) == 2, keys
    # And each keeps only its OWN observation.
    assert sorted(files[keys[0]]["observations"] + files[keys[1]]["observations"]) \
        == ["ha", "hb"], files
    assert files[keys[0]]["observations"] != files[keys[1]]["observations"], files


def test_lint_rejects_a_session_temp_crossref_key(tmp: str) -> None:
    """The generator normalizes; lint is the backstop for any key that
    arrives another way (a hand edit, an older generator)."""
    drain, claims_dir, out = build(tmp, {"alpha": claims("alpha", [
        {"class": "domain", "topic": "one", "title": "T", "body": "b",
         "evidence": ["h1"]},
    ])})
    run_assemble(drain, claims_dir, out)
    if os.path.isdir(SCHEMA_DIR):
        import shutil
        shutil.copytree(SCHEMA_DIR, os.path.join(out, "schema"), dirs_exist_ok=True)

    crossref_path = os.path.join(out, "alpha", "crossref.json")
    with open(crossref_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    doc["index"].setdefault("files", {})[
        "/tmp/claude-1000/-home-user-projects-gzapp-claude9/x/scratchpad/p.ts"
    ] = {"observations": [], "slices": []}
    with open(crossref_path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2, sort_keys=True)

    proc = subprocess.run(
        [sys.executable, LINT, "--roles", out], capture_output=True, text=True)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "session-local temp path" in proc.stderr, proc.stderr


def main() -> int:
    cases = [
        test_places_claims_and_writes_provenance,
        test_unresolved_origin_is_stated_not_invented,
        test_index_lists_every_slice,
        test_index_banner_names_which_sections_load_when,
        test_committed_indexes_carry_the_banner_the_assembler_emits,
        test_drain_report_carries_the_watermark_forward,
        test_drain_report_records_unattributable_rows,
        test_drain_report_tolerates_a_drain_with_no_harvest_report,
        test_unattributable_rows_warn_loudly_but_do_not_fail_the_drain,
        test_a_fully_attributed_drain_says_nothing_about_bindings,
        test_output_is_byte_stable,
        test_slice_splits_when_it_exceeds_budget,
        test_budget_accounts_for_what_merge_mode_carries,
        test_claim_owned_by_two_roles_is_stored_once,
        test_shared_claims_reach_every_owner_crossref,
        test_crossref_maps_artifacts_to_slices,
        test_merge_mode_preserves_earlier_drains,
        test_index_keeps_slices_this_drain_did_not_touch,
        test_a_title_containing_a_newline_is_not_truncated,
        test_a_class_never_gets_both_a_flat_file_and_a_directory,
        test_a_hash_shaped_like_a_number_survives_the_frontmatter,
        test_carried_full_scope_survives_a_domain_only_drain,
        test_merge_target_strengthens_instead_of_appending,
        test_duplicate_title_keeps_both_claims,
        test_collision_is_reported_on_every_run,
        test_collision_survives_a_drain_with_an_empty_delta,
        test_authored_headings_are_not_mistaken_for_collisions,
        test_a_collision_slice_passes_lint,
        test_quoted_titles_survive_repeated_drains,
        test_merge_target_clears_the_collision_it_resolves,
        test_collision_scan_ignores_authored_documents,
        test_carried_sections_keep_their_citation_edges,
        test_carried_evidence_keeps_its_origin,
        test_domain_only_evidence_may_only_support_a_domain_claim,
        test_domain_only_evidence_is_accepted_on_a_domain_claim,
        test_hygiene_violation_fails_the_run,
        test_non_english_slice_is_flagged_by_lint,
        test_lint_detects_index_drift,
        test_scratchpad_references_are_normalized,
        test_a_tracked_scratchpad_path_is_left_alone,
        test_same_named_temp_artifacts_stay_distinct,
        test_lint_rejects_a_session_temp_crossref_key,
    ]
    # THE REGISTRY IS THE TRAP THIS GUARDS. Cases run because they are
    # listed here, not because they are named test_*, so a case that is
    # written and not listed passes silently and forever — it never
    # runs. Two were added that way and only a mutation that should have
    # failed, and did not, revealed it.
    declared = {
        name for name, obj in sorted(globals().items())
        if name.startswith("test_") and callable(obj)
    }
    listed = {case.__name__ for case in cases}
    missing = sorted(declared - listed)
    if missing:
        print(f"  FAIL registry: defined but never run: {missing}")
        return 1

    failures = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                case(tmp)
                print(f"  ok   {case.__name__}")
            except AssertionError as exc:
                failures += 1
                print(f"  FAIL {case.__name__}: {exc}")
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
