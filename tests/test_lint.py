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
REAL_PROMPT = os.path.join(ROOT, "identities", "prompt")
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
    # The launch-prompt sections every session appends; lint requires them.
    shutil.copytree(REAL_PROMPT, os.path.join(fabric, "identities", "prompt"))
    write(os.path.join(fabric, "identities", "roles", "catalog.json"), json.dumps(CATALOG))
    write(os.path.join(fabric, "projects", PROJECT, "taxonomy.json"), json.dumps(TAXONOMY))
    write(os.path.join(fabric, "identities", "roles", "web-dev", "charter.md"), CHARTER)
    return fabric


def ident(fabric: str, *rest: str) -> str:
    return os.path.join(fabric, "identities", "roles", "web-dev", *rest)


def dom(fabric: str, *rest: str) -> str:
    return os.path.join(fabric, "memory", "domains", "web-dev", *rest)


def wc_demo(fabric: str) -> str:
    """The demo project's working copy: a sibling of the fixture fabric,
    where the project's memory lives (<wc>/.agent-fabric/memory/)."""
    return os.path.join(os.path.dirname(fabric), "wc-demo")


def proj(fabric: str, *rest: str) -> str:
    return os.path.join(wc_demo(fabric), ".agent-fabric", "memory", "web-dev", *rest)


# Links a project's index writes to fabric-side slices go through the
# sibling checkout, whatever the fixture fabric is called (layout.link_rel).
F = "../agent-fabric/"
CHARTER_LINE = f"- [`{F}identities/roles/web-dev/charter.md`]({F}identities/roles/web-dev/charter.md) — The web sub-apps.\n"


def index_for(*entries: str) -> str:
    return "# Index\n\n" + CHARTER_LINE + "".join(entries)


def run_lint(fabric: str, *extra: str) -> tuple[int, str]:
    # The demo working copy is named whenever it exists, so lint sees the
    # project's memory where it lives; a case may name it itself too.
    wc = wc_demo(fabric)
    if os.path.isdir(wc) and not any(a.startswith(f"{PROJECT}=") for a in extra):
        extra = ("--working-copy", f"{PROJECT}={wc}", *extra)
    proc = subprocess.run([sys.executable, LINT, "--fabric", fabric, *extra], capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


HYGIENE = {"patterns": [{"pattern": "\\bspringfield\\b", "flags": "i", "label": "city name"}]}


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


def case_secrets_are_refused_by_shape() -> None:
    """Passwords, keys and tokens assigned a value, key material and known
    token shapes are refused wherever they appear; a sentence about a
    token, a placeholder and an environment variable's name are not."""
    leaks = ["password=hunter2hunter2", "api_key: 0123456789abcdef", 'ANTHROPIC_API_KEY="sk-ant-api03-abcdefghijklmnopqrstuvwxyz"',
             "token = ZmFrZS10b2tlbi12YWx1ZQ", "AKIAIOSFODNN7EXAMPLE", "-----BEGIN RSA PRIVATE KEY-----",
             "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
             "dp.st.dev.abcdefghijklmnop", "client_secret: q1w2e3r4t5y6u7i8"]
    fine = ["the token arrives with fabric-secrets sync", "export CLAUDE_BRIDGE_AUTH_TOKEN=<value>", "token_env_file: infra/local/.env.local",
            "password: (redacted)", "api_key: ${OPENROUTER_API_KEY}", "secret: none", "A bearer token is sent on every call."]
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        for leak in leaks:
            write(dom(fabric, "domain", "leak.md"), SLICE.replace("A claim with provenance.", f"Set {leak} and retry."))
            code, out = run_lint(fabric)
            assert code == 1 and "credential" in out, f"a secret passed: {leak!r}\n{out}"
        for text in fine:
            write(dom(fabric, "domain", "leak.md"), SLICE.replace("A claim with provenance.", text))
            code, out = run_lint(fabric)
            assert code == 0, f"a harmless line was refused: {text!r}\n{out}"


def case_a_persons_name_is_refused_everywhere() -> None:
    """The fabric's own hygiene list (policies/hygiene.json) applies with no
    project list in sight: a person is named by role. Kills: dropping the
    fabric list from load_hygiene_patterns."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        os.makedirs(os.path.join(fabric, "policies"), exist_ok=True)
        shutil.copy(os.path.join(ROOT, "policies", "hygiene.json"), os.path.join(fabric, "policies", "hygiene.json"))
        write(dom(fabric, "domain", "named.md"), SLICE.replace("A claim with provenance.", "Andrea Benetton asked for it; Andrea caught the workaround."))
        code, out = run_lint(fabric)
        assert code == 1 and "person's name" in out and "the CEO" in out, f"a person's name passed, or the finding does not say what to write instead:\n{out}"
        write(dom(fabric, "domain", "named.md"), SLICE.replace("A claim with provenance.", "The CEO asked for it; the CEO caught the workaround."))
        code, out = run_lint(fabric)
        assert code == 0, f"naming the role tripped the linter:\n{out}"


def case_slices_are_still_linted() -> None:
    """Kills: widening PAYLOAD_DIRS to swallow a slice directory."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "skills", "ok", "SKILL.md"), SKILL)
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(dom(fabric, "domain", "bad.md"), NO_FRONTMATTER)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`../agent-fabric/memory/domains/web-dev/domain/good.md`](../agent-fabric/memory/domains/web-dev/domain/good.md) — A well-formed slice, shaped like the real ones\n",
            "- [`../agent-fabric/memory/domains/web-dev/domain/bad.md`](../agent-fabric/memory/domains/web-dev/domain/bad.md) — x\n"))
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
            "- [`../agent-fabric/memory/domains/web-dev/domain/good.md`](../agent-fabric/memory/domains/web-dev/domain/good.md) — A well-formed slice, shaped like the real ones\n"))
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
            "- [`../agent-fabric/memory/domains/web-dev/domain/good.md`](../agent-fabric/memory/domains/web-dev/domain/good.md) — STALE WORDING\n"))
        code, out = run_lint(fabric)
        assert code != 0, f"a drifted index description was not caught:\n{out}"
        assert "STALE WORDING" in out, f"the finding does not quote the index text:\n{out}"
        assert "A well-formed slice" in out, f"the finding does not quote the slice text:\n{out}"


