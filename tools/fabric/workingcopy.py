#!/usr/bin/env python3
"""tools/fabric/workingcopy.py — working copy and logical project resolution.

A WORKING COPY is a filesystem checkout: a path, a git toplevel, a remote.
A PROJECT is the logical system that checkout is a copy of. Many working
copies map to one project (the legacy repository's clone directories were
all copies of one project), and neither of them is the agent using it.

Resolution is by the checkout's origin remote against projects/registry.json,
or by a `.agent-fabric-project` marker file at the toplevel naming the
project id — and a marker that names an unknown project is an error, not
a fall-through. A directory basename is never used to guess a project:
names are conveniences, and the old system's `legacy-family` bucket is
what guessing from them produced.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from typing import Any

FABRIC_ROOT = os.environ.get("AGENT_FABRIC_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
MARKER = ".agent-fabric-project"


def _git(args: list[str], cwd: str) -> str | None:
    try:
        out = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return out.strip() or None


def toplevel(path: str) -> str | None:
    """The git toplevel containing `path`, or None outside any repository."""
    directory = path if os.path.isdir(path) else os.path.dirname(path)
    if not os.path.isdir(directory):
        return None
    return _git(["rev-parse", "--show-toplevel"], directory)


def remote_url(top: str, name: str = "origin") -> str | None:
    return _git(["remote", "get-url", name], top)


def normalize_remote(url: str) -> str:
    """`git@github.com:org/repo.git`, `https://github.com/org/repo/` and
    `ssh://git@github.com/org/repo.git` all become `github.com/org/repo`."""
    u = url.strip()
    u = re.sub(r"^[a-z][a-z0-9+.-]*://", "", u, flags=re.I)
    u = re.sub(r"^[^@/]+@", "", u)
    head, sep, tail = u.partition("/")
    if ":" in head:
        host, _, first = head.partition(":")
        u = f"{host}/{first}{sep}{tail}"
    u = u.rstrip("/")
    if u.endswith(".git"):
        u = u[:-4]
    return u.lower()


def load_registry(path: str | None = None) -> dict[str, Any]:
    path = path or os.path.join(FABRIC_ROOT, "projects", "registry.json")
    if not os.path.exists(path):
        return {"version": 1, "projects": {}}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def project_for_remote(url: str | None, registry: dict[str, Any]) -> str | None:
    if not url:
        return None
    wanted = normalize_remote(url)
    for pid, entry in (registry.get("projects") or {}).items():
        if any(normalize_remote(r) == wanted for r in entry.get("remotes") or []):
            return pid
    return None


def resolve(path: str, registry: dict[str, Any] | None = None) -> dict[str, Any]:
    """{path, id, remote, project, project_source} for the working copy
    containing `path`. Outside a repository every field is None."""
    top = toplevel(path)
    if not top:
        return {"path": None, "id": None, "remote": None, "project": None, "project_source": None}
    registry = registry if registry is not None else load_registry()
    remote = remote_url(top)
    project, source = None, None
    marker = os.path.join(top, MARKER)
    if os.path.isfile(marker):
        # A marker is a declaration, not a hint: one that names nothing the
        # registry knows is an error the human sees, never a silent fall
        # back to the remote (review, 2026-09-16 — before this, a typo in
        # the marker resolved to whatever the remote said, or to nothing).
        with open(marker, encoding="utf-8") as fh:
            declared = fh.read().strip()
        known = registry.get("projects") or {}
        if not declared:
            raise SystemExit(f"workingcopy: {marker} is empty; it must name a project id from "
                             f"projects/registry.json ({', '.join(sorted(known)) or 'none registered'}), "
                             "or be removed so the remote decides")
        if declared not in known:
            raise SystemExit(f"workingcopy: {marker} names project {declared!r}, which projects/registry.json "
                             f"does not know ({', '.join(sorted(known)) or 'none registered'}). Fix the marker, "
                             "register the project, or remove the marker so the remote decides")
        project, source = declared, "marker"
    if project is None:
        project = project_for_remote(remote, registry)
        source = "remote" if project else None
    return {"path": top, "id": os.path.basename(top), "remote": remote,
            "project": project, "project_source": source}


if __name__ == "__main__":
    import sys
    print(json.dumps(resolve(sys.argv[1] if len(sys.argv) > 1 else os.getcwd()), indent=2, sort_keys=True))
