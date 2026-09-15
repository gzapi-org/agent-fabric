#!/usr/bin/env python3
"""tests/test_launch_prompt.py — the launch prompt is built from the
binding, byte-stable, and never names the project.

Runs tools/fabric/launch_prompt.py against a throwaway agent-fabric root
and a throwaway state directory, as tests/test_role.py does: the real
modules copied in, a fixture charter and brief, the real prompt sections.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
LOGIN = os.environ.get("USER") or "user"


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


class Fixture:
    def __init__(self, tmp: str, role: str = "backend-dev", brief: bool = True):
        self.root = os.path.join(tmp, "fabric")
        self.state = os.path.join(tmp, "state")
        for rel in ("tools/fabric/layout.py", "tools/fabric/workingcopy.py",
                    "tools/fabric/launch_prompt.py", "runtime/identity.py"):
            os.makedirs(os.path.dirname(os.path.join(self.root, rel)), exist_ok=True)
            shutil.copy2(os.path.join(ROOT, rel), os.path.join(self.root, rel))
        shutil.copytree(os.path.join(ROOT, "identities", "prompt"),
                        os.path.join(self.root, "identities", "prompt"))
        write(os.path.join(self.root, "identities", "roles", role, "charter.md"),
              f"---\nrole: {role}\nclass: charter\ndescription: \"x\"\ntier: 1\ndistilled_at: 2026-09-15\n---\n\n"
              f"# {role} — charter\n\nCHARTER-BODY-LINE for {role}.\n")
        if brief:
            write(os.path.join(self.root, "identities", "roles", role, "brief.md"),
                  f"---\nrole: {role}\nclass: brief\ndescription: \"y\"\ntier: 1\ndistilled_at: 2026-09-15\n---\n\n"
                  f"# {role} — brief\n\nBRIEF-BODY-LINE for {role}.\n")
        self.bind(role)
        self.env = {**os.environ, "AGENT_FABRIC_ROOT": self.root, "AGENT_FABRIC_STATE_DIR": self.state}

    def bind(self, role: str | None) -> None:
        # The binding a fabric-role bind would have written: keyed by the
        # login (identity.read_binding refuses another agent's record).
        d = os.path.join(self.state, "agents", LOGIN)
        os.makedirs(d, exist_ok=True)
        rec = {"agent": LOGIN, "host": "h", "updated_at": "2026-09-15T00:00:00Z"}
        if role:
            rec["role"] = role
        write(os.path.join(d, "binding.json"), json.dumps(rec))

    def run(self, *argv: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, os.path.join(self.root, "tools", "fabric", "launch_prompt.py"), *argv],
                              env=self.env, capture_output=True, text=True)


def case_header_names_agent_host_role() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        r = f.run("--print")
        assert r.returncode == 0, r.stderr
        assert f"agent `{LOGIN}`" in r.stdout and "**backend-dev**" in r.stdout, r.stdout
        assert "bin/fabric-whoami" in r.stdout and "relaunch" in r.stdout


def case_charter_and_brief_bodies_without_frontmatter() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        out = f.run("--print").stdout
        assert "CHARTER-BODY-LINE for backend-dev" in out and "BRIEF-BODY-LINE for backend-dev" in out
        assert "class: charter" not in out and "distilled_at" not in out, "frontmatter leaked into the prompt"
        assert out.index("— charter") < out.index("— brief") < out.index("Working with the team") \
            < out.index("Your long-term memory"), "sections out of order"


def case_shared_sections_are_rendered_for_the_role() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        out = f.run("--print").stdout
        assert "{role}" not in out, "an unsubstituted placeholder reached the prompt"
        assert "memory/domains/backend-dev/" in out and ".agent-fabric/roles/backend-dev.md" in out
        assert "REPLY-EXPECTED: yes" in out and "roles_class" in out


def case_missing_brief_is_a_placeholder_not_a_failure() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp, brief=False)
        r = f.run("--print")
        assert r.returncode == 0, r.stderr
        assert "No brief has been distilled" in r.stdout and "backend-dev — brief" in r.stdout


def case_missing_charter_is_a_failure() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        os.remove(os.path.join(f.root, "identities", "roles", "backend-dev", "charter.md"))
        r = f.run("--print")
        assert r.returncode == 1 and "no charter" in r.stderr, r.stderr


def case_no_binding_is_a_failure_naming_fabric_role() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        f.bind(None)
        r = f.run("--print")
        assert r.returncode == 1 and "bin/fabric-role bind" in r.stderr, r.stderr


def case_out_writes_the_file_and_prints_its_digest() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        out = os.path.join(tmp, "state", "agents", LOGIN, "launch-prompt.md")
        r = f.run("--out", out)
        assert r.returncode == 0, r.stderr
        printed = r.stdout.strip()
        assert printed.startswith("sha256:"), r.stdout
        with open(out, "rb") as fh:
            assert printed == "sha256:" + hashlib.sha256(fh.read()).hexdigest(), "digest is not of the file's bytes"
        assert not [n for n in os.listdir(os.path.dirname(out)) if n.startswith(".launch-prompt-")], \
            "a temporary file was left beside the prompt"


def case_byte_stable_across_builds_and_cwds() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        a = f.run("--print").stdout
        elsewhere = os.path.join(tmp, "elsewhere")
        os.makedirs(elsewhere)
        b = subprocess.run([sys.executable, os.path.join(f.root, "tools", "fabric", "launch_prompt.py"), "--print"],
                           env=f.env, capture_output=True, text=True, cwd=elsewhere).stdout
        assert a == b, "the prompt depends on something other than (agent, host, role)"
        assert tmp not in a, "a fixture path (a cwd or working copy) reached the prompt"


def case_nothing_about_who_can_be_passed_in() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        r = f.run("--print", "--role", "db-admin")
        assert r.returncode == 2, "an identity argument was accepted"


def case_oversized_prompt_is_refused() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp)
        write(os.path.join(f.root, "identities", "roles", "backend-dev", "brief.md"),
              "---\nrole: backend-dev\nclass: brief\n---\n\n# backend-dev — brief\n\n" + ("padding line\n" * 2000))
        r = f.run("--print")
        assert r.returncode == 1 and "exceeds" in r.stderr, r.stderr


def main() -> int:
    cases = [
        case_header_names_agent_host_role,
        case_charter_and_brief_bodies_without_frontmatter,
        case_shared_sections_are_rendered_for_the_role,
        case_missing_brief_is_a_placeholder_not_a_failure,
        case_missing_charter_is_a_failure,
        case_no_binding_is_a_failure_naming_fabric_role,
        case_out_writes_the_file_and_prints_its_digest,
        case_byte_stable_across_builds_and_cwds,
        case_nothing_about_who_can_be_passed_in,
        case_oversized_prompt_is_refused,
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
