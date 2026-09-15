#!/usr/bin/env python3
"""Behavioural tests for runtime/claude-code/hooks/session-start.py and
runtime/claude-code/bootstrap.sh: a session started from the parent
projects/ directory learns the agent from the OS, records the working
copy and project it is in, and never touches the role.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HOOK = os.path.join(ROOT, "runtime", "claude-code", "hooks", "session-start.sh")
BOOTSTRAP = os.path.join(ROOT, "runtime", "claude-code", "bootstrap.sh")


def id_un() -> str:
    return subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()


def git_repo(path: str, remote: str) -> None:
    os.makedirs(path, exist_ok=True)
    subprocess.run(["git", "init", "-q", "."], cwd=path, check=True)
    subprocess.run(["git", "remote", "add", "origin", remote], cwd=path, check=True)


def run_hook(payload: dict, env: dict) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", HOOK], input=json.dumps(payload), capture_output=True, text=True, env=env)


def test_hook_records_context_not_identity(tmp: str) -> None:
    state = os.path.join(tmp, "state")
    wc = os.path.join(tmp, "legacy-clone-2")
    git_repo(wc, "git@github.com:gzapi-org/gzapp.git")
    env = {**os.environ, "AGENT_FABRIC_ROOT": ROOT, "AGENT_FABRIC_STATE_DIR": state,
           "USER": "architect01", "LOGNAME": "architect01"}
    # A pre-existing binding with a role: the hook must keep it.
    os.makedirs(os.path.join(state, "agents", id_un()))
    with open(os.path.join(state, "agents", id_un(), "binding.json"), "w", encoding="utf-8") as fh:
        json.dump({"agent": id_un(), "host": "h", "role": "architect-cto", "updated_at": "x"}, fh)
    proc = run_hook({"cwd": wc, "session_id": "sess-123"}, env)
    assert proc.returncode == 0, proc.stderr
    assert f"agent={id_un()}" in proc.stdout, proc.stdout
    assert "project=gzapp" in proc.stdout and "role=architect-cto" in proc.stdout, proc.stdout
    b = json.load(open(os.path.join(state, "agents", id_un(), "binding.json"), encoding="utf-8"))
    assert b["agent"] == id_un() and b["role"] == "architect-cto"
    assert b["project"] == "gzapp" and b["working_copy"] == wc and b["session"] == "sess-123", b


def test_hook_from_the_parent_directory_has_no_project(tmp: str) -> None:
    state = os.path.join(tmp, "state")
    parent = os.path.join(tmp, "projects")
    os.makedirs(parent)
    env = {**os.environ, "AGENT_FABRIC_ROOT": ROOT, "AGENT_FABRIC_STATE_DIR": state}
    proc = run_hook({"cwd": parent}, env)
    assert proc.returncode == 0, proc.stderr
    assert f"agent={id_un()}" in proc.stdout and "project=(none)" in proc.stdout, proc.stdout
    assert "role=(none" in proc.stdout, proc.stdout


def test_hook_never_blocks(tmp: str) -> None:
    env = {**os.environ, "AGENT_FABRIC_ROOT": os.path.join(tmp, "nowhere"),
           "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state")}
    proc = run_hook({"cwd": "/"}, env)
    assert proc.returncode == 0, "a broken control plane must not block a session start"
    proc = subprocess.run(["bash", HOOK], input="not json", capture_output=True, text=True,
                          env={**os.environ, "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state2")})
    assert proc.returncode == 0


def test_hook_exports_the_control_plane_into_the_session_shell(tmp: str) -> None:
    """A SessionStart hook may append `export` lines to $CLAUDE_ENV_FILE;
    the harness sources them into every later Bash call. AGENT_FABRIC_ROOT
    must be one of them — the integration docs run inbox.mjs through it,
    and until 2026-09-14 it was set only for the hook's own child."""
    env_file = os.path.join(tmp, "claude-env")
    env = {**os.environ, "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state"), "CLAUDE_ENV_FILE": env_file}
    env.pop("AGENT_FABRIC_ROOT", None)
    proc = run_hook({"cwd": "/"}, env)
    assert proc.returncode == 0, proc.stderr
    exported = subprocess.run(["bash", "-c", f'source "{env_file}" && printf %s "$AGENT_FABRIC_ROOT"'],
                              capture_output=True, text=True).stdout
    assert exported == ROOT, exported
    # Resume and compaction run the hook again: the line is written once.
    run_hook({"cwd": "/"}, env)
    assert open(env_file, encoding="utf-8").read().count("export AGENT_FABRIC_ROOT=") == 1
    # Without the file nothing is written anywhere and the hook still runs.
    env.pop("CLAUDE_ENV_FILE")
    assert run_hook({"cwd": "/"}, env).returncode == 0


