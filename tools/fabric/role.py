#!/usr/bin/env python3
"""tools/roles/switch.py

>>> help
Make this working copy BE a role: install that role's skills and commands
where the harness discovers them, and record what was installed.

    tools/roles/switch.py flutter-dev        # become the Flutter developer
    tools/roles/switch.py --status           # what am I right now?
    tools/roles/switch.py flutter-dev --force

Why copies rather than symlinks. Roles hold disjoint tool sets, discovery
is by directory, and — the part that matters — a working copy that lives
as one role for weeks will adapt its own tools. A copy lets that happen
and survives; a link would make every clone share one file and would dangle
the moment a template is renamed upstream. So the copy is per-instance
working state, not a cache, and a switch that would discard local edits
stops and says so instead.

Why this never writes to the registry. The registry is committed, and a
switch can happen in the middle of unrelated work; dirtying the tracked
tree there would smuggle an identity change into someone's feature commit.
Identity changes therefore queue in this clone's own gitignored state and
are materialised by the next drain, which is already opening a pull
request.

What lands where:
    .roles/<role>/skills/<name>/  ->  .claude/skills/<name>/     (copied)
    .roles/<role>/commands/<n>.md ->  .claude/commands/<n>.md    (copied)
    .roles/.instance/state.json       this clone's identity and inventory
    .git/info/exclude                 managed block, so `git add -A` is safe

Exit 0 on success, 1 on a refusal that needs a decision, 2 on usage error.
<<< help
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import uuid

MARK_BEGIN = "# >>> gzapp role switcher (generated) >>>"
MARK_END = "# <<< gzapp role switcher (generated) <<<"

# Tier-1 knowledge, in load order. Two SHAPES are accepted per entry,
# because `workflow` is a directory of slices in every role rather than a
# single file — and the assembler has always emitted it that way. Naming
# only `workflow.md` here meant the existence check never matched, so
# activation silently listed two of the three tier-1 entries and 28
# `tier: 1` workflow slices across the nine roles never loaded at all.
# Silently, because the check that skipped them is the same one that
# legitimately skips a class a role has nothing in yet.
TIER1 = ("charter.md", "INDEX.md", "workflow")


def tier1_paths(role_dir: str) -> list[str]:
    """Tier-1 slice paths relative to role_dir, in TIER1 order.

    An entry resolves as a file (`<name>` or `<name>.md`) or, when it is a
    directory, as every `.md` slice inside it sorted by name. A missing
    entry yields nothing: a role with no slices of that class is normal.
    """
    found: list[str] = []
    for name in TIER1:
        as_dir = os.path.join(role_dir, name)
        if os.path.isdir(as_dir):
            found.extend(
                os.path.join(name, entry)
                for entry in sorted(os.listdir(as_dir))
                if entry.endswith(".md")
            )
            continue
        for candidate in (name, f"{name}.md"):
            if os.path.isfile(os.path.join(role_dir, candidate)):
                found.append(candidate)
                break
    return found


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def now_iso() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


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


def read_state(state_path: str) -> dict:
    if not os.path.exists(state_path):
        return {}
    with open(state_path, encoding="utf-8") as fh:
        return json.load(fh)


def adopt_clone_id(root: str, host: str, dir_basename: str) -> str | None:
    """A working copy already known to the registry keeps its identity rather
    than minting a second one for itself."""
    path = os.path.join(root, ".roles", "registry", "bindings.jsonl")
    if not os.path.exists(path):
        return None
    best = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("host") == host and row.get("dir_basename") == dir_basename:
                if row.get("valid_to") in (None, ""):
                    return row["clone_id"]
                best = row["clone_id"]
    return best


def git_exclude_path(root: str) -> str:
    """Where git ACTUALLY reads clone-local excludes from.

    `<root>/.git` is a directory only in an ordinary clone. In a linked
    worktree it is a FILE holding `gitdir: ...`, so joining onto it raises
    NotADirectoryError — and this is called LAST in a switch, after the
    tools, the state file and the active symlink are already written, so
    the crash left a half-installed role whose copies nothing excluded and
    `git add -A` would stage. Not hypothetical: this repo mandates
    worktree isolation on every subagent dispatch.

    `git rev-parse --git-path` is git's own resolver, so the worktree,
    separate-gitdir and submodule layouts are all handled without this
    code knowing about any of them. Note it resolves into the COMMON dir:
    a linked worktree shares info/exclude with its main clone. That is
    git's design rather than a choice made here, and the managed block is
    delimited precisely so rewriting it is safe.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--git-path", "info/exclude"],
            cwd=root, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    if not out:
        return os.path.join(root, ".git", "info", "exclude")
    return out if os.path.isabs(out) else os.path.join(root, out)


