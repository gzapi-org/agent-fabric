#!/usr/bin/env python3
"""tools/fabric/announce.py — HELLO and GOODBYE over GZCoord, best effort.

>>> help
    announce.py hello   --role R --project P
    announce.py goodbye --role R --project P [--note TEXT]
<<< help

One implementation for the two callers that announce presence:

  * runtime/openrouter/launch sends HELLO just before exec — a HELLO
    means a session actually exists (owner, 2026-09-15). It used to be
    sent by the role activator, which now runs from a login shell with no
    session behind it.
  * tools/fabric/role.py sends GOODBYE when a role is changed or dropped,
    as the role being left.

Never blocks its caller: no node, no relay scripts, no project, or a
refused send is one line on stderr and a normal return. Silent under
AGENT_FABRIC_NO_ANNOUNCE=1 (test sandboxes; a launch with no relay).
The message text is built by communication/gzcoord/scripts/gzmsg.mjs
(HELLO) or here (GOODBYE), and posted by send.mjs as the login this runs
as — FROM is never a claim.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(__file__))


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


layout = _load("fabric_layout", os.path.join(HERE, "layout.py"))
identity = _load("fabric_identity", os.path.join(layout.FABRIC_ROOT, "runtime", "identity.py"))

GZCOORD = os.path.join(layout.FABRIC_ROOT, "communication", "gzcoord", "scripts")


def announce(kind: str, ctx: dict, role: str | None, project: str | None, note: str = "") -> bool:
    """Send HELLO or GOODBYE; True when the relay accepted it. `ctx` needs
    `host` and `agent` (identity.resolve_context gives both)."""
    if os.environ.get("AGENT_FABRIC_NO_ANNOUNCE") == "1":
        return False
    if not (project and role and shutil.which("node")):
        return False
    gzmsg, send = os.path.join(GZCOORD, "gzmsg.mjs"), os.path.join(GZCOORD, "send.mjs")
    if not (os.path.isfile(gzmsg) and os.path.isfile(send)):
        return False
    try:
        if kind == "HELLO":
            text = subprocess.run(["node", gzmsg, "hello", "--role", role, "--project", project],
                                  capture_output=True, text=True, check=True).stdout
        else:
            mid = subprocess.run(["node", gzmsg, "new-id"], capture_output=True, text=True, check=True).stdout.strip()
            text = (f"[GZCOORD/1] GOODBYE\nFROM: {ctx['host']}/{ctx['agent']}\nROLE: {role}\n"
                    f"PROJECT: {project}\nMESSAGE-ID: {mid}\n\nNOTES:\n{note}\n")
        r = subprocess.run(["node", send, "-"], input=text, capture_output=True, text=True)
        if r.returncode == 0:
            print(f"  announced {kind} as {role}: {r.stdout.strip()}")
            return True
        print(f"  ({kind} not announced: {(r.stderr or '').strip().splitlines()[-1] if r.stderr else 'send failed'})",
              file=sys.stderr)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"  ({kind} not announced: {exc})", file=sys.stderr)
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="announce.py")
    parser.add_argument("kind", choices=("hello", "goodbye"))
    parser.add_argument("--role", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--note", default="")
    args = parser.parse_args(argv)
    ctx = {"agent": identity.current_agent(), "host": identity.current_host()}
    announce(args.kind.upper(), ctx, args.role, args.project, args.note)
    return 0  # best effort: the caller never fails on an announcement


if __name__ == "__main__":
    sys.exit(main())
