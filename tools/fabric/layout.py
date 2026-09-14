#!/usr/bin/env python3
"""tools/fabric/layout.py — where each kind of knowledge lives.

One module answers "where is it" so the activator, assembler, linter and
query tool agree by construction:

    identities/roles/<role>/            charter.md, recall.md, skills/, commands/
    memory/domains/<domain>/            domain slices (reusable field knowledge)
    memory/shared/                      multi-owner field slices
    memory/agents/<login>/              knowledge genuinely tied to one agent

    <working copy>/.agent-fabric/memory/<role>/
                                        PROJECT knowledge: solution, intersection,
                                        rationale, workflow, threads, crossref.json,
                                        INDEX.md — and shared/ for multi-owner
                                        project slices
    <working copy>/.agent-fabric/roles/<role>.md
                                        the role's REMIT in that project: which
                                        surfaces, stack and rules the function
                                        covers there. The charter here is the
                                        function; the remit is the project's,
                                        authored, and loads at activation with it.

Project knowledge lives IN THE PROJECT'S REPOSITORY, not here. A `solution`
slice describes the tree as of a date and loses to the tree; the only way it
stays honest is to be versioned with the tree, so a change that moves the
architecture can update the slice in the same commit series, and a checkout
at any commit carries the knowledge that was true then. It also keeps a
project's confidential knowledge under the project's own license and
access, and leaves this repository plainly Apache-2.0.

`.agent-fabric/` in a managed repository is fabric-coordinator's to write
(policies/AUTHORITY.md): the drain writes it, every other role reads it.

The working copy for a project comes from, in order: an explicit
`set_working_copy()` (a tool's --working-copy), `$AGENT_FABRIC_WORKING_COPY`,
the agent's runtime binding (the session-start hook records the working copy
it started in), and — for agent-fabric as a managed project of its own —
this checkout. Links written into a project's INDEX.md are relative to the
working copy root; a fabric-side slice (charter, domain, memory/shared) is
linked as `../agent-fabric/<path>`, the sibling-checkout layout every
adapter already assumes.

A project whose memory has not moved yet would still have it under
`memory/projects/<project>/` here; that location is honoured while it
exists (no project is there today).

Domain ids currently equal role ids: the extracted corpus filed domain
knowledge per role, and renaming domains was not part of the extraction.
A domain may be split or renamed later without touching this contract.
"""
from __future__ import annotations

import json
import os