def test_bootstrap_writes_only_the_workspace_and_home_files(tmp: str) -> None:
    projects = os.path.join(tmp, "projects")
    home = os.path.join(tmp, "home")
    os.makedirs(projects); os.makedirs(home)
    env = {**os.environ, "HOME": home, "AGENT_FABRIC_STATE_DIR": os.path.join(tmp, "state")}
    env.pop("CLAUDE_CONFIG_DIR", None)
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects], capture_output=True, text=True, env=env)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    claude_md = open(os.path.join(projects, "CLAUDE.md"), encoding="utf-8").read()
    assert "@agent-fabric/CLAUDE.md" in claude_md and len(claude_md.splitlines()) <= 8, claude_md
    settings = json.load(open(os.path.join(projects, ".claude", "settings.json"), encoding="utf-8"))
    hooks = json.dumps(settings["hooks"])
    assert "session-start.sh" in hooks and "agent-dispatch-guard.sh" in hooks and ROOT in hooks
    assert "communication/gzcoord/scripts/inbox.mjs" in hooks, "the workspace drains the GZCoord inbox too"
    assert "statusline.sh" in settings["statusLine"]["command"]
    assert settings["env"]["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] == "1", "the hook must be the only tab-title writer"
    assert not os.path.exists(os.path.join(home, ".claude", "commands", "role.md")), "/role is retired; nothing installs it"
    with open(os.path.join(home, ".claude", "agents", "code-review.md"), encoding="utf-8") as fh:
        assert "\nmodel: claude-opus-5[1m]\n" in fh.read(), "the reviewer file carries the anthropic column's pin"
    with open(os.path.join(home, ".claude", "agents", "code-high.md"), encoding="utf-8") as fh:
        assert "\nmodel: opus\n" in fh.read(), "an unpinned class keeps its alias"
    for skill in ("subagent-dispatch", "gzcoord-send", "gzcoord-receive"):
        assert os.path.isfile(os.path.join(home, ".claude", "skills", skill, "SKILL.md")), skill
    for f in ("code-low.md", "code-medium.md", "code-high.md"):
        assert os.path.isfile(os.path.join(home, ".claude", "agents", f))
    assert not os.path.exists(os.path.join(projects, ".git")), "projects/ must not become a repository"
    # Idempotent: a second run changes nothing.
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects], capture_output=True, text=True, env=env)
    assert "0 written" in proc.stdout, proc.stdout
    # An account that still carries the retired /role command from an
    # earlier bootstrap: our copy is removed (dry-run says so first), a
    # human's own commands/role.md and a .before-agent-fabric backup stay.
    retired = os.path.join(home, ".claude", "commands", "role.md")
    os.makedirs(os.path.dirname(retired), exist_ok=True)
    with open(retired, "w", encoding="utf-8") as fh:
        fh.write("---\ndescription: x\n---\n!`python3 /old/agent-fabric/tools/fabric/role.py $ARGUMENTS`\n")
    with open(retired + ".before-agent-fabric", "w", encoding="utf-8") as fh:
        fh.write("the human's own\n")
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects, "--dry-run"], capture_output=True, text=True, env=env)
    assert "would remove" in proc.stdout and os.path.isfile(retired), proc.stdout
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects], capture_output=True, text=True, env=env)
    assert not os.path.exists(retired) and "removed: /role is retired" in proc.stdout, proc.stdout
    assert os.path.isfile(retired + ".before-agent-fabric"), "the human's backup was touched"
    with open(retired, "w", encoding="utf-8") as fh:
        fh.write("---\ndescription: my own role command\n---\nnothing to do with the fabric\n")
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects], capture_output=True, text=True, env=env)
    assert os.path.isfile(retired), "a command the human wrote was removed"
    os.remove(retired); os.remove(retired + ".before-agent-fabric")
    # An existing settings file keeps its own entries.
    with open(os.path.join(projects, ".claude", "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"permissions": {"allow": ["Bash(ls:*)"]}, "env": {"MY_OWN": "x"}, "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}}, fh)
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects], capture_output=True, text=True, env=env)
    settings = json.load(open(os.path.join(projects, ".claude", "settings.json"), encoding="utf-8"))
    assert settings["env"] == {"MY_OWN": "x", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"}, settings["env"]
    assert settings["permissions"] == {"allow": ["Bash(ls:*)"]}
    assert any("echo mine" in json.dumps(g) for g in settings["hooks"]["SessionStart"])
    assert any("session-start.sh" in json.dumps(g) for g in settings["hooks"]["SessionStart"])
    # Entries from an EARLIER bootstrap out of another checkout are replaced,
    # not kept beside the new ones: an account that moved from a shared path
    # to its own clone must end up with one set of hooks.
    with open(os.path.join(projects, ".claude", "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"hooks": {"SessionStart": [{"hooks": [{"type": "command",
                   "command": "bash \"/somewhere/else/agent-fabric/runtime/claude-code/hooks/session-start.sh\""}]}]}}, fh)
    proc = subprocess.run(["bash", BOOTSTRAP, "--projects", projects], capture_output=True, text=True, env=env)
    settings = json.load(open(os.path.join(projects, ".claude", "settings.json"), encoding="utf-8"))
    starts = [json.dumps(g) for g in settings["hooks"]["SessionStart"]]
    assert not any("/somewhere/else" in g for g in starts), starts
    assert sum("session-start.sh" in g for g in starts) == 1, starts


def main() -> int:
    cases = [test_hook_records_context_not_identity, test_hook_from_the_parent_directory_has_no_project,
             test_hook_never_blocks, test_hook_exports_the_control_plane_into_the_session_shell,
             test_bootstrap_writes_only_the_workspace_and_home_files]
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
