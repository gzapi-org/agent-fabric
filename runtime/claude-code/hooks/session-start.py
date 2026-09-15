#!/usr/bin/env python3
"""runtime/claude-code/hooks/session-start.py — the SessionStart hook.

Reads the hook payload (cwd, session_id) on stdin, resolves the agent and
its context through runtime/identity.py, records the working copy,
project and session in the agent's runtime binding — never the role,
which only bin/fabric-role changes, from a login shell — and prints one
line of context for the session.

    agent-fabric: agent=user host=develop-qzapp role=backend-dev project=gzapp working_copy=/home/user/projects/gzapp-claude2

The agent name is whatever the OS says. The payload's cwd only tells us
which working copy and project the session is in; a session started in
the parent projects/ directory has neither and says so.

Never blocks a session start: any failure is one line on stderr and exit 0.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys

FABRIC_ROOT = os.environ.get("AGENT_FABRIC_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))


def main() -> int:
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        payload = {}
    cwd = payload.get("cwd") if isinstance(payload, dict) else None
    session = payload.get("session_id") if isinstance(payload, dict) else None
    try:
        spec = importlib.util.spec_from_file_location(
            "fabric_identity", os.path.join(FABRIC_ROOT, "runtime", "identity.py"))
        identity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(identity)
        ctx = identity.resolve_context(cwd=cwd or os.getcwd(), session=session)
        binding = identity.read_binding(ctx["agent"])
        binding.update({
            "working_copy": ctx["working_copy"],
            "project": ctx["project"] if ctx["project_source"] == "working-copy" else binding.get("project"),
            "session": session or binding.get("session"),
        })
        identity.write_binding(binding, ctx["agent"])
        print(f"agent-fabric: agent={ctx['agent']} host={ctx['host']} "
              f"role={binding.get('role') or '(none — bin/fabric-role bind <role>)'} "
              f"project={ctx['project'] or '(none)'} "
              f"working_copy={ctx['working_copy'] or '(not in a working copy)'} "
              f"control_plane={FABRIC_ROOT}")
    except Exception as exc:  # noqa: BLE001 — a hook must never block a session
        print(f"agent-fabric session-start: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