FABRIC_ROOT = os.environ.get("AGENT_FABRIC_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))))

# The project-side directory, and how a project's INDEX.md reaches back
# into this repository.
PROJECT_DIRNAME = ".agent-fabric"
PROJECT_MEMORY_SUBDIR = os.path.join(PROJECT_DIRNAME, "memory")
PROJECT_ROLES_SUBDIR = os.path.join(PROJECT_DIRNAME, "roles")
FABRIC_LINK_PREFIX = "../agent-fabric"
FABRIC_PROJECT_ID = "agent-fabric"

IDENTITY_CLASSES = ("charter", "recall")
DOMAIN_CLASSES = ("domain",)
PROJECT_CLASSES = ("solution", "intersection", "rationale", "workflow", "threads")
# Tier-1 knowledge, in load order: the charter, the project index, the
# project workflow slices. Everything else waits for a cue from the index.
TIER1 = ("charter.md", "INDEX.md", "workflow")

_WORKING_COPIES: dict[str, str] = {}


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


def shared_dir() -> str:
    return os.path.join(FABRIC_ROOT, "memory", "shared")


def agent_memory_dir(agent: str) -> str:
    return os.path.join(FABRIC_ROOT, "memory", "agents", agent)


# --- project homes ----------------------------------------------------------

def legacy_projects_memory_dir() -> str:
    """Where project memory lived before it moved into the projects."""
    return os.path.join(FABRIC_ROOT, "memory", "projects")


def set_working_copy(project: str, path: str | None) -> None:
    """Tell the layout where a project's working copy is for this run."""
    if path:
        _WORKING_COPIES[project] = os.path.abspath(path)
    else:
        _WORKING_COPIES.pop(project, None)


def _binding_working_copy(project: str) -> str | None:
    """The working copy this agent's runtime binding names, if it is for
    `project` (runtime/identity.py owns where the binding lives)."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "fabric_identity", os.path.join(FABRIC_ROOT, "runtime", "identity.py"))
        identity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(identity)  # type: ignore[union-attr]
        binding = identity.read_binding() or {}
    except Exception:  # noqa: BLE001
        return None
    if binding.get("project") == project and binding.get("working_copy"):
        return binding["working_copy"]
    return None


def explicit_working_copies() -> dict[str, str]:
    """The working copies this run was told about (set_working_copy)."""
    return dict(_WORKING_COPIES)


def working_copy_for(project: str) -> str | None:
    """The checkout holding `project`'s .agent-fabric/, if this run knows one."""
    if project in _WORKING_COPIES:
        return _WORKING_COPIES[project]
    env = os.environ.get("AGENT_FABRIC_WORKING_COPY")
    if env and _project_of_env_working_copy(env) == project:
        return os.path.abspath(env)
    bound = _binding_working_copy(project)
    if bound:
        return bound
    if project == FABRIC_PROJECT_ID:
        return FABRIC_ROOT
    return None


def _project_of_env_working_copy(path: str) -> str | None:
    """$AGENT_FABRIC_WORKING_COPY names a directory, not a project; resolve
    it through the registry the same way the session-start hook does."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "fabric_workingcopy", os.path.join(FABRIC_ROOT, "tools", "fabric", "workingcopy.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        return mod.resolve(path).get("project")
    except Exception:  # noqa: BLE001
        return None


def project_is_legacy(project: str) -> bool:
    """True while the project's memory still lives under memory/projects/ here."""
    return os.path.isdir(os.path.join(legacy_projects_memory_dir(), project))


def project_memory_root(project: str) -> str:
    """The directory holding <role>/ subtrees for a project."""
    if project_is_legacy(project):
        return os.path.join(legacy_projects_memory_dir(), project)
    wc = working_copy_for(project)
    if not wc:
        raise LookupError(
            f"project {project!r}: no working copy known (its memory lives in the project's "
            f"repository under {PROJECT_MEMORY_SUBDIR}/); pass --working-copy, set "
            "AGENT_FABRIC_WORKING_COPY, or activate from inside the working copy")
    return os.path.join(wc, PROJECT_MEMORY_SUBDIR)


def project_remit_path(project: str, role: str) -> str | None:
    """The role's authored remit in the project's working copy, if the
    working copy is known (None otherwise; a project need not have one)."""
    if project_is_legacy(project):
        return None
    wc = working_copy_for(project)
    return os.path.join(wc, PROJECT_ROLES_SUBDIR, f"{role}.md") if wc else None


def project_hygiene_path(project: str) -> str | None:
    """A project's own banned-pattern list, in its working copy: what must
    never appear in a slice because it names the deployment, a sibling
    project, or anything else that is that project's to keep. The fabric
    carries only the generic patterns (credentials, language)."""
    wc = working_copy_for(project)
    return os.path.join(wc, PROJECT_DIRNAME, "hygiene.json") if wc else None


def load_hygiene_patterns(projects: list[str] | None = None) -> list[tuple]:
    """Compiled (pattern, label) pairs: the generic ones, plus every listed
    project's own (from <working copy>/.agent-fabric/hygiene.json, when that
    working copy is known). Entries: {"pattern": <regex>, "label": <what it
    is>, "flags": "i"?}."""
    import re
    out: list[tuple] = [
        (re.compile(r"\bghp_[A-Za-z0-9]{10,}"), "credential"),
        (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "credential"),
        (re.compile(r"\bsk-[A-Za-z0-9-]{20,}"), "credential"),
        (re.compile(r"\bxox[bp]-[A-Za-z0-9-]{10,}"), "credential"),
    ]
    for pid in projects or []:
        path = project_hygiene_path(pid)
        if not path or not os.path.isfile(path):
            continue
        try:
            doc = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for entry in doc.get("patterns") or []:
            flags = re.I if "i" in (entry.get("flags") or "") else 0
            try:
                out.append((re.compile(entry["pattern"], flags), entry.get("label") or f"{pid} hygiene"))
            except (re.error, KeyError):
                continue
    return out


def project_link_root(project: str) -> str:
    """The directory INDEX.md links for this project are relative to."""
    if project_is_legacy(project):
        return FABRIC_ROOT
    return working_copy_for(project) or FABRIC_ROOT


def project_dir(project: str, role: str) -> str:
    return os.path.join(project_memory_root(project), role)


def project_report_path(project: str) -> str:
    """Where a drain leaves its report for this project."""
    if project_is_legacy(project):
        return os.path.join(FABRIC_ROOT, "memory", "last-drain-report.json")
    return os.path.join(project_memory_root(project), "last-drain-report.json")


def shared_home(klass: str, project: str | None = None) -> str:
    """Where a slice owned by several roles lives: field knowledge under
    memory/shared/, project knowledge under that project's shared/."""
    if klass in DOMAIN_CLASSES:
        return shared_dir()
    if not project:
        raise ValueError(f"shared {klass!r} is project-scoped; no project given")
    return os.path.join(project_memory_root(project), "shared")


def link_rel(path: str, project: str | None = None) -> str:
    """A path as an index writes it. Relative to the project's link root; a
    fabric-side path seen from a project's repository is linked through the
    sibling checkout (`../agent-fabric/...`)."""
    path = os.path.abspath(path)
    base = project_link_root(project) if project else FABRIC_ROOT
    fabric = os.path.abspath(FABRIC_ROOT)
    # The fabric first, when it is not the base itself: a checkout of the
    # fabric may sit INSIDE the working copy (CI checks it out under the
    # workspace), and a fabric slice is still reached through the sibling
    # prefix, never through wherever this run happened to put the checkout.
    if base != fabric and os.path.commonpath([path, fabric]) == fabric:
        return os.path.join(FABRIC_LINK_PREFIX, os.path.relpath(path, fabric))
    if os.path.commonpath([path, base]) == base:
        return os.path.relpath(path, base)
    return os.path.relpath(path, base)


def resolve_link(link: str, project: str | None = None) -> str:
    """The absolute path an index link denotes (the inverse of link_rel)."""
    if link.startswith(FABRIC_LINK_PREFIX + "/"):
        return os.path.join(FABRIC_ROOT, link[len(FABRIC_LINK_PREFIX) + 1:])
    base = project_link_root(project) if project else FABRIC_ROOT
    return os.path.join(base, link)


def root_rel(path: str) -> str:
    """A fabric-side path relative to this checkout (lint labels, provenance)."""
    return os.path.relpath(path, FABRIC_ROOT)


def list_projects() -> list[str]:
    """Projects whose memory this run can see: the legacy subtrees here, and
    every project with a known working copy that has a .agent-fabric/memory/."""
    found: set[str] = set()
    base = legacy_projects_memory_dir()
    if os.path.isdir(base):
        found.update(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    candidates = set(_WORKING_COPIES) | {FABRIC_PROJECT_ID}
    env = os.environ.get("AGENT_FABRIC_WORKING_COPY")
    if env:
        pid = _project_of_env_working_copy(env)
        if pid:
            candidates.add(pid)
    for pid in candidates:
        if pid in found:
            continue
        wc = working_copy_for(pid)
        if wc and os.path.isdir(os.path.join(wc, PROJECT_MEMORY_SUBDIR)):
            found.add(pid)
    return sorted(found)


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
        remit = project_remit_path(project, role)
        if remit and os.path.isfile(remit):
            found.append(remit)
        try:
            base = project_dir(project, role)
        except LookupError:
            return found  # no working copy known: the project's memory is out of reach
        for name in TIER1[1:]:
            found += [os.path.join(base, p) for p in slices_of(base, name)]
    return found