def open_binding_dir(root: str, clone_id: str) -> str | None:
    """The directory this clone is currently recorded under, per the registry.

    The fallback for a `state.json` written before `dir_basename` existed.
    There the field reads None, which is indistinguishable from "unchanged"
    — so a rename performed before the first switch on this version queued
    nothing, and the new state then recorded the CURRENT basename, closing
    the last chance to notice. The registry still holds the truth, so ask it
    rather than suppressing detection.
    """
    path = os.path.join(root, ".roles", "registry", "bindings.jsonl")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("clone_id") == clone_id and row.get("valid_to") in (None, ""):
                return row.get("dir_basename")
    return None


def write_exclude_block(root: str, paths: list[str]) -> None:
    """Role copies are untracked files with ordinary names, indistinguishable
    from real ones to git — so name them explicitly, clone-locally."""
    exclude = git_exclude_path(root)
    os.makedirs(os.path.dirname(exclude), exist_ok=True)
    existing = []
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
    block = [MARK_BEGIN, "# Installed by tools/roles/switch.py; do not edit by hand."]
    block += [f"/{p}" for p in sorted(paths)]
    block.append(MARK_END)
    with open(exclude, "w", encoding="utf-8") as fh:
        fh.write("\n".join(existing + [""] + block) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Switch this working copy to a role.")
    ap.add_argument("role", nargs="?", help="role id, e.g. flutter-dev")
    ap.add_argument("--status", action="store_true", help="report the active role and exit")
    ap.add_argument("--force", action="store_true",
                    help="replace locally adapted copies, stashing them first")
    args = ap.parse_args()

    root = repo_root()
    roles_dir = os.path.join(root, ".roles")
    instance_dir = os.path.join(roles_dir, ".instance")
    state_path = os.path.join(instance_dir, "state.json")
    state = read_state(state_path)
    host = socket.gethostname().split(".")[0]
    dir_basename = os.path.basename(root)

    if args.status or not args.role:
        if not state:
            print("no role active in this working copy")
            available = sorted(
                d for d in os.listdir(roles_dir)
                if os.path.isdir(os.path.join(roles_dir, d))
                and d not in {"schema", "registry", ".instance", "shared"}
            ) if os.path.isdir(roles_dir) else []
            if available:
                print("available roles:", ", ".join(available))
            return 0 if args.status else 2
        print(f"role      {state.get('role')}")
        print(f"clone_id  {state.get('clone_id')}")
        print(f"host      {state.get('host')}  dir {dir_basename}")
        print(f"since     {state.get('updated_at')}")
        for item in state.get("installed", []):
            drift = ""
            target = os.path.join(root, item["path"])
            if os.path.exists(target) and digest_path(target) != item.get("digest"):
                drift = "   [adapted locally]"
            print(f"  {item['kind']:8} {item['path']}{drift}")
        pending = state.get("pending_bindings") or []
        if pending:
            print(f"\n{len(pending)} binding change(s) queued for the next drain")
        return 0

    role = args.role
    role_dir = os.path.join(roles_dir, role)
    if not os.path.isdir(role_dir):
        print(f"switch: no role '{role}' under .roles/", file=sys.stderr)
        return 2

    # 1. What is installed now, and has any of it been adapted here?
    previous = state.get("installed", [])
    adapted = []
    for item in previous:
        target = os.path.join(root, item["path"])
        if os.path.exists(target) and digest_path(target) != item.get("digest"):
            adapted.append(item)
    if adapted and not args.force:
        print("switch: refusing — these copies were adapted in this working copy:",
              file=sys.stderr)
        for item in adapted:
            print(f"  {item['path']}", file=sys.stderr)
        print(
            "\nThose edits exist only here. Promote them into .roles/<role>/ with a pull\n"
            "request if they should outlive this clone, or re-run with --force to stash\n"
            "and replace them.",
            file=sys.stderr,
        )
        return 1

    # 1b. Build and validate the WHOLE new plan before touching anything.
    #     Validating after removal made a refusal destructive: the current
    #     role's tools were already gone, while the state file and exclude
    #     block still described them.
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

    ours = {item["path"] for item in previous}
    collisions = [rel for _s, rel, _k in plan
                  if os.path.exists(os.path.join(root, rel)) and rel not in ours]
    if collisions:
        print("switch: refusing — these already exist and are not ours to replace:",
              file=sys.stderr)
        for rel in collisions:
            print(f"  {rel}", file=sys.stderr)
        print("\nA committed skill or command of the same name would be shadowed. Rename "
              "the role's copy. Nothing was changed.", file=sys.stderr)
        return 1

    stash_dir = ""
    if adapted and args.force:
        stash_dir = os.path.join(instance_dir, "stash", now_iso().replace(":", ""))
        for item in adapted:
            target = os.path.join(root, item["path"])
            destination = os.path.join(stash_dir, item["path"])
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            if os.path.isdir(target):
                shutil.copytree(target, destination)
            else:
                shutil.copy2(target, destination)

    # 2. Remove exactly what a previous switch installed — never a wildcard
    #    sweep, which could take something this tool did not put there.
    for item in previous:
        target = os.path.join(root, item["path"])
        if os.path.isdir(target):
            shutil.rmtree(target, ignore_errors=True)
        elif os.path.exists(target):
            os.remove(target)

    # 3. Install the new role, under exact names (the name is the command).
    installed: list[dict[str, str]] = []
    for source, rel, kind in plan:
        target = os.path.join(root, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.isdir(source):
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
        installed.append({"path": rel, "source": os.path.relpath(source, root),
                          "kind": kind, "digest": digest_path(target)})

    # 4. Identity: keep it if we have it, adopt it if the registry knows this
    #    working copy, mint it only if truly new.
    clone_id = state.get("clone_id") or adopt_clone_id(root, host, dir_basename)
    minted = False
    if not clone_id:
        clone_id = f"clone-{uuid.uuid4().hex[:16]}"
        minted = True

    pending = list(state.get("pending_bindings") or [])
    changed_role = state.get("role") != role
    changed_host = state.get("host") not in (None, host)
    # A rename is a binding change too. Without recording the directory we
    # were last known by, renaming a working copy in place queued nothing, and
    # observations written under the new name resolved to no clone at all —
    # the very case the append-only window design exists to survive.
    #
    # A state file written before `dir_basename` existed reads None here,
    # which is indistinguishable from "unchanged" — so a rename done before
    # the first switch on this version was missed, and the state we write
    # below then records the CURRENT basename, destroying the evidence. The
    # registry's open window is the surviving record of where this clone was
    # last known, so consult it before concluding nothing moved.
    known_dir = state.get("dir_basename")
    if known_dir is None and not minted:
        known_dir = open_binding_dir(root, clone_id)
    changed_dir = known_dir not in (None, dir_basename)
    if minted or changed_role or changed_host or changed_dir:
        reason = "initial"
        if not minted:
            if changed_host:
                reason = "host-move"
            elif changed_dir:
                reason = "rename"
            else:
                reason = "role-change"
        pending.append({
            "clone_id": clone_id, "host": host, "dir_basename": dir_basename,
            "role": role, "valid_from": now_iso(),
            # `known_dir`, not the raw state field: in the pre-upgrade case
            # the field is None and the real previous name came from the
            # registry, which is the one worth recording.
            "previous_dir_basename": known_dir,
            "previous_host": state.get("host"),
            "reason": reason,
        })

    os.makedirs(instance_dir, exist_ok=True)
    new_state = {
        "clone_id": clone_id,
        "host": host,
        "dir_basename": dir_basename,
        "role": role,
        "updated_at": now_iso(),
        "installed": installed,
        "pending_bindings": pending,
    }
    with open(state_path, "w", encoding="utf-8") as fh:
        json.dump(new_state, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")

    active = os.path.join(instance_dir, "active")
    if os.path.islink(active) or os.path.exists(active):
        os.remove(active)
    os.symlink(os.path.join("..", role), active)

    write_exclude_block(root, [item["path"] for item in installed])

    # 5. Tell the caller what to load. Tier 1 only: everything else waits for
    #    a cue from the index.
    print(f"role: {role}   clone: {clone_id}   host: {host}")
    if stash_dir:
        print(f"stashed adapted copies -> {os.path.relpath(stash_dir, root)}")
    if installed:
        for item in installed:
            print(f"  installed {item['kind']:8} {item['path']}")
    else:
        print("  (this role ships no skills or commands yet)")
    print("\nload now:")
    for rel in tier1_paths(role_dir):
        print(f"  .roles/{role}/{rel}")
    print("\nEverything else loads on demand — consult INDEX.md when its cue matches.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