def case_a_sibling_working_copy_is_linted_unasked() -> None:
    """The working copies beside the checkout are linted without being
    named, so a charter edited here with the project's index describing
    the old one fails the fabric's own run before the project's CI does
    (2026-09-17). The sibling is found by its remote against the registry;
    --no-siblings turns it off. Kills: dropping the discovery, or making
    it ignore a drifted index."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(dom(fabric, "domain", "good.md"), SLICE)
        wc = wc_demo(fabric)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`../agent-fabric/memory/domains/web-dev/domain/good.md`](../agent-fabric/memory/domains/web-dev/domain/good.md) — STALE WORDING\n"))
        # a git working copy whose remote the fixture registry maps to the demo project
        _write_license_layout(fabric, {"version": 1, "projects": {
            "agent-fabric": {"license": "Apache-2.0", "remotes": ["git@github.com:gzapi-org/agent-fabric.git"]},
            "demo": {"license": "Apache-2.0", "remotes": ["git@example.com:org/demo.git"]}}}, REUSE_OK)
        subprocess.run(["git", "-C", wc, "init", "-q"], check=True)
        subprocess.run(["git", "-C", wc, "remote", "add", "origin", "git@example.com:org/demo.git"], check=True)
        proc = subprocess.run([sys.executable, LINT, "--fabric", fabric], capture_output=True, text=True)
        assert proc.returncode != 0 and "STALE WORDING" in proc.stdout + proc.stderr, f"the sibling's drifted index passed unasked:\n{proc.stdout}{proc.stderr}"
        proc = subprocess.run([sys.executable, LINT, "--fabric", fabric, "--no-siblings"], capture_output=True, text=True)
        assert proc.returncode == 0, f"--no-siblings still looked beside the checkout:\n{proc.stdout}{proc.stderr}"


def case_index_lists_domain_slices() -> None:
    """A role's domain slices live outside the project directory and must
    still be indexed there. Kills: indexing only the project directory."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(proj(fabric, "INDEX.md"), index_for())
        code, out = run_lint(fabric)
        assert code == 1, f"an unindexed domain slice passed:\n{out}"
        assert "does not list ../agent-fabric/memory/domains/web-dev/domain/good.md" in out, out
        # And a domain with slices that no project indexes at all is named.
        os.remove(proj(fabric, "INDEX.md"))
        os.rmdir(proj(fabric))
        code, out = run_lint(fabric)
        assert code == 1 and "indexed by no project" in out, out


