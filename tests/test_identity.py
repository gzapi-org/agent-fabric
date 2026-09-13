#!/usr/bin/env python3
"""Behavioural tests for runtime/identity.py and tools/fabric/workingcopy.py.

The invariant under test: the agent name is the Linux login of the
effective user and nothing else. Changing directory, renaming a working
copy, being inside or outside a repository, or setting environment
variables must leave it untouched — and must still resolve the CONTEXT
(working copy, project) correctly and separately.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IDENTITY = os.path.join(ROOT, "runtime", "identity.py")
WHOAMI = os.path.join(ROOT, "bin", "fabric-whoami")

sys.path.insert(0, os.path.join(ROOT, "runtime"))
sys.path.insert(0, os.path.join(ROOT, "tools", "fabric"))
import identity  # noqa: E402
import workingcopy  # noqa: E402


def sh(*argv: str, cwd: str | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(list(argv), cwd=cwd, env=env, capture_output=True, text=True)


def id_un() -> str:
    return sh("id", "-un").stdout.strip()


def git_repo(path: str, remote: str) -> None:
    os.makedirs(path, exist_ok=True)
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    for cmd in (["init", "-q", "."], ["remote", "add", "origin", remote]):
        assert sh("git", "-c", "commit.gpgsign=false", *cmd, cwd=path, env=env).returncode == 0


def fabric_fixture(tmp: str) -> str:
    """A fake agent-fabric root with one registered project."""
    root = os.path.join(tmp, "fabric")
    os.makedirs(os.path.join(root, "projects"))
    os.makedirs(os.path.join(root, "tools", "fabric"))
    with open(os.path.join(root, "projects", "registry.json"), "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "projects": {"demo": {
            "remotes": ["git@example.com:org/demo.git"], "memory": "memory/projects/demo"}}}, fh)
    os.symlink(os.path.join(ROOT, "tools", "fabric", "workingcopy.py"),
               os.path.join(root, "tools", "fabric", "workingcopy.py"))
    return root


def test_agent_is_the_effective_login() -> None:
    assert identity.current_agent() == id_un()
    assert sh(sys.executable, IDENTITY).stdout.strip() == id_un()
    assert sh("bash", WHOAMI).stdout.strip() == id_un()


def test_agent_is_computed_from_the_uid_not_from_names() -> None:
    fake = lambda uid: type("pw", (), {"pw_name": f"login-{uid}"})()  # noqa: E731
    assert identity.current_agent(getpwuid=fake, geteuid=lambda: 4242) == "login-4242"


def test_agent_ignores_cwd_and_environment(tmp: str) -> None:
    """From the parent directory, inside a repo, inside a renamed copy of
    that repo, and outside any repo: always the same agent."""
    root = fabric_fixture(tmp)
    repo = os.path.join(tmp, "demo-clone-a")
    git_repo(repo, "git@example.com:org/demo.git")
    renamed = os.path.join(tmp, "some-other-name")
    os.rename(repo, renamed)
    env = {**os.environ, "AGENT_FABRIC_ROOT": root, "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state"),
           "USER": "not-the-agent", "LOGNAME": "not-the-agent", "AGENT_FABRIC_AGENT": "nope",
           "CLAUDE_PROJECT_DIR": renamed}
    seen = set()
    for cwd in (tmp, renamed, os.path.join(renamed, "sub") if os.path.isdir(os.path.join(renamed, "sub")) else renamed, "/"):
        out = sh(sys.executable, IDENTITY, "--json", cwd=cwd, env=env)
        assert out.returncode == 0, out.stderr
        seen.add(json.loads(out.stdout)["agent"])
    assert seen == {id_un()}, seen


def test_context_changes_while_agent_does_not(tmp: str) -> None:
    root = fabric_fixture(tmp)
    repo = os.path.join(tmp, "whatever-name")
    git_repo(repo, "https://example.com/org/demo")
    env = {**os.environ, "AGENT_FABRIC_ROOT": root, "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state")}
    inside = json.loads(sh(sys.executable, IDENTITY, "--json", "--cwd", repo, env=env).stdout)
    outside = json.loads(sh(sys.executable, IDENTITY, "--json", "--cwd", tmp, env=env).stdout)
    assert inside["agent"] == outside["agent"] == id_un()
    assert inside["project"] == "demo" and inside["project_source"] == "working-copy"
    assert inside["working_copy"] == os.path.realpath(repo) or inside["working_copy"] == repo
    assert inside["working_copy_id"] == "whatever-name", "the basename is a label, reported as such"
    assert outside["project"] is None and outside["working_copy"] is None


def test_renaming_the_working_copy_keeps_project_and_agent(tmp: str) -> None:
    root = fabric_fixture(tmp)
    repo = os.path.join(tmp, "demo-one")
    git_repo(repo, "git@example.com:org/demo.git")
    env = {**os.environ, "AGENT_FABRIC_ROOT": root, "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state")}
    before = json.loads(sh(sys.executable, IDENTITY, "--json", "--cwd", repo, env=env).stdout)
    moved = os.path.join(tmp, "demo-main")
    os.rename(repo, moved)
    after = json.loads(sh(sys.executable, IDENTITY, "--json", "--cwd", moved, env=env).stdout)
    assert before["agent"] == after["agent"] == id_un()
    assert before["project"] == after["project"] == "demo"
    assert before["working_copy_id"] == "demo-one" and after["working_copy_id"] == "demo-main"


def test_project_is_matched_by_remote_not_by_directory_name(tmp: str) -> None:
    root = fabric_fixture(tmp)
    registry = workingcopy.load_registry(os.path.join(root, "projects", "registry.json"))
    for url in ("git@example.com:org/demo.git", "https://example.com/org/demo/",
                "ssh://git@example.com/org/demo.git", "EXAMPLE.com/Org/Demo"):
        assert workingcopy.project_for_remote(url, registry) == "demo", url
    assert workingcopy.project_for_remote("git@example.com:org/other.git", registry) is None
    lookalike = os.path.join(tmp, "demo")          # named like the project, but not it
    git_repo(lookalike, "git@example.com:org/other.git")
    assert workingcopy.resolve(lookalike, registry)["project"] is None, \
        "a directory named like a project must not be taken for it"


def test_marker_file_declares_the_project(tmp: str) -> None:
    root = fabric_fixture(tmp)
    registry = workingcopy.load_registry(os.path.join(root, "projects", "registry.json"))
    repo = os.path.join(tmp, "no-remote")
    git_repo(repo, "git@example.com:org/unregistered.git")
    with open(os.path.join(repo, workingcopy.MARKER), "w", encoding="utf-8") as fh:
        fh.write("demo\n")
    got = workingcopy.resolve(repo, registry)
    assert got["project"] == "demo" and got["project_source"] == "marker", got


def test_binding_round_trip_is_stamped_by_the_os(tmp: str) -> None:
    os.environ["AGENT_FABRIC_STATE_DIR"] = os.path.join(tmp, "state")
    try:
        path = identity.write_binding({"role": "architect-cto", "agent": "forged", "host": "forged"})
        assert path.startswith(os.path.join(tmp, "state", "agents", id_un()))
        got = identity.read_binding()
        assert got["agent"] == id_un(), "the caller's `agent` must be overwritten"
        assert got["host"] == identity.current_host()
        assert got["role"] == "architect-cto"
        # A binding copied under another agent's directory is refused.
        other = os.path.join(tmp, "state", "agents", "someone-else")
        os.makedirs(other)
        with open(os.path.join(other, "binding.json"), "w", encoding="utf-8") as fh:
            json.dump({"agent": id_un(), "host": "h", "updated_at": "x"}, fh)
        try:
            identity.read_binding("someone-else")
        except SystemExit as exc:
            assert "names agent" in str(exc)
        else:
            raise AssertionError("a binding under the wrong agent directory was accepted")
    finally:
        del os.environ["AGENT_FABRIC_STATE_DIR"]


def main() -> int:
    cases = [
        test_agent_is_the_effective_login,
        test_agent_is_computed_from_the_uid_not_from_names,
        test_agent_ignores_cwd_and_environment,
        test_context_changes_while_agent_does_not,
        test_renaming_the_working_copy_keeps_project_and_agent,
        test_project_is_matched_by_remote_not_by_directory_name,
        test_marker_file_declares_the_project,
        test_binding_round_trip_is_stamped_by_the_os,
    ]
    failures = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
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
