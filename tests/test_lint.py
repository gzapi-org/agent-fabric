#!/usr/bin/env python3
"""Behavioural tests for tools/fabric/lint.py.

Stdlib only; runnable as `python3 tests/test_lint.py`. Each case builds a
throwaway agent-fabric root in a temp directory, so nothing here touches
the real working copy. Fixtures copy the real schemas so schema validation
is actually exercised rather than skipped by `load_schema` returning None.

The corpus holds two kinds of markdown that look alike and are judged by
opposite rules. Knowledge slices carry provenance frontmatter and face the
role-template schema, the evidence rule, the budget and INDEX membership.
`identities/roles/<role>/skills/` and `commands/` hold installable payload
that role.py copies verbatim into `.claude/`, so their .md files carry
skill frontmatter and would fail every slice test at once.

The exemption is therefore narrow by construction, and each case below
pins one edge of it. **Each names the mutation it kills**:

  payload_is_exempt           <- reverting the payload branch; counting
                                 payload into `slices`
  hygiene_still_runs          <- exempting payload from the hygiene scan
  slices_are_still_linted     <- widening PAYLOAD_DIRS (e.g. adding "domain")
  exemption_is_anchored       <- widening PAYLOAD_DIRS; matching the dir
                                 name at any depth
  payload_shape_is_asserted   <- dropping payload_shape_findings
  index_need_not_list_payload <- reverting the payload branch; counting
                                 payload into `slices`

And the layout rules the split into identities/ and memory/ introduced:

  authored_classes_only_in_identities <- letting a charter-class slice
                                 into memory/ without evidence
  knowledge_not_in_identities <- letting a distilled slice sit beside the
                                 charter, where nothing indexes it
  index_lists_domain_slices   <- indexing only the project directory
  taxonomy_roles_are_catalogued <- a binding for a role nobody defined
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LINT = os.path.join(ROOT, "tools", "fabric", "lint.py")
REAL_SCHEMAS = os.path.join(ROOT, "identities", "schemas")
REAL_PROJECT_SCHEMAS = os.path.join(ROOT, "projects", "schemas")
REAL_ROUTING = os.path.join(ROOT, "routing")
REAL_ALIASES = os.path.join(ROOT, "runtime", "claude-code", "aliases.json")
PROJECT = "demo"

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

CHARTER = """---
role: "web-dev"
class: charter
description: "The web sub-apps."
tier: 1
distilled_at: "2026-09-06"
---

# web-dev
"""

NO_FRONTMATTER = "# Just a heading\n\nNo frontmatter at all.\n"

DIRTY_SKILL = """---
name: leaky
description: Payload carrying what must never be committed.
---