def case_domain_bound_by_an_unseen_project_is_not_judged() -> None:
    """A domain whose role no VISIBLE project binds is not required to be
    indexed: another repository's CI passes only its own working copy and
    must not fail on a role that repository never holds. Kills: judging
    every domain whenever any project is visible (the 2026-09-17 queue
    failure)."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        # the fixture project binds web-dev and indexes it; a second role's
        # domain has slices and no index anywhere this run can see
        write(dom(fabric, "domain", "good.md"), SLICE)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`../agent-fabric/memory/domains/web-dev/domain/good.md`](../agent-fabric/memory/domains/web-dev/domain/good.md) — A good slice\n"))
        other = os.path.join(fabric, "memory", "domains", "db-admin", "domain", "plan.md")
        write(other, SLICE.replace('role: "web-dev"', 'role: "db-admin"'))
        cat = json.load(open(os.path.join(fabric, "identities", "roles", "catalog.json"), encoding="utf-8"))
        cat["roles"].append({"id": "db-admin", "title": "DB"})
        write(os.path.join(fabric, "identities", "roles", "catalog.json"), json.dumps(cat))
        code, out = run_lint(fabric)
        assert "indexed by no project" not in out, f"a role the visible project does not bind was judged:\n{out}"
        # …and once the visible project binds that role, the missing index is named.
        tax = dict(TAXONOMY); tax["roles"] = TAXONOMY["roles"] + [{"id": "db-admin", "paths": ["infra/db/"]}]
        write(os.path.join(fabric, "projects", PROJECT, "taxonomy.json"), json.dumps(tax))
        code, out = run_lint(fabric)
        assert code == 1 and "memory/domains/db-admin" in out and "indexed by no project" in out, out


GE_BODY = "\n# web-dev — წესდება\n\n" + ("ეს არის ქართული თარგმანი, რომელიც სრულად ქართულ დამწერლობაზეა დაწერილი. " * 6) + "\n"


def _digest_of_body(path: str) -> str:
    import hashlib
    import re as _re
    text = open(path, encoding="utf-8").read()
    body = _re.sub(r"\A---\n.*?\n---\n", "", text, count=1, flags=_re.DOTALL)
    return "sha256:" + hashlib.sha256(body.encode("utf-8")).hexdigest()


def _translation(digest: str, klass: str = "charter") -> str:
    return (f'---\nrole: "web-dev"\nclass: {klass}\ndescription: "ქართული წესდება"\ntier: 1\ndistilled_at: "2026-09-17"\n'
            f'translates: identities/roles/web-dev/charter.md\ntranslates_digest: {digest}\n---\n' + GE_BODY)


WORKER = """---
name: locale-worker
description: ენის როლის მხოლოდ ქართულენოვანი მუშაკი (agent-fabric) — იღებს ქართულს, პასუხობს ქართულად
model: opus
tools: TaskStop
---

შენ ხარ ქართული ენის რედაქტორი. პასუხობ მხოლოდ ქართულად.
"""


def case_locale_translation_is_a_charter_with_a_digest() -> None:
    """A locale charter is linted on its own terms (schema, class, source
    and digest) and never as a generic slice beside a worker file that
    carries no fabric frontmatter. Kills: dropping the locale/ exemption
    in lint_slices, or the translation rule itself."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "locale", "ge", "charter.md"), _translation(_digest_of_body(ident(fabric, "charter.md"))))
        write(ident(fabric, "locale", "ge", "worker.md"), WORKER)
        code, out = run_lint(fabric)
        assert code == 0, f"a well-formed translation and worker failed:\n{out}"
        # class must be charter; the source must be this role's charter
        write(ident(fabric, "locale", "ge", "charter.md"), _translation(_digest_of_body(ident(fabric, "charter.md")), klass="brief"))
        code, out = run_lint(fabric)
        assert code == 1 and "is class charter" in out, out


