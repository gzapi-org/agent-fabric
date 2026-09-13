#!/usr/bin/env python3
"""Behavioural tests for tools/roles/switch.py.

Stdlib only; runnable as `python3 test_switch.py` or under pytest. Each
case builds a throwaway repository skeleton in a temp directory, so nothing
here touches the real working copy.

The cases target what makes a switcher dangerous rather than merely broken:
it deletes files, it writes into the directories the harness scans, and it
is the only thing that knows which of those files it put there. A switch
that removed something it did not install, silently discarded work someone
did locally, or shadowed a committed skill would all look like success.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SWITCH = os.path.join(HERE, "switch.py")


def build_repo(root: str) -> None:
    """A miniature of the real layout: two roles, one committed skill."""
    for role, skills, commands in (
        ("flutter-dev", ["widget-testing", "ble-debugging"], ["run-emulator.md"]),
        ("backend-dev", ["migration-check"], []),
    ):
        base = os.path.join(root, ".roles", role)
        os.makedirs(base, exist_ok=True)
        with open(os.path.join(base, "charter.md"), "w", encoding="utf-8") as fh:
            fh.write(f"---\nrole: {role}\nclass: charter\n---\n\n# {role}\n")
        with open(os.path.join(base, "INDEX.md"), "w", encoding="utf-8") as fh:
            fh.write(f"# {role} index\n")
        # flutter-dev gets the DIRECTORY shape every real role uses for
        # workflow; backend-dev deliberately gets none, so the "role has
        # nothing of this class" path stays covered too.
        if role == "flutter-dev":
            wf = os.path.join(base, "workflow")
            os.makedirs(wf, exist_ok=True)
            for slice_name in ("hot-reload-traps.md", "apk-signing.md"):
                with open(os.path.join(wf, slice_name), "w", encoding="utf-8") as fh:
                    fh.write(f"---\nrole: {role}\nclass: workflow\ntier: 1\n---\n\nbody\n")
            with open(os.path.join(wf, "notes.txt"), "w", encoding="utf-8") as fh:
                fh.write("not a slice\n")
        for skill in skills:
            d = os.path.join(base, "skills", skill)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as fh:
                fh.write(f"---\nname: {skill}\ndescription: {skill} for {role}\n---\n\nbody\n")
        for command in commands:
            d = os.path.join(base, "commands")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, command), "w", encoding="utf-8") as fh:
                fh.write("---\ndescription: x\n---\n\nbody\n")

    committed = os.path.join(root, ".claude", "skills", "adr-lookup")
    os.makedirs(committed, exist_ok=True)
    with open(os.path.join(committed, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write("---\nname: adr-lookup\ndescription: committed and universal\n---\n")
    os.makedirs(os.path.join(root, ".claude", "commands"), exist_ok=True)
    # Only in an ordinary clone. In a linked worktree `.git` is a FILE, and
    # this very makedirs is what raises NotADirectoryError — the harness
    # reproducing the bug it is meant to test. There, git owns the real
    # info/ directory in the common dir and the switcher resolves it.
    if not os.path.isfile(os.path.join(root, ".git")):
        os.makedirs(os.path.join(root, ".git", "info"), exist_ok=True)
    os.makedirs(os.path.join(root, "tools", "roles"), exist_ok=True)
    shutil.copy2(SWITCH, os.path.join(root, "tools", "roles", "switch.py"))


def run(root: str, *argv: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, os.path.join(root, "tools", "roles", "switch.py"), *argv],
        capture_output=True, text=True,
    )


def state_of(root: str) -> dict:
    with open(os.path.join(root, ".roles", ".instance", "state.json"), encoding="utf-8") as fh:
        return json.load(fh)


def test_install_places_copies_under_exact_names(root: str) -> None:
    proc = run(root, "flutter-dev")
    assert proc.returncode == 0, proc.stderr
    # The name IS the command, so a prefix or suffix would change what the
    # user types and break the whole point.
    assert os.path.isfile(os.path.join(root, ".claude/skills/widget-testing/SKILL.md"))
    assert os.path.isfile(os.path.join(root, ".claude/skills/ble-debugging/SKILL.md"))
    assert os.path.isfile(os.path.join(root, ".claude/commands/run-emulator.md"))


def test_copies_not_links(root: str) -> None:
    path = os.path.join(root, ".claude/skills/widget-testing")
    assert not os.path.islink(path), "must be a copy: a link cannot be adapted per clone"


def test_state_records_what_was_installed(root: str) -> None:
    state = state_of(root)
    assert state["role"] == "flutter-dev"
    assert state["clone_id"].startswith("clone-")
    paths = {i["path"] for i in state["installed"]}
    assert ".claude/skills/widget-testing" in paths
    assert all(i.get("digest") for i in state["installed"]), "digests enable the drift check"


def test_exclude_block_names_the_copies(root: str) -> None:
    with open(os.path.join(root, ".git/info/exclude"), encoding="utf-8") as fh:
        text = fh.read()
    assert "/.claude/skills/widget-testing" in text
    assert "/.claude/commands/run-emulator.md" in text


def test_exclude_block_preserves_existing_content(root: str) -> None:
    path = os.path.join(root, ".git/info/exclude")
    with open(path, encoding="utf-8") as fh:
        assert "# pre-existing user entry" in fh.read()


def test_switch_removes_only_what_it_installed(root: str) -> None:
    proc = run(root, "backend-dev")
    assert proc.returncode == 0, proc.stderr
    assert os.path.isfile(os.path.join(root, ".claude/skills/migration-check/SKILL.md"))
    assert not os.path.exists(os.path.join(root, ".claude/skills/widget-testing"))
    assert not os.path.exists(os.path.join(root, ".claude/commands/run-emulator.md"))
    # Never a wildcard sweep: the committed skill is still standing.
    assert os.path.isfile(os.path.join(root, ".claude/skills/adr-lookup/SKILL.md"))


def test_clone_id_survives_a_switch(root: str, first_id: str) -> None:
    assert state_of(root)["clone_id"] == first_id, "identity must not be re-minted on a switch"


def test_role_change_queues_a_binding_rather_than_writing_the_registry(root: str) -> None:
    pending = state_of(root)["pending_bindings"]
    assert any(p["reason"] == "role-change" for p in pending), pending
    # The registry is committed; a mid-task switch must not dirty the tree.
    assert not os.path.exists(os.path.join(root, ".roles/registry/bindings.jsonl"))


def test_locally_adapted_copy_blocks_a_switch(root: str) -> None:
    target = os.path.join(root, ".claude/skills/migration-check/SKILL.md")
    with open(target, "a", encoding="utf-8") as fh:
        fh.write("\nlocal adaptation made in this clone\n")
    proc = run(root, "flutter-dev")
    assert proc.returncode == 1, "an adapted copy must stop the switch"
    assert "adapted" in proc.stderr.lower()
    assert os.path.exists(target), "the adaptation must still be there after a refusal"


def test_force_stashes_before_replacing(root: str) -> None:
    proc = run(root, "flutter-dev", "--force")
    assert proc.returncode == 0, proc.stderr
    stash_root = os.path.join(root, ".roles/.instance/stash")
    found = []
    for dirpath, _dirnames, filenames in os.walk(stash_root):
        for name in filenames:
            found.append(os.path.join(dirpath, name))
    assert found, "--force must stash the adapted copy, not discard it"
    assert any("migration-check" in p for p in found), found


def test_collision_with_a_committed_skill_is_refused(root: str) -> None:
    """A role skill named like a committed one would shadow it silently."""
    clash = os.path.join(root, ".roles/backend-dev/skills/adr-lookup")
    os.makedirs(clash, exist_ok=True)
    with open(os.path.join(clash, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write("---\nname: adr-lookup\ndescription: impostor\n---\n")
    proc = run(root, "backend-dev")
    assert proc.returncode == 1, "must refuse to shadow a committed skill"
    assert "adr-lookup" in proc.stderr
    with open(os.path.join(root, ".claude/skills/adr-lookup/SKILL.md"), encoding="utf-8") as fh:
        assert "committed and universal" in fh.read(), "the committed skill must be untouched"


def test_refused_collision_leaves_the_current_role_intact(root: str) -> None:
    """A refusal must change nothing. Validating after removal meant the
    current role's tools were already deleted while the state file still
    described them — a refusal that broke the working copy."""
    run(root, "flutter-dev")
    before = state_of(root)
    assert before["role"] == "flutter-dev"
    installed = [i["path"] for i in before["installed"]]
    assert installed

    clash = os.path.join(root, ".roles/backend-dev/skills/adr-lookup")
    os.makedirs(clash, exist_ok=True)
    with open(os.path.join(clash, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write("---\nname: adr-lookup\ndescription: impostor\n---\n")

    proc = run(root, "backend-dev")
    assert proc.returncode == 1, "the collision must still be refused"
    for path in installed:
        assert os.path.exists(os.path.join(root, path)), \
            f"{path} was deleted by a refused switch"
    assert state_of(root)["role"] == "flutter-dev", "state must still describe the live role"
    shutil.rmtree(clash)


def test_directory_rename_queues_a_binding(root: str) -> None:
    """Renaming a working copy in place changes neither host nor role, so
    without tracking the directory it queued nothing — and observations under
    the new name then resolved to no clone."""
    run(root, "flutter-dev")
    state_path = os.path.join(root, ".roles", ".instance", "state.json")
    with open(state_path, encoding="utf-8") as fh:
        st = json.load(fh)
    assert st.get("dir_basename"), "state must record the directory it is known by"
    st["dir_basename"] = "gzapp-under-its-old-name"
    st["pending_bindings"] = []
    with open(state_path, "w", encoding="utf-8") as fh:
        json.dump(st, fh)

    run(root, "flutter-dev")          # same role, same host, different directory
    pending = state_of(root)["pending_bindings"]
    assert any(p["reason"] == "rename" for p in pending), pending
    row = next(p for p in pending if p["reason"] == "rename")
    assert row["previous_dir_basename"] == "gzapp-under-its-old-name"


def test_switch_works_inside_a_linked_worktree() -> None:
    """A linked worktree's `.git` is a FILE, not a directory.

    Joining `<root>/.git/info/exclude` onto it raises NotADirectoryError,
    and the exclude block is written LAST — after the tools, the state file
    and the active symlink — so the crash left a half-installed role whose
    copies nothing excluded and `git add -A` would stage. This repo mandates
    worktree isolation on every subagent dispatch, so the path is live.

    Builds a REAL repo and a REAL worktree: nothing less reproduces it,
    which is why the rest of the suite (a fabricated `.git/info` directory)
    never caught it.
    """
    with tempfile.TemporaryDirectory() as tmp:
        main_repo = os.path.join(tmp, "main-repo")
        os.makedirs(main_repo)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        def git(*a, cwd=main_repo):
            return subprocess.run(["git", "-c", "commit.gpgsign=false", *a],
                                  cwd=cwd, capture_output=True, text=True, env=env)
        git("init", "-q", ".")
        with open(os.path.join(main_repo, "seed.txt"), "w", encoding="utf-8") as fh:
            fh.write("seed\n")
        git("add", "seed.txt")
        git("commit", "-q", "-m", "init")

        linked = os.path.join(tmp, "linked")
        add = git("worktree", "add", "-q", "--detach", linked, "HEAD")
        assert add.returncode == 0, add.stderr

        # The precondition the bug rests on.
        assert os.path.isfile(os.path.join(linked, ".git")), \
            "a linked worktree must have a FILE .git for this test to mean anything"

        build_repo(linked)
        proc = run(linked, "flutter-dev")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "NotADirectoryError" not in proc.stderr, proc.stderr

        # And the block landed where git actually reads it from.
        resolved = subprocess.run(
            ["git", "rev-parse", "--git-path", "info/exclude"],
            cwd=linked, capture_output=True, text=True).stdout.strip()
        target = resolved if os.path.isabs(resolved) else os.path.join(linked, resolved)
        with open(target, encoding="utf-8") as fh:
            body = fh.read()
        assert ".claude/skills/widget-testing" in body, body


def test_rename_is_detected_from_the_registry_when_state_predates_the_field(root: str) -> None:
    """A `state.json` written before `dir_basename` existed reads None, which
    is indistinguishable from "unchanged".

    So a clone renamed before its first switch on this version queued no
    binding, and the state written afterwards recorded the CURRENT basename
    — destroying the only evidence and leaving the registry permanently
    attributing this clone's observations to a directory it no longer has.
    The registry's own open window survives that, so it is what gets asked.
    """
    run(root, "flutter-dev")
    state_path = os.path.join(root, ".roles", ".instance", "state.json")
    with open(state_path, encoding="utf-8") as fh:
        st = json.load(fh)
    clone_id = st["clone_id"]

    # A pre-upgrade state file: no dir_basename key at all.
    st.pop("dir_basename", None)
    st["pending_bindings"] = []
    with open(state_path, "w", encoding="utf-8") as fh:
        json.dump(st, fh)

    # ...and a registry that still knows this clone by its former name.
    reg = os.path.join(root, ".roles", "registry")
    os.makedirs(reg, exist_ok=True)
    with open(os.path.join(reg, "bindings.jsonl"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "clone_id": clone_id, "host": socket.gethostname().split(".")[0],
            "dir_basename": "gzapp-before-the-rename",
            "role": "flutter-dev", "valid_from": "2026-01-01T00:00:00Z",
            "valid_to": None,
        }) + "\n")

    run(root, "flutter-dev")
    pending = state_of(root)["pending_bindings"]
    assert any(p["reason"] == "rename" for p in pending), pending
    row = next(p for p in pending if p["reason"] == "rename")
    assert row["previous_dir_basename"] == "gzapp-before-the-rename", row


def _load_now(stdout: str) -> list[str]:
    """The paths under the `load now:` heading, in the order printed."""
    lines = stdout.splitlines()
    start = lines.index("load now:") + 1
    out = []
    for line in lines[start:]:
        if not line.startswith("  "):
            break
        out.append(line.strip())
    return out


def test_activation_lists_workflow_slices_from_the_directory(root: str) -> None:
    # The regression: TIER1 named `workflow.md`, every role ships a
    # `workflow/` DIRECTORY, and the existence check therefore never
    # matched — so tier-1 workflow knowledge loaded nowhere, silently.
    proc = run(root, "flutter-dev")
    assert proc.returncode == 0, proc.stderr
    listed = _load_now(proc.stdout)
    assert ".roles/flutter-dev/workflow/apk-signing.md" in listed, listed
    assert ".roles/flutter-dev/workflow/hot-reload-traps.md" in listed, listed


def test_activation_lists_tier1_in_order_with_workflow_last(root: str) -> None:
    proc = run(root, "flutter-dev")
    listed = _load_now(proc.stdout)
    assert listed[0].endswith("/charter.md"), listed
    assert listed[1].endswith("/INDEX.md"), listed
    assert all("/workflow/" in p for p in listed[2:]), listed


def test_activation_lists_only_markdown_slices(root: str) -> None:
    # A stray non-slice file in the directory is not knowledge to load.
    proc = run(root, "flutter-dev")
    assert "notes.txt" not in proc.stdout, proc.stdout


def test_activation_omits_a_tier1_class_the_role_does_not_have(root: str) -> None:
    # backend-dev ships no workflow at all. That is normal, not an error,
    # and must not print a path that does not exist.
    try:
        proc = run(root, "backend-dev")
        assert proc.returncode == 0, proc.stderr
        listed = _load_now(proc.stdout)
        assert listed == [".roles/backend-dev/charter.md", ".roles/backend-dev/INDEX.md"], listed
    finally:
        # These cases share one repo with the rest of the suite, and a
        # switch is global state — leave the role as we found it.
        run(root, "flutter-dev", "--force")


def test_activation_accepts_the_single_file_workflow_shape(root: str) -> None:
    # The shape the README described and no role uses. Accepting both keeps
    # the switcher honest if a role ever consolidates its workflow slices.
    path = os.path.join(root, ".roles", "backend-dev", "workflow.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("---\nrole: backend-dev\nclass: workflow\ntier: 1\n---\n\nbody\n")
    try:
        proc = run(root, "backend-dev")
        assert ".roles/backend-dev/workflow.md" in _load_now(proc.stdout), proc.stdout
    finally:
        os.remove(path)
        run(root, "flutter-dev", "--force")


def test_status_reports_the_active_role(root: str) -> None:
    proc = run(root, "--status")
    assert proc.returncode == 0, proc.stderr
    assert "flutter-dev" in proc.stdout
    assert "clone-" in proc.stdout


def test_unknown_role_is_a_usage_error(root: str) -> None:
    proc = run(root, "no-such-role")
    assert proc.returncode == 2, proc.stdout + proc.stderr


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as root:
        build_repo(root)
        with open(os.path.join(root, ".git/info/exclude"), "w", encoding="utf-8") as fh:
            fh.write("# pre-existing user entry\nscratch/\n")

        ordered = [
            ("install_places_copies_under_exact_names", lambda: test_install_places_copies_under_exact_names(root)),
            ("copies_not_links", lambda: test_copies_not_links(root)),
            ("state_records_what_was_installed", lambda: test_state_records_what_was_installed(root)),
            ("exclude_block_names_the_copies", lambda: test_exclude_block_names_the_copies(root)),
            ("exclude_block_preserves_existing_content", lambda: test_exclude_block_preserves_existing_content(root)),
        ]
        for name, fn in ordered:
            try:
                fn()
                print(f"  ok   {name}")
            except AssertionError as exc:
                failures += 1
                print(f"  FAIL {name}: {exc}")

        first_id = state_of(root)["clone_id"]
        rest = [
            ("switch_removes_only_what_it_installed", lambda: test_switch_removes_only_what_it_installed(root)),
            ("clone_id_survives_a_switch", lambda: test_clone_id_survives_a_switch(root, first_id)),
            ("role_change_queues_a_binding", lambda: test_role_change_queues_a_binding_rather_than_writing_the_registry(root)),
            ("locally_adapted_copy_blocks_a_switch", lambda: test_locally_adapted_copy_blocks_a_switch(root)),
            ("force_stashes_before_replacing", lambda: test_force_stashes_before_replacing(root)),
            ("collision_with_committed_skill_refused", lambda: test_collision_with_a_committed_skill_is_refused(root)),
            ("refused_collision_leaves_role_intact", lambda: test_refused_collision_leaves_the_current_role_intact(root)),
            ("directory_rename_queues_a_binding", lambda: test_directory_rename_queues_a_binding(root)),
            ("activation_lists_workflow_slices_from_the_directory",
             lambda: test_activation_lists_workflow_slices_from_the_directory(root)),
            ("activation_lists_tier1_in_order_with_workflow_last",
             lambda: test_activation_lists_tier1_in_order_with_workflow_last(root)),
            ("activation_lists_only_markdown_slices",
             lambda: test_activation_lists_only_markdown_slices(root)),
            ("activation_omits_a_tier1_class_the_role_does_not_have",
             lambda: test_activation_omits_a_tier1_class_the_role_does_not_have(root)),
            ("activation_accepts_the_single_file_workflow_shape",
             lambda: test_activation_accepts_the_single_file_workflow_shape(root)),
            ("status_reports_the_active_role", lambda: test_status_reports_the_active_role(root)),
            ("unknown_role_is_a_usage_error", lambda: test_unknown_role_is_a_usage_error(root)),
            ("rename_detected_from_registry_when_state_predates_field",
             lambda: test_rename_is_detected_from_the_registry_when_state_predates_the_field(root)),
            ("switch_works_inside_a_linked_worktree", test_switch_works_inside_a_linked_worktree),
        ]
        for name, fn in rest:
            try:
                fn()
                print(f"  ok   {name}")
            except AssertionError as exc:
                failures += 1
                print(f"  FAIL {name}: {exc}")

        total = len(ordered) + len(rest)
        print(f"\n{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