Run it against ghp_ABCDEFGHIJKLMNOP in Springfield.
"""

CATALOG = {"version": 1, "roles": [{"id": "web-dev", "title": "Web sub-app developer"}]}
TAXONOMY = {
    "version": 1, "project": PROJECT,
    "projects": {"include": ["demo"], "exclude": [], "unattributed_bucket": "observer-sessions"},
    "reattribution": {"path_markers": {"include": [], "exclude": []},
                      "keywords": {"include": [], "exclude": []}},
    "roles": [{"id": "web-dev", "paths": ["apps/admin_web/"]}],
}
PROFILES = {
    "version": 2,
    "defaults": {"session": "anthropic/claude-sonnet-5"},
    "roles": {"web-dev": {"session": "z-ai/glm-5.3", "capabilities": {"code-low": "z-ai/glm-5.3-flash"}}},
    "agents": {"web-dev-01": {"session": "~z-ai/glm-flash-latest"}},
}


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def make_base(root: str) -> str:
    """A minimal agent-fabric root with the real schemas, one catalogued
    role, and one project binding it."""
    fabric = os.path.join(root, "fabric")
    shutil.copytree(REAL_SCHEMAS, os.path.join(fabric, "identities", "schemas"))
    shutil.copytree(REAL_PROJECT_SCHEMAS, os.path.join(fabric, "projects", "schemas"))
    # The real routing files (minus the profiles, which each case writes)
    # and the Claude Code alias binding, so the routing checks actually run.
    shutil.copytree(REAL_ROUTING, os.path.join(fabric, "routing"),
                    ignore=shutil.ignore_patterns("profiles.json"))
    os.makedirs(os.path.join(fabric, "runtime", "claude-code"))
    shutil.copy2(REAL_ALIASES, os.path.join(fabric, "runtime", "claude-code", "aliases.json"))
    write(os.path.join(fabric, "identities", "roles", "catalog.json"), json.dumps(CATALOG))
    write(os.path.join(fabric, "projects", PROJECT, "taxonomy.json"), json.dumps(TAXONOMY))
    write(os.path.join(fabric, "identities", "roles", "web-dev", "charter.md"), CHARTER)
    return fabric


def ident(fabric: str, *rest: str) -> str:
    return os.path.join(fabric, "identities", "roles", "web-dev", *rest)


def dom(fabric: str, *rest: str) -> str:
    return os.path.join(fabric, "memory", "domains", "web-dev", *rest)


def proj(fabric: str, *rest: str) -> str:
    return os.path.join(fabric, "memory", "projects", PROJECT, "web-dev", *rest)


CHARTER_LINE = "- [`identities/roles/web-dev/charter.md`](identities/roles/web-dev/charter.md) — The web sub-apps.\n"


def index_for(*entries: str) -> str:
    return "# Index\n\n" + CHARTER_LINE + "".join(entries)


def run_lint(fabric: str, *extra: str) -> tuple[int, str]:
    proc = subprocess.run([sys.executable, LINT, "--fabric", fabric, *extra], capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


HYGIENE = {"patterns": [{"pattern": "\\bSpringfield\\b", "flags": "i", "label": "city name"}]}


def with_project_hygiene(root: str) -> str:
    """A working copy for the demo project carrying its own hygiene list —
    the deployment's names are the project's to ban, not the fabric's."""
    wc = os.path.join(root, "wc-demo")
    write(os.path.join(wc, ".agent-fabric", "hygiene.json"), json.dumps(HYGIENE))
    return f"{PROJECT}={wc}"


def case_clean_base_passes() -> None:
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        code, out = run_lint(fabric)
        assert code == 0, f"a minimal well-formed root tripped the linter:\n{out}"


def case_payload_is_exempt() -> None:
    """Well-formed payload passes. Kills: reverting the payload branch."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "skills", "webapp-testing", "SKILL.md"), SKILL)
        write(ident(fabric, "commands", "check.md"), SKILL)
        code, out = run_lint(fabric)
        assert code == 0, f"well-formed payload tripped the linter:\n{out}"


def case_hygiene_still_runs_over_payload() -> None:
    """Payload is exempt from slice checks, never from the hygiene scan."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "skills", "leaky", "SKILL.md"), DIRTY_SKILL)
        code, out = run_lint(fabric)
        assert code == 1, f"a credential in payload passed CI:\n{out}"
        assert "credential" in out, f"the token went unreported:\n{out}"
        assert "city name" not in out, f"a deployment name was banned with no project list in sight:\n{out}"
        # The city is banned by the PROJECT's list, through its working copy.
        code, out = run_lint(fabric, "--working-copy", with_project_hygiene(root))
        assert code == 1 and "city name" in out, f"the banned place name went unreported:\n{out}"