def case_translation_lag_is_reported() -> None:
    """The English charter moves, the translation keeps the old digest:
    named, never silently served as current. Kills: dropping the digest
    comparison."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "locale", "ge", "charter.md"), _translation(_digest_of_body(ident(fabric, "charter.md"))))
        assert run_lint(fabric)[0] == 0
        write(ident(fabric, "charter.md"), CHARTER + "\nA paragraph the translation does not carry yet.\n")
        code, out = run_lint(fabric)
        assert code == 1 and "the translation lags" in out, out


def case_locale_worker_shape_and_hygiene() -> None:
    """The worker file is not a slice, but its shape is asserted (the
    dispatcher's name, a description in the locale with the installer's
    marker, an alias, one inert tool) and hygiene still runs over its body."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(ident(fabric, "locale", "ge", "worker.md"), WORKER)
        assert run_lint(fabric)[0] == 0
        bad = WORKER.replace("name: locale-worker", "name: ka-worker").replace("(agent-fabric)", "").replace("tools: TaskStop\n", "tools: Read, Bash\n")
        write(ident(fabric, "locale", "ge", "worker.md"), bad)
        code, out = run_lint(fabric)
        assert code == 1, out
        for phrase in ("locale-worker", "agent-fabric` marker", "its one tool is TaskStop"):
            assert phrase in out, f"{phrase!r} not reported:\n{out}"
        # An empty tools line is the trap: it inherits every tool.
        write(ident(fabric, "locale", "ge", "worker.md"), WORKER.replace("tools: TaskStop\n", "tools:\n"))
        code, out = run_lint(fabric)
        assert code == 1 and "inherits every tool" in out, out
        # An English description is the leak: its only reader is the bridge, which reasons in the locale.
        write(ident(fabric, "locale", "ge", "worker.md"), WORKER.replace("description: ენის როლის მხოლოდ ქართულენოვანი მუშაკი (agent-fabric) — იღებს ქართულს, პასუხობს ქართულად", "description: The Georgian-only worker (agent-fabric): receives Georgian, answers Georgian"))
        code, out = run_lint(fabric)
        assert code == 1 and "not in the locale" in out, out
        write(ident(fabric, "locale", "ge", "worker.md"), WORKER + "\nRun it against ghp_ABCDEFGHIJKLMNOP.\n")
        code, out = run_lint(fabric)
        assert code == 1 and "credential" in out, f"a credential in the worker body passed:\n{out}"


def case_harness_source_shape() -> None:
    """runtime/claude-code/harness/en.md, when a fabric carries it: class,
    build, captured_at, an existing live check as its source, the
    memory-directory placeholder exactly once. Absent, nothing is said
    (a fixture fabric). Kills: a capture with no build, or with the
    login's real memory path left in."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        assert run_lint(fabric)[0] == 0, "no capture, no finding"
        lc = os.path.join(fabric, "docs", "live-checks", "2026-09-17-x.md"); os.makedirs(os.path.dirname(lc), exist_ok=True); write(lc, "# x\n")
        good = ("---\nclass: harness-source\nbuild: \"2.1.274 (Claude Code)\"\ncaptured_at: 2026-09-17\nsource: docs/live-checks/2026-09-17-x.md\n---\n"
                "You are Claude Code.\n\n# Memory\n\nYou have a persistent file-based memory at `{memory_dir}`.\n")
        write(os.path.join(fabric, "runtime", "claude-code", "harness", "en.md"), good)
        code, out = run_lint(fabric)
        assert code == 0, out
        write(os.path.join(fabric, "runtime", "claude-code", "harness", "en.md"), good.replace("build: \"2.1.274 (Claude Code)\"\n", "").replace("{memory_dir}", "/home/x/.claude/projects/-home-x/memory/"))
        code, out = run_lint(fabric)
        assert code == 1, out
        for phrase in ("no `build`", "{memory_dir} appears 0 time(s)"):
            assert phrase in out, f"{phrase!r} not reported:\n{out}"
        write(os.path.join(fabric, "runtime", "claude-code", "harness", "en.md"), good.replace("2026-09-17-x.md", "2026-09-17-missing.md"))
        code, out = run_lint(fabric)
        assert code == 1 and "not an existing docs/live-checks/ note" in out, out


def case_prompt_templates_carry_their_placeholders() -> None:
    """identities/prompt/header.md names the login ({agent}, {host},
    {role}); a header without {agent} would read the same for every login.
    Kills: checking only {role} on every template."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        p = os.path.join(fabric, "identities", "prompt", "header.md")
        write(p, open(p, encoding="utf-8").read().replace("{agent}", "someone"))
        code, out = run_lint(fabric)
        assert code == 1 and "header.md: no {agent} placeholder" in out, out


