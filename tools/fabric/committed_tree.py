"""tools/fabric/committed_tree.py — the files of a git repository's committed tree (HEAD) under one directory, read through git.

The memory server serves only what lint has seen, and lint sees what is committed (agent-fabric ADR-049 rule 6): so it reads
`git show HEAD:<path>` and never the working tree, where an uncommitted slice, a half-edited one or a link to some other file
may stand. Git objects have no filesystem path to follow, so there is no link to leave a root by; a symlink or a submodule
entry is skipped by its mode.

CONTRACT
  read(directory)  -> {path relative to directory: bytes} of every regular blob (mode 100644 or 100755) of HEAD under
                      `directory`, which must lie in a git working tree. Raises CommittedTreeError, one line, when it
                      does not (no repository, no commit yet, git missing, a timeout): unknown stays unknown, never an
                      empty tree that looks like a corpus with nothing in it.
  git is run with an argument list, a timeout, a checked status and an environment of its own: no user or system
  configuration, no GIT_DIR, no prompt, no pager."""
from __future__ import annotations

import os
import subprocess

LS_TIMEOUT_S = 30
CAT_TIMEOUT_S = 60
REGULAR = ("100644", "100755")
MAX_BLOB = 1 << 20          # a slice is a few kilobytes; a megabyte is not a slice


class CommittedTreeError(Exception):
    """The committed tree cannot be read: one line."""


def _env() -> dict[str, str]:
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"}


def _git(directory: str, args: list[str], timeout: int, stdin: bytes | None = None) -> bytes:
    try:
        done = subprocess.run(["git", "-C", directory, *args], input=stdin, capture_output=True, timeout=timeout, env=_env(), check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise CommittedTreeError(f"{directory}: git did not run ({type(e).__name__})") from None
    if done.returncode != 0:
        why = done.stderr.decode("utf-8", "replace").strip().splitlines()
        raise CommittedTreeError(f"{directory}: git {args[0]} failed" + (f" ({why[0][:120]})" if why else ""))
    return done.stdout


def read(directory: str) -> dict[str, bytes]:
    if not os.path.isdir(directory):
        raise CommittedTreeError(f"{directory}: not a directory")
    if os.path.islink(directory):
        raise CommittedTreeError(f"{directory}: is a link, and a corpus root is never one (git would answer for the repository it points into)")
    top = _git(directory, ["rev-parse", "--show-toplevel"], LS_TIMEOUT_S).decode("utf-8", "surrogateescape").strip()
    prefix = os.path.relpath(os.path.realpath(directory), os.path.realpath(top))
    listing = _git(top, ["ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", prefix if prefix != "." else "."], LS_TIMEOUT_S)
    entries: list[tuple[str, str]] = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        fields = meta.split()
        if len(fields) == 3 and fields[0].decode() in REGULAR and fields[1] == b"blob":
            entries.append((fields[2].decode(), path.decode("utf-8", "surrogateescape")))
    if not entries:
        return {}
    wanted = "".join(f"{sha}\n" for sha, _p in entries).encode()
    blobs = _git(top, ["cat-file", "--batch"], CAT_TIMEOUT_S, wanted)
    out: dict[str, bytes] = {}
    at = 0
    for sha, path in entries:
        end = blobs.find(b"\n", at)
        header = blobs[at:end].split()
        if len(header) != 3 or header[0].decode() != sha or header[1] != b"blob":
            raise CommittedTreeError(f"{directory}: git cat-file answered something that is not the blob asked for")
        size = int(header[2])
        body = blobs[end + 1:end + 1 + size]
        at = end + 1 + size + 1
        rel = os.path.relpath(path, prefix) if prefix != "." else path
        if size <= MAX_BLOB:
            out[rel] = body
    return out