def case_slices_are_still_linted() -> None:
    """Kills: widening PAYLOAD_DIRS to swallow a slice directory."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "skills", "ok", "SKILL.md"), SKILL)
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(dom(fabric, "domain", "bad.md"), NO_FRONTMATTER)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`memory/domains/web-dev/domain/good.md`](memory/domains/web-dev/domain/good.md) — A well-formed slice, shaped like the real ones\n",
            "- [`memory/domains/web-dev/domain/bad.md`](memory/domains/web-dev/domain/bad.md) — x\n"))
        code, out = run_lint(fabric)
        assert code == 1, f"a slice with no frontmatter should fail:\n{out}"
        assert "domain/bad.md" in out, f"the bad slice went unreported:\n{out}"
        assert "good.md" not in out, f"the well-formed slice was flagged:\n{out}"


def case_exemption_is_anchored_at_the_role_root() -> None:
    """Only `identities/roles/<role>/skills/` is payload. Keying on the
    name alone would let anyone park unlinted files under `domain/skills/`."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(dom(fabric, "domain", "skills", "sneaky.md"), NO_FRONTMATTER)
        code, out = run_lint(fabric)
        assert code == 1, f"a nested skills/ must still be linted:\n{out}"
        assert "sneaky.md" in out, f"nested payload escaped the linter:\n{out}"


def case_payload_shape_is_asserted() -> None:
    """Misplaced payload is loud here, because role.py drops it silently."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "skills", "single-file.md"), SKILL)
        os.makedirs(ident(fabric, "skills", "empty-dir"))
        write(ident(fabric, "commands", "nested", "deep.md"), SKILL)
        code, out = run_lint(fabric)
        assert code == 1, f"misplaced payload passed silently:\n{out}"
        assert "single-file.md" in out, f"a non-directory under skills/ went unreported:\n{out}"
        assert "empty-dir" in out, f"a skill with no SKILL.md went unreported:\n{out}"
        assert "commands/nested" in out, f"a directory under commands/ went unreported:\n{out}"


def case_index_need_not_list_payload() -> None:
    """A role with an INDEX.md and payload — the real web-dev shape."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`memory/domains/web-dev/domain/good.md`](memory/domains/web-dev/domain/good.md) — A well-formed slice, shaped like the real ones\n"))
        write(ident(fabric, "skills", "webapp-testing", "SKILL.md"), SKILL)
        code, out = run_lint(fabric)
        assert code == 0, f"payload was counted against the index:\n{out}"
        assert "index has drifted" not in out, f"index drift reported for payload:\n{out}"


def case_index_description_drift_is_caught() -> None:
    """An INDEX.md entry whose description no longer matches the slice."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`memory/domains/web-dev/domain/good.md`](memory/domains/web-dev/domain/good.md) — STALE WORDING\n"))
        code, out = run_lint(fabric)
        assert code != 0, f"a drifted index description was not caught:\n{out}"
        assert "STALE WORDING" in out, f"the finding does not quote the index text:\n{out}"
        assert "A well-formed slice" in out, f"the finding does not quote the slice text:\n{out}"


def case_index_lists_domain_slices() -> None:
    """A role's domain slices live outside the project directory and must
    still be indexed there. Kills: indexing only the project directory."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(proj(fabric, "INDEX.md"), index_for())
        code, out = run_lint(fabric)
        assert code == 1, f"an unindexed domain slice passed:\n{out}"
        assert "does not list memory/domains/web-dev/domain/good.md" in out, out
        # And a domain with slices that no project indexes at all is named.
        os.remove(proj(fabric, "INDEX.md"))
        os.rmdir(proj(fabric))
        code, out = run_lint(fabric)
        assert code == 1 and "indexed by no project" in out, out


def case_quoted_description_round_trips() -> None:
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        inner = 'Uses the two-step "commented out, later" pattern'
        write(dom(fabric, "domain", "good.md"), SLICE.replace(
            'description: "A well-formed slice, shaped like the real ones"', f'description: "{inner}"'))
        write(proj(fabric, "INDEX.md"), index_for(
            f"- [`memory/domains/web-dev/domain/good.md`](memory/domains/web-dev/domain/good.md) — {inner}\n"))
        code, out = run_lint(fabric)
        assert code == 0, f"an unescaped-quote description was read differently than assemble reads it:\n{out}"