def case_locale_file_shape() -> None:
    """locale.json fixes the search tools' country and languages, one block
    per engine; lint asserts the shapes each engine takes and a description
    in the locale. Kills: an unchecked file the server would refuse at start."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        good = ('{"timezone": "Asia/Tbilisi", "serpapi": {"gl": "ge", "hl": "ka", "google_domain": "google.ge", "lr": "lang_ka", "tool_description": "ვებ-ძიება ქართულად"},'
                ' "brave": {"country": "ALL", "tool_description": "გლობალური ვებ-ძიება"}}')
        write(ident(fabric, "locale", "ge", "locale.json"), good)
        code, out = run_lint(fabric)
        assert code == 0, out
        write(ident(fabric, "locale", "ge", "locale.json"), good.replace('"gl": "ge"', '"gl": "GE"').replace('"hl": "ka"', '"hl": "KA-"').replace('"lr": "lang_ka"', '"lr": "ka"').replace("ვებ-ძიება ქართულად", "Web search in Georgian").replace('"ALL"', '"all"'))
        code, out = run_lint(fabric)
        assert code == 1, out
        for phrase in ("serpapi.gl 'GE'", "serpapi.hl 'KA-'", "serpapi.lr 'ka'", "serpapi.tool_description is not in the locale", "brave.country 'all'"):
            assert phrase in out, f"{phrase!r} not reported:\n{out}"
        write(ident(fabric, "locale", "ge", "locale.json"), '{"timezone": "Asia/Tbilisi", "brave": {"country": "US", "search_lang": "en", "ui_lang": "en-US", "tool_description": "ძიება"}}')
        code, out = run_lint(fabric)
        assert code == 0, f"one engine alone, with the languages Brave has: {out}"
        write(ident(fabric, "locale", "ge", "locale.json"), good.replace('"tool_description": "ვებ-ძიება ქართულად"', '"label": "main engine", "tool_description": "ვებ-ძიება ქართულად"'))
        code, out = run_lint(fabric)
        assert code == 1 and "serpapi.label 'main engine'" in out, f"a label not in the locale is refused: {out}"
        write(ident(fabric, "locale", "ge", "locale.json"), '{"timezone": "Asia/Tbilisi"}')
        code, out = run_lint(fabric)
        assert code == 1 and "no engine block" in out, out
        write(ident(fabric, "locale", "ge", "locale.json"), good[:-1] + ', "country": "GE"}')
        code, out = run_lint(fabric)
        assert code == 1 and "unknown field(s) ['country']" in out, out
        write(ident(fabric, "locale", "ge", "locale.json"), "{not json")
        code, out = run_lint(fabric)
        assert code == 1 and "not JSON" in out, out


def case_non_latin_translation_budget_is_stricter() -> None:
    """A Georgian body is budgeted at the measured 1.5 characters a token,
    not four, against three times the tier-1 budget (the measured cost of
    a full rendering): a body that passes the flat estimate is refused,
    and a full rendering's size passes. Kills: using CHARS_PER_TOKEN for a
    non-Latin body; a ceiling no rendering can meet."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        # ~15 000 letters: 3 750 tokens at 4/char (under 9 000), 10 000 at 1.5/char (over)
        big = "\n# წ\n\n" + ("ქართული ტექსტი " * 1000) + "\n"
        text = _translation(_digest_of_body(ident(fabric, "charter.md"))).replace(GE_BODY, big)
        write(ident(fabric, "locale", "ge", "charter.md"), text)
        code, out = run_lint(fabric)
        assert code == 1 and "at 1.5 chars/token" in out and "locale budget 9000" in out, out
        # The first real rendering's size (11 041 characters, ~7 360 at 1.5) passes.
        real = "\n# წ\n\n" + ("ქართული ტექსტი " * 735) + "\n"
        write(ident(fabric, "locale", "ge", "charter.md"), _translation(_digest_of_body(ident(fabric, "charter.md"))).replace(GE_BODY, real))
        code, out = run_lint(fabric)
        assert code == 0, out


