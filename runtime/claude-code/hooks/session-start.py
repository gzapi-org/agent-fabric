#!/usr/bin/env python3
"""runtime/claude-code/hooks/session-start.py — the SessionStart hook.

Reads the hook payload (cwd, session_id) on stdin, resolves the agent and
its context through runtime/identity.py, records the working copy,
project and session in the agent's runtime binding — never the role,
which only bin/fabric-role changes, from a login shell — and returns the
PROJECT LAYER of the session's context as hook output:

    {"hookSpecificOutput": {"hookEventName": "SessionStart",
                            "additionalContext": "agent-fabric: agent=… role=… project=… \n<the remit>\n<the INDEX pointer>"}}

The role layer (charter, brief, team and memory sections) is in the
system prompt the launcher rendered (tools/fabric/launch_prompt.py) and
never here. What goes here is what follows the working copy: the
project's remit for the role (<working copy>/.agent-fabric/roles/<role>.md
— what the function covers in THIS repository) and one line pointing at
the role's INDEX.md there. The hook runs at start, on resume and after a
compaction, so this layer is re-given each time from the cwd of the
moment — a session that moved to another working copy gets that
project's remit — and the drift line (a rebind under a running session)
is said at each of them. Read back live 2026-09-15: the JSON form is
taken (docs/live-checks/2026-09-15-append-system-prompt.md §6).

The agent name is whatever the OS says. The payload's cwd only tells us
which working copy and project the session is in; a session started in
the parent projects/ directory has neither and says so.

Never blocks a session start: any failure is one line on stderr and exit 0.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
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
        role = binding.get("role")
        lines = [f"agent-fabric: agent={ctx['agent']} host={ctx['host']} "
                 f"role={role or '(none — bin/fabric-role bind <role>)'} "
                 f"project={ctx['project'] or '(none)'} "
                 f"working_copy={ctx['working_copy'] or '(not in a working copy)'} "
                 f"control_plane={FABRIC_ROOT}"]
        # The hook runs on start, resume and after a compaction: a rebind
        # from a login shell under a running session is said at the next
        # of those, never left to disagree silently with the prompt.
        drift = identity.launch_role_drift(binding)
        if drift:
            lines.append(f"agent-fabric: DRIFT {drift}")
        lines += project_layer(role, ctx["project"], ctx["working_copy"])
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                 "additionalContext": "\n".join(lines)}}))
    except Exception as exc:  # noqa: BLE001 — a hook must never block a session
        print(f"agent-fabric session-start: {exc}", file=sys.stderr)
    return 0


def project_layer(role: str | None, project: str | None, working_copy: str | None) -> list[str]:
    """The remit and the INDEX pointer for (role, project) in this working
    copy, as context lines; what is missing is said in one line each."""
    if not role:
        return []
    if not (project and working_copy):
        return ["agent-fabric: not in a registered working copy — no project remit for "
                f"{role} here; cd into one and the next start or resume gives it."]
    remit = os.path.join(working_copy, ".agent-fabric", "roles", f"{role}.md")
    index = os.path.join(working_copy, ".agent-fabric", "memory", role, "INDEX.md")
    out: list[str] = []
    try:
        with open(remit, encoding="utf-8") as fh:
            body = fh.read()
        body = re.sub(r"\A---\n.*?\n---\n", "", body, count=1, flags=re.DOTALL).strip("\n")
        out.append(f"# {role} — remit in {project} ({os.path.relpath(remit, working_copy)})\n\n{body}")
    except OSError:
        out.append(f"agent-fabric: {project} has no remit for {role} "
                   f"({os.path.relpath(remit, working_copy)} is missing); the charter is the whole definition here.")
    if os.path.isfile(index):
        out.append(f"Your knowledge of {project}: {os.path.relpath(index, working_copy)} lists every slice with "
                   "its cue — open a slice when its cue matches what you are doing; nothing else now.")
    else:
        out.append(f"agent-fabric: {project} has no distilled knowledge for {role} yet "
                   f"({os.path.relpath(os.path.dirname(index), working_copy)}/).")
    return out


if __name__ == "__main__":
    sys.exit(main())
