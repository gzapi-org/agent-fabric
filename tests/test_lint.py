#!/usr/bin/env python3
"""Behavioural tests for tools/roles/lint.py.

Stdlib only; runnable as `python3 test_lint.py` or under pytest. Each case
builds a throwaway role base in a temp directory, so nothing here touches
the real working copy. Fixtures copy the real `.roles/schema/` so the
role-template validation is actually exercised rather than skipped by
`load_schema` returning None.

A role directory holds two kinds of file that look alike and are judged by
opposite rules. Knowledge slices carry provenance frontmatter and face the
role-template schema, the evidence rule, the budget and INDEX membership.
`skills/` and `commands/` hold installable payload that switch.py copies
verbatim into `.claude/`, so their .md files carry skill frontmatter and
would fail every slice test at once.

The exemption is therefore narrow by construction, and each case below
pins one edge of it. **Each names the mutation it kills**, because they
fail against DIFFERENT mutations and a reader who assumes otherwise will
delete one as redundant:

  payload_is_exempt           <- reverting the payload branch; counting
                                 payload into `slices`
  hygiene_still_runs          <- exempting payload from the hygiene scan
                                 (the ONLY case that catches this)
  slices_are_still_linted     <- widening PAYLOAD_DIRS (e.g. adding "domain")
  exemption_is_anchored       <- widening PAYLOAD_DIRS; matching the dir
                                 name at any depth
  payload_shape_is_asserted   <- dropping payload_shape_findings
                                 (the ONLY case that catches this)
  index_need_not_list_payload <- reverting the payload branch; counting
                                 payload into `slices`

Verified by running each mutation against every case: all six mutations
are caught and no case is dead weight. Two cases overlap on a pair of
mutations, which is coverage, not redundancy — the two marked ONLY are
each the sole cover for theirs.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LINT = os.path.join(HERE, "lint.py")
REAL_SCHEMA = os.path.join(HERE, os.pardir, os.pardir, ".roles", "schema")

SKILL = """---
name: webapp-testing
description: Drive a running web app with Playwright.
license: Apache-2.0
---

# Web Application Testing

Payload, not a claim.
"""

SLICE = """---
role: "web-dev"
class: domain
description: "A well-formed slice, shaped like the real ones"
tier: 2
distilled_at: "2026-09-06"
derived_from:
  - 1e965e01a6ef7e31
  - 7b465cbdb303fddf
---

A claim with provenance.
"""

NO_FRONTMATTER = "# Just a heading\n\nNo frontmatter at all.\n"

# A leaked token and a banned place name, in payload that lint must still see.
DIRTY_SKILL = """---
name: leaky
description: Payload carrying what must never be committed.
---

