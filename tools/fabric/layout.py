#!/usr/bin/env python3
"""tools/fabric/layout.py — where each kind of knowledge lives.

One module answers "where is it" so the activator, assembler, linter and
query tool agree by construction:

    identities/roles/<role>/            charter.md, recall.md, skills/, commands/
    memory/domains/<domain>/            domain slices (reusable field knowledge)
    memory/projects/<project>/<role>/   solution, intersection, rationale,
                                        workflow, threads, crossref.json, INDEX.md
    memory/shared/                      multi-owner slices
    memory/agents/<login>/              knowledge genuinely tied to one agent

Domain ids currently equal role ids: the extracted corpus filed domain
knowledge per role, and renaming domains was not part of the extraction.
A domain may be split or renamed later without touching this contract.
"""
from __future__ import annotations

import os

FABRIC_ROOT = os.environ.get("AGENT_FABRIC_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))))

IDENTITY_CLASSES = ("charter", "recall")
DOMAIN_CLASSES = ("domain",)
PROJECT_CLASSES = ("solution", "intersection", "rationale", "workflow", "threads")
# Tier-1 knowledge, in load order: the charter, the project index, the
# project workflow slices. Everything else waits for a cue from the index.
TIER1 = ("charter.md", "INDEX.md", "workflow")


def roles_dir() -> str:
    return os.path.join(FABRIC_ROOT, "identities", "roles")


def role_dir(role: str) -> str:
    return os.path.join(roles_dir(), role)


def catalog_path() -> str:
    return os.path.join(roles_dir(), "catalog.json")


def list_roles() -> list[str]:
    base = roles_dir()
    if not os.path.isdir(base):
        return []
    return sorted(d for d in os.listdir(base)
                  if os.path.isfile(os.path.join(base, d, "charter.md")))


def domain_dir(domain: str) -> str:
    return os.path.join(FABRIC_ROOT, "memory", "domains", domain)


def projects_memory_dir() -> str:
    return os.path.join(FABRIC_ROOT, "memory", "projects")


def project_dir(project: str, role: str) -> str:
    return os.path.join(projects_memory_dir(), project, role)


def shared_dir() -> str:
    return os.path.join(FABRIC_ROOT, "memory", "shared")


def agent_memory_dir(agent: str) -> str:
    return os.path.join(FABRIC_ROOT, "memory", "agents", agent)


def class_home(klass: str, role: str, project: str | None = None) -> str:
    """The directory a slice of `klass` for `role` belongs in."""
    if klass in IDENTITY_CLASSES:
        return role_dir(role)
    if klass in DOMAIN_CLASSES:
        return domain_dir(role)
    if klass in PROJECT_CLASSES or klass == "index":
        if not project:
            raise ValueError(f"class {klass!r} is project-scoped; no project given")
        return project_dir(project, role)
    raise ValueError(f"unknown knowledge class {klass!r}")


def slices_of(base: str, name: str) -> list[str]:
    """Paths (relative to `base`) for one tier-1 entry.

    Two shapes are accepted: a file (`<name>` or `<name>.md`) or a directory
    of `.md` slices, sorted by name. Naming only `workflow.md` once meant the
    directory shape — the one every role actually uses — never matched, and
    28 tier-1 slices loaded nowhere while nothing said so.
    """
    as_dir = os.path.join(base, name)
    if os.path.isdir(as_dir):
        return [os.path.join(name, e) for e in sorted(os.listdir(as_dir)) if e.endswith(".md")]
    for candidate in (name, f"{name}.md"):
        if os.path.isfile(os.path.join(base, candidate)):
            return [candidate]
    return []


def tier1_paths(role: str, project: str | None) -> list[str]:
    """Absolute paths to load at activation, in order. A role with nothing
    of a class, or no project context, simply yields fewer paths."""
    found = [os.path.join(role_dir(role), p) for p in slices_of(role_dir(role), "charter.md")]
    if project:
        base = project_dir(project, role)
        for name in TIER1[1:]:
            found += [os.path.join(base, p) for p in slices_of(base, name)]
    return found
