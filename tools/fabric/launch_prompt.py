#!/usr/bin/env python3
"""tools/fabric/launch_prompt.py — the system prompt a session is born with.

>>> help
    launch_prompt.py --out FILE        render for this agent's bound role, write
                                       FILE atomically, print sha256:<hex>
    launch_prompt.py --print           render to stdout, write nothing
<<< help

runtime/openrouter/launch calls this just before exec and passes the file
to claude as `--append-system-prompt-file` (read back live on both launch
paths: docs/live-checks/2026-09-15-append-system-prompt.md). The session
therefore holds its role from its first request, in the system prompt —
which survives compaction and cannot be edited from inside — instead of
being asked to Read a charter after it starts (the old /role command).

WHO IS NOT A PARAMETER. Agent, host and role are resolved here, from the
OS and the runtime binding (runtime/identity.py); the caller names only
where the file goes. Nothing about identity can be passed in.

WHAT GOES IN, in order: the identity header; the role's charter; its brief
(how the role works, in any project — absent until written, and a missing
brief never blocks a launch); then the two sections every role shares,
identities/prompt/team.md and memory.md, with `{role}` substituted.

WHAT STAYS OUT: the project. The remit, the INDEX pointer and the working
copy follow the cwd and change with `cd`; they reach the session from the
SessionStart hook (runtime/claude-code/hooks/session-start.py), never
from this file. The filesystem is context, not identity.

BYTE-STABLE by construction: no timestamps, no session id, no cwd. The
same (agent, host, role) renders the same bytes, so the harness's prompt
prefix stays cacheable across relaunches and the digest the launcher
stamps (AGENT_FABRIC_LAUNCH_PROMPT_DIGEST) changes only when the content
did.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


layout = _load("fabric_layout", os.path.join(HERE, "layout.py"))
identity = _load("fabric_identity", os.path.join(layout.FABRIC_ROOT, "runtime", "identity.py"))

FRONTMATTER_RE = re.compile(r"\A---\n.*?\n---\n", re.DOTALL)
# ~5 000 tokens: fabric-coordinator's 7 KB charter (13 KB rendered with no
# brief) plus a full brief fits; anything larger is a lint problem upstream,
# not something to ship with every request of a session.
MAX_CHARS = 20_000

HEADER = """\
# Who you are

You are agent `{agent}` on host `{host}`, launched by agent-fabric holding
the role **{role}**. `bin/fabric-whoami` and `bin/fabric-status` (under
`agent-fabric/`, beside your working copies) are the authority on who you
are; the directory you stand in, the repository, the branch and this
session never are — changing directory changes your context, not your
name. Another login in the same working copy is another agent.

The role cannot change inside this session: it was bound before launch
(`bin/fabric-role`, from a login shell) and a different role is a
relaunch. What the role covers *in the project you are in* — its remit —
is not here: the session-start hook gives it to you, and it follows your
working copy.
"""

BRIEF_MISSING = "_No brief has been distilled for this role yet; the charter above is the whole definition._\n"


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _body(path: str) -> str:
    """A slice's markdown without its frontmatter, trailing newline kept."""
    text = FRONTMATTER_RE.sub("", _read(path), count=1)
    return text.strip("\n") + "\n"


# A locale's translation of the charter is rendered for a login whose name
# ends in that locale (language-culture-ge -> locale/ge/charter.md): the
# CEO's rule of 2026-09-17 that a holder who thinks in its language reads
# its own definition in it. Keyed by the login's suffix, not by role: a
# locale/ directory is an authored thing lint validates (a source digest,
# a lag finding), and with none present every role renders as before,
# byte-identical. A translation is served even when lint says it lags — a
# launch never fails on a day's lag; lint is where the lag is seen. The
# real cost is tokens, not characters: measured on the first Georgian
# charter, the rendering is about the characters of its English (11 041
# against 10 931) and 2.9x the tokens (7 584 against 2 642;
# docs/live-checks/2026-09-17-language-culture-bridge.md). The character
# ceiling therefore needs little headroom — LOCALE_CHARS_FACTOR times
# MAX_CHARS — and the token cost is the CEO's accepted price for the role.
LOCALE_CHARS_FACTOR = 1.35


def _charter_path(role_dir: str, agent: str) -> str:
    suffix = agent.rsplit("-", 1)[-1] if "-" in agent else agent
    locale = os.path.join(role_dir, "locale", suffix, "charter.md")
    return locale if os.path.isfile(locale) else os.path.join(role_dir, "charter.md")


def build(agent: str, host: str, role: str) -> str:
    """The prompt text for one (agent, host, role). Pure: reads the
    repository, touches nothing else."""
    role_dir = layout.role_dir(role)
    charter = _charter_path(role_dir, agent)
    if not os.path.isfile(charter):
        raise SystemExit(f"launch_prompt: role {role!r} has no charter at {charter}")
    localized = charter != os.path.join(role_dir, "charter.md")
    parts = [HEADER.format(agent=agent, host=host, role=role)]
    # The charter and the brief carry their own H1 ("<role> — charter",
    # "<role> — brief"); only a missing brief needs a heading of its own.
    parts.append(_body(charter))
    brief = os.path.join(role_dir, "brief.md")
    parts.append(_body(brief) if os.path.isfile(brief) else "# " + role + " — brief\n\n" + BRIEF_MISSING)
    for name in layout.PROMPT_TEMPLATES:
        path = layout.prompt_template_path(name)
        if not os.path.isfile(path):
            raise SystemExit(f"launch_prompt: {layout.root_rel(path)} is missing (tools/fabric/lint.py names it)")
        parts.append(_read(path).replace("{role}", role).strip("\n") + "\n")
    text = "\n".join(parts)
    ceiling = int(MAX_CHARS * LOCALE_CHARS_FACTOR) if localized else MAX_CHARS
    if len(text) > ceiling:
        raise SystemExit(f"launch_prompt: {len(text)} characters for role {role!r} exceeds {ceiling}; "
                         "shorten the charter or brief (tools/fabric/lint.py budgets them)")
    return text


def digest(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def render(out: str, agent: str, host: str, role: str) -> str:
    """Write the prompt for (agent, host, role) to `out` atomically and
    return its digest. The same idiom as identity.write_binding: a
    temporary file beside the target, then os.replace, so a launch that
    dies mid-write leaves the previous prompt intact rather than a torn
    one."""
    text = build(agent, host, role)
    directory = os.path.dirname(os.path.abspath(out)) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".launch-prompt-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, out)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    return digest(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="launch_prompt.py", add_help=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--out", help="write the prompt here and print its digest")
    group.add_argument("--print", action="store_true", help="render to stdout, write nothing")
    args = parser.parse_args(argv)

    agent = identity.current_agent()
    host = identity.current_host()
    binding = identity.read_binding(agent)
    role = binding.get("role")
    if not role:
        print(f"launch_prompt: agent {agent!r} has no active role binding; "
              "bind one first (bin/fabric-role bind <role>).", file=sys.stderr)
        return 1
    if args.print:
        sys.stdout.write(build(agent, host, role))
        return 0
    print(render(args.out, agent, host, role))
    return 0


if __name__ == "__main__":
    sys.exit(main())