Run it against ghp_ABCDEFGHIJKLMNOP in Springfield.
"""


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def make_base(root: str) -> str:
    """A role base with the real schemas, so schema checks actually run."""
    roles = os.path.join(root, ".roles")
    os.makedirs(roles, exist_ok=True)
    if os.path.isdir(REAL_SCHEMA):
        shutil.copytree(REAL_SCHEMA, os.path.join(roles, "schema"))
    return roles


def run_lint(roles_dir: str) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, LINT, "--roles", roles_dir],
        capture_output=True, text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def case_payload_is_exempt() -> None:
    """Well-formed payload passes. Kills: reverting the payload branch."""
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "skills", "webapp-testing", "SKILL.md"), SKILL)
        write(os.path.join(roles, "web-dev", "commands", "check.md"), SKILL)
        code, out = run_lint(roles)
        assert code == 0, f"well-formed payload tripped the linter:\n{out}"


def case_hygiene_still_runs_over_payload() -> None:
    """Payload is exempt from slice checks, never from the hygiene scan.

    lint.py is the only CI pass over .roles/**, and switch.py copies payload
    into .claude/ in every clone that adopts the role. Kills: extending the
    exemption to the banned-pattern scan.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "skills", "leaky", "SKILL.md"), DIRTY_SKILL)
        code, out = run_lint(roles)
        assert code == 1, f"a credential in payload passed CI:\n{out}"
        assert "credential" in out, f"the token went unreported:\n{out}"
        assert "city name" in out, f"the banned place name went unreported:\n{out}"


def case_slices_are_still_linted() -> None:
    """Kills: widening PAYLOAD_DIRS to swallow a slice directory."""
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "skills", "ok", "SKILL.md"), SKILL)
        write(os.path.join(roles, "web-dev", "domain", "good.md"), SLICE)
        write(os.path.join(roles, "web-dev", "domain", "bad.md"), NO_FRONTMATTER)
        code, out = run_lint(roles)
        assert code == 1, f"a slice with no frontmatter should fail:\n{out}"
        assert "domain/bad.md" in out, f"the bad slice went unreported:\n{out}"
        assert "good.md" not in out, f"the well-formed slice was flagged:\n{out}"


def case_exemption_is_anchored_at_the_role_root() -> None:
    """Kills: matching the directory NAME at any depth.

    Only `<role>/skills/` is payload. Keying on the name alone would let
    anyone park unlinted files under `domain/skills/`.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "domain", "skills", "sneaky.md"), NO_FRONTMATTER)
        code, out = run_lint(roles)
        assert code == 1, f"a nested skills/ must still be linted:\n{out}"
        assert "sneaky.md" in out, f"nested payload escaped the linter:\n{out}"


def case_payload_shape_is_asserted() -> None:
    """Misplaced payload is loud here, because switch.py drops it silently.

    switch.py installs a directory under skills/ and a .md file under
    commands/, skipping anything else without a word. Kills: dropping
    payload_shape_findings and leaving the exemption as a plain hole.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "skills", "single-file.md"), SKILL)
        os.makedirs(os.path.join(roles, "web-dev", "skills", "empty-dir"))
        write(os.path.join(roles, "web-dev", "commands", "nested", "deep.md"), SKILL)
        code, out = run_lint(roles)
        assert code == 1, f"misplaced payload passed silently:\n{out}"
        assert "single-file.md" in out, f"a non-directory under skills/ went unreported:\n{out}"
        assert "empty-dir" in out, f"a skill with no SKILL.md went unreported:\n{out}"
        assert "commands/nested" in out, f"a directory under commands/ went unreported:\n{out}"


def case_index_need_not_list_payload() -> None:
    """A role with BOTH an INDEX.md and payload — the real .roles/web-dev shape.

    Kills: counting payload toward INDEX membership, which would make every
    role that ships a skill report a drifted index.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "domain", "good.md"), SLICE)
        write(os.path.join(roles, "web-dev", "INDEX.md"), "# Index\n\n- [good](domain/good.md)\n")
        write(os.path.join(roles, "web-dev", "skills", "webapp-testing", "SKILL.md"), SKILL)
        code, out = run_lint(roles)
        assert code == 0, f"payload was counted against the index:\n{out}"
        assert "index has drifted" not in out, f"index drift reported for payload:\n{out}"


def case_index_description_drift_is_caught() -> None:
    """An INDEX.md entry whose description no longer matches the slice.

    Kills: comparing only link PATHS. That was the real blind spot — lint
    reported "clean" while INDEX.md described a slice with superseded
    wording, and the index is the ONLY thing a session reads before deciding
    whether to load a slice, so a stale one silently misroutes retrieval.
    Two independent instances landed the same day in different roles.

    The line shape here is assemble.py's exactly — ``- [`path`](path) — text``
    — because that is what the generator writes and therefore what the check
    has to understand.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "domain", "good.md"), SLICE)
        write(
            os.path.join(roles, "web-dev", "INDEX.md"),
            "# Index\n\n- [`domain/good.md`](domain/good.md) — STALE WORDING\n",
        )
        code, out = run_lint(roles)
        assert code != 0, f"a drifted index description was not caught:\n{out}"
        assert "STALE WORDING" in out, f"the finding does not quote the index text:\n{out}"
        assert "A well-formed slice" in out, f"the finding does not quote the slice text:\n{out}"


def case_index_description_match_passes() -> None:
    """The same shape, in agreement, must not fire.

    Kills: a check that reports drift for every assemble-shaped line, which
    would make the guard unusable and get it reverted rather than fixed.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write(os.path.join(roles, "web-dev", "domain", "good.md"), SLICE)
        write(
            os.path.join(roles, "web-dev", "INDEX.md"),
            "# Index\n\n- [`domain/good.md`](domain/good.md) — "
            "A well-formed slice, shaped like the real ones\n",
        )
        code, out = run_lint(roles)
        assert code == 0, f"a matching index description was reported as drift:\n{out}"


def case_quoted_description_round_trips() -> None:
    """A description whose own text contains double quotes.

    Kills: lint keeping the outer quotes when json.loads fails on unescaped
    inner ones, which assemble.decode_scalar strips. The two parsers then
    disagreed about the same file — lint saw '"...text..."' where assemble saw
    '...text...' — so every length, pattern and equality judgement lint made
    on that field was made on a different string than the index was generated
    from. Three real slices carry this shape.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        inner = 'Uses the two-step "commented out, later" pattern'
        slice_text = SLICE.replace(
            'description: "A well-formed slice, shaped like the real ones"',
            f'description: "{inner}"',
        )
        write(os.path.join(roles, "web-dev", "domain", "good.md"), slice_text)
        write(
            os.path.join(roles, "web-dev", "INDEX.md"),
            f"# Index\n\n- [`domain/good.md`](domain/good.md) — {inner}\n",
        )
        code, out = run_lint(roles)
        assert code == 0, f"an unescaped-quote description was read differently than assemble reads it:\n{out}"


PROFILES = {
    "version": 1,
    "review_grade": ["anthropic/claude-opus-5"],
    "defaults": {
        "session": "anthropic/claude-sonnet-5",
        "tiers": {
            "haiku": "anthropic/claude-haiku-4.5",
            "sonnet": "anthropic/claude-sonnet-5",
            "opus": "anthropic/claude-opus-5",
            "fable": "anthropic/claude-fable-5.1",
        },
    },
    "roles": {"web-dev": {"session": "z-ai/glm-5.3", "tiers": {"haiku": "z-ai/glm-5.3-flash"}}},
    "instances": {"web-dev-01": {"session": "~z-ai/glm-flash-latest"}},
}

TAXONOMY = {
    "version": 1,
    "projects": {"include": ["gzapp"], "exclude": [], "unattributed_bucket": "observer-sessions"},
    "reattribution": {"path_markers": {"include": [], "exclude": []},
                      "keywords": {"include": [], "exclude": []}},
    "roles": [{"id": "web-dev", "paths": ["apps/admin_web/"]}],
}


def write_profiles(roles: str, doc: dict) -> None:
    import json

    write(os.path.join(roles, "registry", "model-profiles.json"), json.dumps(doc))
    # The taxonomy is what gives lint its set of known roles.
    write(os.path.join(roles, "taxonomy.json"), json.dumps(TAXONOMY))


def case_model_profiles_layered_file_passes() -> None:
    """A role row that sets only cheap tiers inherits the default opus.

    Kills: checking each layer's own opus instead of the merged value,
    which would make every partial row a false finding.
    """
    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        write_profiles(roles, PROFILES)
        code, out = run_lint(roles)
        assert code == 0, f"a well-formed layered profile tripped the linter:\n{out}"


def case_model_profiles_cheap_opus_is_refused() -> None:
    """A row that moves the opus tier off the review-grade list is a finding.

    The review class resolves through that pin; a cheaper model there is a
    silent downgrade of every substitute review. Kills: dropping the
    review_grade invariant and trusting the schema alone.
    """
    import copy

    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["instances"]["web-dev-01"]["tiers"] = {"opus": "z-ai/glm-5.3-flash"}
        write_profiles(roles, doc)
        code, out = run_lint(roles)
        assert code == 1, f"a non-review-grade opus passed:\n{out}"
        assert "instances.web-dev-01" in out and "review_grade" in out, f"the row went unnamed:\n{out}"


def case_model_profiles_unknown_role_is_refused() -> None:
    """A roles.<name> key must be a taxonomy role, or nothing resolves to it."""
    import copy

    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["roles"]["wed-dev"] = doc["roles"].pop("web-dev")
        write_profiles(roles, doc)
        code, out = run_lint(roles)
        assert code == 1, f"a typo'd role key passed:\n{out}"
        assert "roles.wed-dev" in out, f"the unknown role went unnamed:\n{out}"


def case_model_profiles_schema_is_enforced() -> None:
    """A model reference the endpoint would not accept fails the schema."""
    import copy

    with tempfile.TemporaryDirectory() as root:
        roles = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["defaults"]["tiers"]["haiku"] = "Claude Haiku"
        write_profiles(roles, doc)
        code, out = run_lint(roles)
        assert code == 1, f"a malformed model id passed the schema:\n{out}"
        assert "model-profiles.json" in out, f"the file went unnamed:\n{out}"


def main() -> int:
    cases = [
        case_index_description_drift_is_caught,
        case_index_description_match_passes,
        case_quoted_description_round_trips,
        case_payload_is_exempt,
        case_hygiene_still_runs_over_payload,
        case_slices_are_still_linted,
        case_exemption_is_anchored_at_the_role_root,
        case_payload_shape_is_asserted,
        case_index_need_not_list_payload,
        case_model_profiles_layered_file_passes,
        case_model_profiles_cheap_opus_is_refused,
        case_model_profiles_unknown_role_is_refused,
        case_model_profiles_schema_is_enforced,
    ]
    for case in cases:
        case()
        print(f"  ok  {case.__name__}")
    print(f"test_lint: {len(cases)} case(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