def case_quoted_description_round_trips() -> None:
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        inner = 'Uses the two-step "commented out, later" pattern'
        write(dom(fabric, "domain", "good.md"), SLICE.replace(
            'description: "A well-formed slice, shaped like the real ones"', f'description: "{inner}"'))
        write(proj(fabric, "INDEX.md"), index_for(
            f"- [`../agent-fabric/memory/domains/web-dev/domain/good.md`](../agent-fabric/memory/domains/web-dev/domain/good.md) — {inner}\n"))
        code, out = run_lint(fabric)
        assert code == 0, f"an unescaped-quote description was read differently than assemble reads it:\n{out}"


def case_authored_classes_only_in_identities() -> None:
    """A charter-class file under memory/ is a hand-authored claim with no
    evidence smuggled past provenance."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(proj(fabric, "charter.md"), CHARTER)
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`.agent-fabric/memory/web-dev/charter.md`](.agent-fabric/memory/web-dev/charter.md) — The web sub-apps.\n"))
        code, out = run_lint(fabric)
        assert code == 1 and "belongs under identities/roles/" in out, out


def case_brief_is_identity_too() -> None:
    """The brief (how the role works, read to every session at launch) is
    the third authored class: beside the charter it lints clean and the
    index may list it; under memory/ it is refused like a charter."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        brief = CHARTER.replace("class: charter", "class: brief")
        write(ident(fabric, "brief.md"), brief)
        write(proj(fabric, "INDEX.md"), index_for(
            CHARTER_LINE +
            "- [`../agent-fabric/identities/roles/web-dev/brief.md`](../agent-fabric/identities/roles/web-dev/brief.md) — The web sub-apps.\n"))
        code, out = run_lint(fabric)
        assert code == 0, f"a brief beside its charter was refused:\n{out}"
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(proj(fabric, "brief.md"), CHARTER.replace("class: charter", "class: brief"))
        write(proj(fabric, "INDEX.md"), index_for(
            "- [`.agent-fabric/memory/web-dev/brief.md`](.agent-fabric/memory/web-dev/brief.md) — The web sub-apps.\n"))
        code, out = run_lint(fabric)
        assert code == 1 and "belongs under identities/roles/" in out, out


def case_prompt_templates_are_linted() -> None:
    """The launch-prompt sections are not slices, so they are checked by
    name: present, carrying {role}, hygiene-clean, within one budget."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        os.remove(os.path.join(fabric, "identities", "prompt", "team.md"))
        code, out = run_lint(fabric)
        assert code == 1 and "identities/prompt/team.md: missing" in out, out
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(os.path.join(fabric, "identities", "prompt", "memory.md"), "# Memory\n\nGeneric text, no placeholder.\n")
        code, out = run_lint(fabric)
        assert code == 1 and "no {role} placeholder" in out, out
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        write(os.path.join(fabric, "identities", "prompt", "memory.md"), "{role} " + "padding words " * 2000)
        code, out = run_lint(fabric)
        assert code == 1 and "exceeds the" in out and "budget every session pays" in out, out


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
        doc["agents"]["web-dev-01"]["capabilities"] = {"code-review": "z-ai/glm-5.3-flash"}
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


def case_the_class_list_a_reader_sees_is_the_real_one() -> None:
    """README.md and CLAUDE.md spell out the capability classes; each list
    must be exactly what routing/capabilities.json defines. The README
    said `review` for a class named code-review for days (2026-09-16)."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        classes = sorted(json.load(open(os.path.join(fabric, "routing", "capabilities.json")))["classes"])
        row = "| **CAPABILITY** | x | `routing/capabilities.json` classes: " + ", ".join(f"`{c}`" for c in classes) + " |\n"
        write(os.path.join(fabric, "README.md"), "# r\n\n" + row)
        code, out = run_lint(fabric)
        assert code == 0, f"the real list was refused:\n{out}"
        write(os.path.join(fabric, "README.md"), "# r\n\n" + row.replace("`code-review`", "`review`"))
        code, out = run_lint(fabric)
        assert code == 1 and "README.md: names capability class 'review'" in out \
            and "does not name capability class 'code-review'" in out, f"a wrong class name passed:\n{out}"
        write(os.path.join(fabric, "README.md"), "# r\n\nno classes here\n")
        code, out = run_lint(fabric)
        assert code == 1 and "class list was not found" in out, f"a README without the list passed:\n{out}"
        # CLAUDE.md's sentence is checked the same way
        write(os.path.join(fabric, "README.md"), "# r\n\n" + row)
        write(os.path.join(fabric, "CLAUDE.md"), "- **Subagents** name a capability class in `subagent_type` — the five\n  are `code-low`, `code-medium` — and the alias.\n")
        code, out = run_lint(fabric)
        assert code == 1 and "CLAUDE.md: does not name capability class 'code-high'" in out, f"CLAUDE.md drift passed:\n{out}"


