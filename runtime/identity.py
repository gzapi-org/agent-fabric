#!/usr/bin/env python3
"""runtime/identity.py — the one place agent identity is resolved.

    AGENT IDENTITY = the Linux login of the effective user   (`id -un`)

The agent's name comes from the operating-system account Claude Code (or
any other harness) is running under. Nothing else participates: not the
current directory, not the repository or clone name, not the branch, not
the project, not a session id, and not an environment variable. Those are
CONTEXT — attributes bound to the agent at runtime — and this module
resolves them separately so they can never be mistaken for the name.

    identity.py             the agent name
    identity.py --json      the full runtime context (agent + bindings)
    identity.py --cwd DIR   the context as seen from DIR

Runtime state (which role the agent holds, which project and working copy
it is on) lives OUTSIDE the repository, per agent:

    $AGENT_FABRIC_STATE_DIR/agents/<login>/binding.json
    default: ${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/

Every other tool in agent-fabric — the role activator, the launchers, the
harvesters, the GZCoord runtime, the Claude Code hooks — defers to this
module (or to `bin/fabric-whoami`, which execs it). None of them derives
the agent name on its own.
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import pwd
import socket
import sys
import tempfile

# The repository this module lives in. AGENT_FABRIC_ROOT lets a test point
# at a fixture tree; it never influences the agent NAME.
FABRIC_ROOT = os.environ.get("AGENT_FABRIC_ROOT") or os.path.dirname(
    os.path.dirname(os.path.realpath(__file__)))


def current_agent(getpwuid=pwd.getpwuid, geteuid=os.geteuid) -> str:
    """The agent's canonical name: the login of the effective user.

    Equivalent to `id -un`. The two parameters exist so a test can pass a
    fake passwd lookup; there is deliberately no environment override.
    """
    return getpwuid(geteuid()).pw_name


def current_host() -> str:
    """Short hostname. Recorded beside the agent, never part of its name."""
    return socket.gethostname().split(".")[0]


def now_iso() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def state_root() -> str:
    override = os.environ.get("AGENT_FABRIC_STATE_DIR")
    if override:
        return os.path.abspath(override)
    xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(xdg, "agent-fabric")


def agent_state_dir(agent: str | None = None) -> str:
    return os.path.join(state_root(), "agents", agent or current_agent())


def binding_path(agent: str | None = None) -> str:
    return os.path.join(agent_state_dir(agent), "binding.json")


def read_binding(agent: str | None = None) -> dict:
    """The agent's runtime binding, or {} when none has been written.

    A binding that names a different agent than the directory it sits in
    is refused rather than trusted: the directory is keyed by the login,
    and a record disagreeing with it is a copied file, not a binding.
    """
    agent = agent or current_agent()
    path = binding_path(agent)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except ValueError as exc:
        raise SystemExit(f"identity: {path} is not valid JSON ({exc})")
    if not isinstance(data, dict):
        raise SystemExit(f"identity: {path} is not a JSON object")
    if data.get("agent") not in (None, agent):
        raise SystemExit(f"identity: {path} names agent {data.get('agent')!r}, "
                         f"but this is {agent!r}'s state directory")
    return data


def write_binding(binding: dict, agent: str | None = None) -> str:
    """Write the agent's binding atomically. `agent` and `host` are stamped
    from the OS, never taken from the caller's dictionary."""
    agent = agent or current_agent()
    record = dict(binding)
    record["agent"] = agent
    record["host"] = current_host()
    record["updated_at"] = now_iso()
    directory = agent_state_dir(agent)
    os.makedirs(directory, exist_ok=True)
    path = binding_path(agent)
    fd, tmp = tempfile.mkstemp(prefix=".binding-", dir=directory)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
    return path


def _workingcopy():
    """tools/fabric/workingcopy.py, loaded by path so this file works from
    any cwd and any sys.path."""
    spec = importlib.util.spec_from_file_location(
        "fabric_workingcopy", os.path.join(FABRIC_ROOT, "tools", "fabric", "workingcopy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve_context(cwd: str | None = None, session: str | None = None,
                    agent: str | None = None) -> dict:
    """The agent plus everything bound to it right now.

    `project` comes from the working copy `cwd` sits in when that copy is a
    registered project; otherwise from the agent's binding (the project the
    role was activated for). `project_source` says which. The working copy
    is reported as a path and as its basename — the basename is a label
    for humans and logs, never an identity.
    """
    agent = agent or current_agent()
    cwd = os.path.abspath(cwd or os.getcwd())
    wc = _workingcopy().resolve(cwd)
    binding = read_binding(agent)
    if wc.get("project"):
        project, source = wc["project"], "working-copy"
    elif binding.get("project"):
        project, source = binding["project"], "binding"
    else:
        project, source = None, None
    return {
        "agent": agent,
        "host": current_host(),
        "role": binding.get("role"),
        "project": project,
        "project_source": source,
        "working_copy": wc.get("path"),
        "working_copy_id": wc.get("id"),
        "remote": wc.get("remote"),
        "session": session or os.environ.get("CLAUDE_SESSION_ID"),
        "cwd": cwd,
        "fabric_root": FABRIC_ROOT,
        "state_dir": agent_state_dir(agent),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Resolve the current agent identity and its runtime context.")
    ap.add_argument("--json", action="store_true", help="print the full context as JSON")
    ap.add_argument("--host", action="store_true", help="print the host label only")
    ap.add_argument("--role", action="store_true",
                    help="print the role this agent's binding holds (empty when none) — the binding alone, no working-copy resolution")
    ap.add_argument("--cwd", default=None, help="resolve working copy and project as seen from this directory")
    ap.add_argument("--session", default=None, help="session identifier to record in the context")
    args = ap.parse_args(argv)
    if args.host:
        print(current_host())
        return 0
    if args.role:
        print((read_binding() or {}).get("role") or "")
        return 0
    if args.json:
        print(json.dumps(resolve_context(args.cwd, args.session), ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    print(current_agent())
    return 0


if __name__ == "__main__":
    sys.exit(main())
