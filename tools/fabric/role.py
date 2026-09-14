#!/usr/bin/env python3
"""tools/fabric/role.py — activate a role for the current agent.

>>> help
    role.py activate <role> [--project ID] [--workspace DIR] [--force]
    role.py status                       what is this agent right now?
    role.py deactivate                   remove the installed copies
    role.py list                         the roles available

The AGENT is the Linux login (runtime/identity.py); it never changes here.
Activation binds a ROLE to that agent — recorded in the agent's runtime
binding outside the repository — and installs the role's skills and
commands into the WORKSPACE's `.claude/`, where the harness discovers them.
The workspace is `--workspace`, else $CLAUDE_PROJECT_DIR, else the current
directory: the place Claude Code was launched from, which may be the
parent `projects/` directory or one working copy.

Why copies rather than symlinks: an agent that lives as one role for weeks
adapts its own tools. A copy lets that happen and survives; a link would
make every agent share one file. So the copy is working state, and a switch
that would discard local edits stops and says so instead.

Why nothing here writes to a committed file: a switch can happen in the
middle of unrelated work. The binding goes to the agent's state directory;
a per-agent `role-history.jsonl` there keeps the chronology for provenance.

Exit 0 on success, 1 on a refusal that needs a decision, 2 on usage error.
<<< help
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
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

MARK_BEGIN = "# >>> agent-fabric role activator (generated) >>>"
MARK_END = "# <<< agent-fabric role activator (generated) <<<"


def digest_path(path: str) -> str:
    """Content digest of a file or a whole directory, order-independent."""
    sha = hashlib.sha256()
    if os.path.isfile(path):
        with open(path, "rb") as fh:
            sha.update(fh.read())
        return sha.hexdigest()[:32]
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            sha.update(os.path.relpath(full, path).encode())
            with open(full, "rb") as fh:
                sha.update(fh.read())
    return sha.hexdigest()[:32]


def git_exclude_path(workspace: str) -> str | None:
    """Where git reads local excludes for this workspace, or None when the
    workspace is not inside a repository (the parent `projects/` directory).

    `git rev-parse --git-path` is git's own resolver, so linked worktrees,
    separate git dirs and submodules are handled without this code knowing
    about any of them.
    """
    try:
        out = subprocess.run(["git", "rev-parse", "--git-path", "info/exclude"],
                             cwd=workspace, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not out:
        return None
    return out if os.path.isabs(out) else os.path.join(workspace, out)


def write_exclude_block(workspace: str, paths: list[str]) -> None:
    """Installed copies are untracked files with ordinary names, so git is
    told about them explicitly, locally, in a delimited block."""
    exclude = git_exclude_path(workspace)
    if exclude is None:
        return
    os.makedirs(os.path.dirname(exclude), exist_ok=True)
    existing: list[str] = []
    if os.path.exists(exclude):
        with open(exclude, encoding="utf-8") as fh:
            keep, skipping = [], False
            for line in fh.read().split("\n"):
                if line.strip() == MARK_BEGIN:
                    skipping = True
                    continue
                if line.strip() == MARK_END:
                    skipping = False
                    continue
                if not skipping:
                    keep.append(line)
            existing = keep
    while existing and existing[-1] == "":
        existing.pop()
    block = [MARK_BEGIN, "# Installed by tools/fabric/role.py; do not edit by hand."]
    block += [f"/{p}" for p in sorted(paths)]
    block.append(MARK_END)
    with open(exclude, "w", encoding="utf-8") as fh:
        fh.write("\n".join(existing + [""] + block) + "\n")


def adapted_items(workspace: str, installed: list[dict]) -> list[dict]:
    out = []
    for item in installed:
        target = os.path.join(workspace, item["path"])
        if os.path.exists(target) and digest_path(target) != item.get("digest"):
            out.append(item)
    return out


def append_history(state_dir: str, record: dict) -> None:
    os.makedirs(state_dir, exist_ok=True)
    with open(os.path.join(state_dir, "role-history.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def cmd_list() -> int:
    roles = layout.list_roles()
    if not roles:
        print(f"no roles under {layout.roles_dir()}")
        return 2
    print("available roles:", ", ".join(roles))
    return 0


def cmd_status(ctx: dict) -> int:
    binding = identity.read_binding(ctx["agent"])
    print(f"agent     {ctx['agent']}")
    print(f"host      {ctx['host']}")
    print(f"role      {binding.get('role') or '(none active)'}")
    print(f"project   {ctx['project'] or '(none)'}"
          + (f"  [from {ctx['project_source']}]" if ctx.get("project_source") else ""))
    print(f"working   {ctx['working_copy'] or '(not in a working copy)'}")
    if binding.get("workspace"):
        print(f"workspace {binding['workspace']}")
    if binding.get("updated_at"):
        print(f"since     {binding['updated_at']}")
    workspace = binding.get("workspace") or ""
    for item in binding.get("installed", []):
        drift = ""
        target = os.path.join(workspace, item["path"])
        if os.path.exists(target) and digest_path(target) != item.get("digest"):
            drift = "   [adapted locally]"
        print(f"  {item['kind']:8} {item['path']}{drift}")
    if not binding.get("role"):
        roles = layout.list_roles()
        if roles:
            print("available roles:", ", ".join(roles))
    return 0


def cmd_deactivate(ctx: dict) -> int:
    binding = identity.read_binding(ctx["agent"])
    workspace = binding.get("workspace")
    if not binding.get("role"):
        print("no role active for this agent")
        return 0
    if workspace:
        for item in binding.get("installed", []):
            target = os.path.join(workspace, item["path"])
            if os.path.isdir(target):
                shutil.rmtree(target, ignore_errors=True)
            elif os.path.exists(target):
                os.remove(target)
        write_exclude_block(workspace, [])
    append_history(ctx["state_dir"], {
        "agent": ctx["agent"], "host": ctx["host"], "role": None,
        "previous_role": binding.get("role"), "project": binding.get("project"),
        "working_copy": binding.get("working_copy"), "valid_from": identity.now_iso(),
        "reason": "deactivate",
    })
    identity.write_binding({**binding, "role": None, "installed": [], "session": ctx.get("session")},
                           ctx["agent"])
    active = os.path.join(ctx["state_dir"], "active")
    if os.path.islink(active) or os.path.exists(active):
        os.remove(active)
    print(f"agent: {ctx['agent']}   role: (none)")
    return 0


def cmd_activate(ctx: dict, role: str, workspace: str, force: bool, project: str | None) -> int:
    role_dir = layout.role_dir(role)
    if not os.path.isfile(os.path.join(role_dir, "charter.md")):
        print(f"role: no role '{role}' under {layout.roles_dir()}", file=sys.stderr)
        available = layout.list_roles()
        if available:
            print("available roles: " + ", ".join(available), file=sys.stderr)
        return 2

    binding = identity.read_binding(ctx["agent"])
    previous = binding.get("installed", []) or []
    previous_workspace = binding.get("workspace") or workspace

    # 1. What is installed now, and has any of it been adapted?
    adapted = adapted_items(previous_workspace, previous)
    if adapted and not force:
        print("role: refusing — these copies were adapted in the workspace:", file=sys.stderr)
        for item in adapted:
            print(f"  {os.path.join(previous_workspace, item['path'])}", file=sys.stderr)
        print("\nThose edits exist only there. Promote them into identities/roles/<role>/\n"
              "with a pull request if they should outlive this workspace, or re-run with\n"
              "--force to stash and replace them.", file=sys.stderr)
        return 1

    # 1b. Build and validate the WHOLE plan before touching anything.
    plan: list[tuple[str, str, str]] = []
    skills_src = os.path.join(role_dir, "skills")
    if os.path.isdir(skills_src):
        for name in sorted(os.listdir(skills_src)):
            source = os.path.join(skills_src, name)
            if os.path.isdir(source):
                plan.append((source, os.path.join(".claude", "skills", name), "skill"))
    commands_src = os.path.join(role_dir, "commands")
    if os.path.isdir(commands_src):
        for name in sorted(os.listdir(commands_src)):
            if name.endswith(".md"):
                plan.append((os.path.join(commands_src, name),
                             os.path.join(".claude", "commands", name), "command"))

    ours = {item["path"] for item in previous} if previous_workspace == workspace else set()
    collisions = [rel for _s, rel, _k in plan
                  if os.path.exists(os.path.join(workspace, rel)) and rel not in ours]
    if collisions:
        print("role: refusing — these already exist in the workspace and are not ours to replace:",
              file=sys.stderr)
        for rel in collisions:
            print(f"  {os.path.join(workspace, rel)}", file=sys.stderr)
        print("\nA committed skill or command of the same name would be shadowed. Rename "
              "the role's copy. Nothing was changed.", file=sys.stderr)
        return 1

    stash_dir = ""
    if adapted and force:
        stash_dir = os.path.join(ctx["state_dir"], "stash", identity.now_iso().replace(":", ""))
        for item in adapted:
            target = os.path.join(previous_workspace, item["path"])
            destination = os.path.join(stash_dir, item["path"])
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            if os.path.isdir(target):
                shutil.copytree(target, destination)
            else:
                shutil.copy2(target, destination)

    # 2. Remove exactly what a previous activation installed — never a sweep.
    for item in previous:
        target = os.path.join(previous_workspace, item["path"])
        if os.path.isdir(target):
            shutil.rmtree(target, ignore_errors=True)
        elif os.path.exists(target):
            os.remove(target)
    if previous_workspace != workspace:
        write_exclude_block(previous_workspace, [])

    # 3. Install the new role under exact names (the name is the command).
    installed: list[dict[str, str]] = []
    for source, rel, kind in plan:
        target = os.path.join(workspace, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.isdir(source):
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
        installed.append({"path": rel, "source": os.path.relpath(source, layout.FABRIC_ROOT),
                          "kind": kind, "digest": digest_path(target)})
    write_exclude_block(workspace, [item["path"] for item in installed])

    # 4. Bind. The agent is stamped by identity.py from the OS; the role,
    #    project and working copy are the attributes bound to it.
    # The project bound here is the one the WORKSPACE belongs to (or the one
    # named explicitly). A previous binding's project is deliberately not
    # carried over: activating from the parent directory means no project
    # context, and saying so beats silently keeping a stale one.
    if not project and ctx.get("project_source") == "working-copy":
        project = ctx["project"]
    changed = binding.get("role") != role or binding.get("project") != project
    if changed or not binding:
        append_history(ctx["state_dir"], {
            "agent": ctx["agent"], "host": ctx["host"], "role": role,
            "previous_role": binding.get("role"), "project": project,
            "working_copy": ctx["working_copy"], "valid_from": identity.now_iso(),
            "reason": "initial" if not binding.get("role") else "role-change",
        })
    identity.write_binding({
        "role": role, "project": project, "working_copy": ctx["working_copy"],
        "workspace": workspace, "session": ctx.get("session"), "installed": installed,
    }, ctx["agent"])
    active = os.path.join(ctx["state_dir"], "active")
    if os.path.islink(active) or os.path.exists(active):
        os.remove(active)
    os.symlink(role_dir, active)

    # 5. Tell the caller what to load. Tier 1 only.
    print(f"agent: {ctx['agent']}   role: {role}   host: {ctx['host']}   "
          f"project: {project or '(none)'}")
    if stash_dir:
        print(f"stashed adapted copies -> {stash_dir}")
    if installed:
        for item in installed:
            print(f"  installed {item['kind']:8} {os.path.join(workspace, item['path'])}")
    else:
        print("  (this role ships no skills or commands yet)")
    print("\nload now:")
    if project and ctx.get("working_copy"):
        layout.set_working_copy(project, ctx["working_copy"])
    for path in layout.tier1_paths(role, project):
        print(f"  {path}")
    if not project:
        print("  (no project context: only the charter loads; activate from inside a "
              "registered working copy, or pass --project, for its index and workflow)")
    elif not layout.project_is_legacy(project) and not layout.working_copy_for(project):
        print(f"  (project {project}: its memory lives in its repository under "
              f"{layout.PROJECT_MEMORY_SUBDIR}/; activate from inside the working copy to load it)")
    print("\nEverything else loads on demand — consult INDEX.md when its cue matches.")
    print("The charter is the role's function; the project's .agent-fabric/roles/<role>.md,")
    print("when listed above, is what that function covers in this project.")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Activate a role for the current agent.")
    ap.add_argument("command", nargs="?", help="activate | status | deactivate | list, or a role id")
    ap.add_argument("role", nargs="?", help="role id, e.g. flutter-dev")
    ap.add_argument("--status", action="store_true", help="alias for `status`")
    ap.add_argument("--force", action="store_true",
                    help="replace locally adapted copies, stashing them first")
    ap.add_argument("--project", default=None, help="logical project id to bind the role to")
    ap.add_argument("--workspace", default=None,
                    help="directory whose .claude/ receives skills (default: $CLAUDE_PROJECT_DIR or cwd)")
    args = ap.parse_args(argv)

    workspace = os.path.abspath(args.workspace or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    ctx = identity.resolve_context(cwd=workspace)

    command, role = args.command, args.role
    if args.status or command in (None, "status"):
        return cmd_status(ctx)
    if command == "list":
        return cmd_list()
    if command == "deactivate":
        return cmd_deactivate(ctx)
    if command == "activate":
        if not role:
            ap.error("activate needs a role id")
    else:
        role, command = command, "activate"
    return cmd_activate(ctx, role, workspace, args.force, args.project)


if __name__ == "__main__":
    sys.exit(main())