def case_the_host_registry_is_one_host_per_id_and_placements_are_known() -> None:
    def registry(hosts, placement):
        return json.dumps({"version": 1, "hosts": hosts, "placement": placement})
    H = {"platform": "debian", "ssh": "op@h2.example", "operator": "op", "fabric": "~/projects/agent-fabric"}
    L = {"platform": "fedora-qubes", "ssh": None, "operator": "user", "fabric": "~/projects/agent-fabric"}
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        shutil.copytree(os.path.join(ROOT, "runtime", "hosts", "schema"), os.path.join(fabric, "runtime", "hosts", "schema"))
        reg = os.path.join(fabric, "runtime", "hosts", "registry.json")
        write(reg, registry({"local": L, "h2": H}, {"a": "local", "b": "h2"}))
        code, out = run_lint(fabric)
        assert code == 0, f"a sound registry was refused:\n{out}"
        write(reg, registry({"local": L, "h2": H, "h3": H}, {"a": "local"}))
        code, out = run_lint(fabric)
        assert code == 1 and "share the ssh destination" in out, f"two hosts on one destination passed:\n{out}"
        write(reg, registry({"h2": H}, {"a": "h2"}))
        code, out = run_lint(fabric)
        assert code == 1 and "exactly one host has ssh null" in out, f"no local host passed:\n{out}"
        write(reg, registry({"local": L}, {"a": "elsewhere"}))
        code, out = run_lint(fabric)
        assert code == 1 and "names host 'elsewhere', which is not registered" in out, f"an unknown placement passed:\n{out}"
        write(reg, registry({"Bad_Host": L}, {}))
        code, out = run_lint(fabric)
        assert code == 1 and "Bad_Host" in out, f"an id that is not a short hostname passed:\n{out}"
        write(reg, registry({"local": {**L, "role": "fabric-coordinator"}}, {}))
        code, out = run_lint(fabric)
        assert code == 1 and "role" in out, f"a role in a host entry passed (placement is never identity):\n{out}"