def case_authored_classes_only_in_identities() -> None:
    """A charter-class file under memory/ is a hand-authored claim with no
    evidence smuggled past provenance."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(proj(fabric, "charter.md"), CHARTER)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`memory/projects/demo/web-dev/charter.md`](memory/projects/demo/web-dev/charter.md) — The web sub-apps.\n"))
        code, out = run_lint(fabric)
        assert code == 1 and "belongs under identities/roles/" in out, out


def case_knowledge_not_in_identities() -> None:
    """A distilled slice beside the charter is knowledge nothing indexes."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "solution.md"), SLICE.replace("class: domain", "class: solution"))
        code, out = run_lint(fabric)
        assert code == 1 and "belongs under memory/" in out, out


def case_taxonomy_roles_are_catalogued() -> None:
    """A project may bind only roles the catalogue defines, and only with
    repository-relative paths."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        tax = dict(TAXONOMY)
        tax["roles"] = [{"id": "web-dev", "paths": ["apps/"]}, {"id": "ghost", "paths": ["/home/someone/x/"]}]
        write(os.path.join(fabric, "projects", PROJECT, "taxonomy.json"), json.dumps(tax))
        code, out = run_lint(fabric)
        assert code == 1, out
        assert "'ghost' is not in identities/roles/catalog.json" in out, out
        assert "machine-specific" in out, out


def write_profiles(fabric: str, doc: dict) -> None:
    write(os.path.join(fabric, "routing", "profiles.json"), json.dumps(doc))


def case_model_profiles_layered_file_passes() -> None:
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write_profiles(fabric, PROFILES)
        code, out = run_lint(fabric)
        assert code == 0, f"a well-formed layered profile tripped the linter:\n{out}"


def case_model_profiles_cheap_review_is_refused() -> None:
    """A row that moves the review class off the review-grade list is a
    finding; a row that moves a CODING class to a cheap model is not."""
    import copy
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["agents"]["web-dev-01"]["capabilities"] = {"review": "z-ai/glm-5.3-flash"}
        write_profiles(fabric, doc)
        code, out = run_lint(fabric)
        assert code == 1, f"a non-review-grade review model passed:\n{out}"
        assert "agents.web-dev-01" in out and "review-grade" in out, f"the row went unnamed:\n{out}"
        doc = copy.deepcopy(PROFILES)
        doc["agents"]["web-dev-01"]["capabilities"] = {"code-high": "z-ai/glm-5.3-flash"}
        write_profiles(fabric, doc)
        code, out = run_lint(fabric)
        assert code == 0, f"a cheap coding class was review-gated:\n{out}"


def case_model_profiles_agents_are_logins() -> None:
    import copy
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["agents"]["clone-74e1ddd4096a45ce"] = {"session": "z-ai/glm-5.3"}
        write_profiles(fabric, doc)
        code, out = run_lint(fabric)
        assert code == 1 and "is not a Linux login" in out, out


def case_model_profiles_unknown_role_is_refused() -> None:
    import copy
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["roles"]["wed-dev"] = doc["roles"].pop("web-dev")
        write_profiles(fabric, doc)
        code, out = run_lint(fabric)
        assert code == 1, f"a typo'd role key passed:\n{out}"
        assert "roles.wed-dev" in out, f"the unknown role went unnamed:\n{out}"


def case_model_profiles_schema_is_enforced() -> None:
    import copy
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        doc = copy.deepcopy(PROFILES)
        doc["defaults"]["session"] = "Claude Sonnet"
        write_profiles(fabric, doc)
        code, out = run_lint(fabric)
        assert code == 1, f"a malformed model id passed the schema:\n{out}"
        assert "routing/profiles.json" in out, f"the file went unnamed:\n{out}"


def _write_license_layout(fabric: str, registry: dict, reuse_toml: str, licenses: tuple = ("Apache-2.0",)) -> None:
    os.makedirs(os.path.join(fabric, "projects"), exist_ok=True)
    with open(os.path.join(fabric, "projects", "registry.json"), "w", encoding="utf-8") as fh:
        json.dump(registry, fh)
    with open(os.path.join(fabric, "REUSE.toml"), "w", encoding="utf-8") as fh:
        fh.write(reuse_toml)
    shutil.rmtree(os.path.join(fabric, "LICENSES"), ignore_errors=True)
    os.makedirs(os.path.join(fabric, "LICENSES"))
    for lic in licenses:
        with open(os.path.join(fabric, "LICENSES", lic + ".txt"), "w", encoding="utf-8") as fh:
            fh.write(lic + "\n")


REUSE_OK = """version = 1
[[annotations]]
path = ["**"]
precedence = "aggregate"
SPDX-FileCopyrightText = "t"
SPDX-License-Identifier = "Apache-2.0"
"""


def case_the_repository_is_one_license() -> None:
    """Apache-2.0 throughout: REUSE.toml may assign nothing else, every
    identifier it uses has its text, every project names ITS OWN license
    as information, and no project knowledge lives here."""
    registry = {"projects": {
        "agent-fabric": {"license": "Apache-2.0"},
        PROJECT: {"license": "LicenseRef-demo-Proprietary"},
    }}
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        _write_license_layout(fabric, registry, REUSE_OK)
        code, out = run_lint(fabric)
        assert code == 0, f"a single-license layout was refused:\n{out}"
        # a second license assigned in REUSE.toml
        _write_license_layout(fabric, registry, REUSE_OK + '[[annotations]]\npath = ["projects/demo/**"]\nprecedence = "override"\nSPDX-FileCopyrightText = "t"\nSPDX-License-Identifier = "LicenseRef-demo-Proprietary"\n', licenses=("Apache-2.0", "LicenseRef-demo-Proprietary"))
        code, out = run_lint(fabric)
        assert code == 1 and "Apache-2.0 throughout" in out, f"a second license passed:\n{out}"
        # the one license has no text
        _write_license_layout(fabric, registry, REUSE_OK, licenses=())
        code, out = run_lint(fabric)
        assert code == 1 and "no LICENSES/Apache-2.0.txt" in out, f"missing license text passed:\n{out}"
        # a project naming no license at all
        _write_license_layout(fabric, {"projects": {"agent-fabric": {"license": "Apache-2.0"}, PROJECT: {}}}, REUSE_OK)
        code, out = run_lint(fabric)
        assert code == 1 and "project 'demo' names no license" in out, f"licenseless project passed:\n{out}"
        # project knowledge in the fabric
        _write_license_layout(fabric, registry, REUSE_OK)
        os.makedirs(os.path.join(fabric, "memory", "projects", PROJECT), exist_ok=True)
        code, out = run_lint(fabric)
        assert code == 1 and "lives in the project's repository" in out, f"project knowledge here passed:\n{out}"


def main() -> int:
    cases = [
        case_clean_base_passes,
        case_index_description_drift_is_caught,
        case_index_lists_domain_slices,
        case_quoted_description_round_trips,
        case_payload_is_exempt,
        case_hygiene_still_runs_over_payload,
        case_slices_are_still_linted,
        case_exemption_is_anchored_at_the_role_root,
        case_payload_shape_is_asserted,
        case_index_need_not_list_payload,
        case_authored_classes_only_in_identities,
        case_knowledge_not_in_identities,
        case_taxonomy_roles_are_catalogued,
        case_model_profiles_layered_file_passes,
        case_model_profiles_cheap_review_is_refused,
        case_model_profiles_agents_are_logins,
        case_model_profiles_unknown_role_is_refused,
        case_model_profiles_schema_is_enforced,
        case_the_repository_is_one_license,
    ]
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