def case_a_managed_projects_name_stays_out_of_generic_files() -> None:
    """A project id from the registry in a role skill, the provisioning,
    a tool or the GZCoord runtime is a finding; the fabric's own remote,
    tests, READMEs and history are not."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        _write_license_layout(fabric, {"projects": {
            "agent-fabric": {"license": "Apache-2.0", "remotes": ["git@github.com:gzapi-org/agent-fabric.git"]},
            "acme.shop": {"license": "Apache-2.0", "remotes": ["git@github.com:acme/acme.shop.git"]}}}, REUSE_OK)
        code, out = run_lint(fabric)
        assert code == 0, f"the base was refused:\n{out}"
        write(ident(fabric, "skills", "probe", "SKILL.md"), SKILL + "\nRead ACME_SHOP_PORT_OFFSET first.\n")
        code, out = run_lint(fabric)
        assert code == 1 and "identities/roles/web-dev/skills/probe/SKILL.md" in out and "'ACME_SHOP_'" in out, f"a project's variable in a skill passed:\n{out}"
        write(ident(fabric, "skills", "probe", "SKILL.md"), SKILL + "\nThe acme.shop checkout is under ~/projects.\n")
        code, out = run_lint(fabric)
        assert code == 1 and "'acme.shop'" in out, f"a project's id in a skill passed:\n{out}"
        write(ident(fabric, "skills", "probe", "SKILL.md"), SKILL + "\nClone gzapi-org/agent-fabric first; see the README.\n")
        code, out = run_lint(fabric)
        assert code == 0, f"the fabric's own remote was taken for a project:\n{out}"
        os.makedirs(os.path.join(fabric, "runtime", "provisioning"), exist_ok=True)
        write(os.path.join(fabric, "runtime", "provisioning", "test_x.sh"), "# acme.shop in a test is fine\n")
        write(os.path.join(fabric, "runtime", "provisioning", "README.md"), "# acme.shop in a README is fine\n")
        code, out = run_lint(fabric)
        assert code == 0, f"a test or README was linted as generic code:\n{out}"
        write(os.path.join(fabric, "runtime", "provisioning", "x.sh"), "echo acme.shop\n")
        code, out = run_lint(fabric)
        assert code == 1 and "runtime/provisioning/x.sh:1" in out, f"provisioning naming a project passed:\n{out}"


def case_review_lenses_are_named_described_and_bounded() -> None:
    """The lens directory is the vocabulary: each file names itself, has a
    one-line description, a body under the cap; general.md must exist."""
    with tempfile.TemporaryDirectory() as root:
        fabric = make_base(root)
        lenses = os.path.join(fabric, "runtime", "claude-code", "review", "lenses")
        write(os.path.join(lenses, "general.md"), "---\nname: general\ndescription: The ordinary review.\n---\nLook at everything.\n")
        write(os.path.join(lenses, "security.md"), "---\nname: security\ndescription: Trust boundaries.\n---\nWhere does input enter?\n")
        code, out = run_lint(fabric)
        assert code == 0, f"sound lenses were refused:\n{out}"
        write(os.path.join(lenses, "security.md"), "---\nname: secure\ndescription: Trust boundaries.\n---\nWhere does input enter?\n")
        code, out = run_lint(fabric)
        assert code == 1 and "security.md: name 'secure' must equal the filename" in out, f"a misnamed lens passed:\n{out}"
        write(os.path.join(lenses, "security.md"), "---\nname: security\ndescription: Trust boundaries.\n---\n" + ("x" * 1600) + "\n")
        code, out = run_lint(fabric)
        assert code == 1 and "the cap is 1500" in out, f"an oversized lens passed:\n{out}"
        write(os.path.join(lenses, "security.md"), "Where does input enter?\n")
        code, out = run_lint(fabric)
        assert code == 1 and "no frontmatter" in out, f"a lens without frontmatter passed:\n{out}"
        os.remove(os.path.join(lenses, "security.md")); os.remove(os.path.join(lenses, "general.md"))
        write(os.path.join(lenses, "cleanup.md"), "---\nname: cleanup\ndescription: Dead code.\n---\nWhat is unreachable now?\n")
        code, out = run_lint(fabric)
        assert code == 1 and "no general.md" in out, f"a lens directory without general passed:\n{out}"


def main() -> int:
    cases = [
        case_clean_base_passes,
        case_index_description_drift_is_caught,
        case_a_sibling_working_copy_is_linted_unasked,
        case_index_lists_domain_slices,
        case_quoted_description_round_trips,
        case_payload_is_exempt,
        case_hygiene_still_runs_over_payload,
        case_secrets_are_refused_by_shape,
        case_a_persons_name_is_refused_everywhere,
        case_slices_are_still_linted,
        case_exemption_is_anchored_at_the_role_root,
        case_payload_shape_is_asserted,
        case_index_need_not_list_payload,
        case_authored_classes_only_in_identities,
        case_brief_is_identity_too,
        case_prompt_templates_are_linted,
        case_knowledge_not_in_identities,
        case_taxonomy_roles_are_catalogued,
        case_domain_bound_by_an_unseen_project_is_not_judged,
        case_locale_translation_is_a_charter_with_a_digest,
        case_translation_lag_is_reported,
        case_locale_worker_shape_and_hygiene,
        case_harness_source_shape,
        case_prompt_templates_carry_their_placeholders,
        case_locale_file_shape,
        case_non_latin_translation_budget_is_stricter,
        case_model_profiles_layered_file_passes,
        case_model_profiles_cheap_review_is_refused,
        case_model_profiles_agents_are_logins,
        case_model_profiles_unknown_role_is_refused,
        case_model_profiles_schema_is_enforced,
        case_the_repository_is_one_license,
        case_the_class_list_a_reader_sees_is_the_real_one,
        case_the_host_registry_is_one_host_per_id_and_placements_are_known,
        case_a_managed_projects_name_stays_out_of_generic_files,
        case_review_lenses_are_named_described_and_bounded,
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
