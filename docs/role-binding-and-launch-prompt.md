# Role binding and the launch prompt — what changed on 2026-09-15

A note under `docs/` because a concept moved, not only a file: **how a
session comes to hold its role.**

## Before

A session bound its own role from inside the harness with `/role
<role>`, a slash command `bootstrap.sh` installed into every account.
The command wrote the binding and printed a "load now" list — the
charter, the project's index and workflow slices — which the model was
then asked to Read. Three things were wrong with that in practice:

- it depended on the model obeying an instruction printed into its
  context, and on nobody compacting that context away;
- a role could be switched under a running session, so what the session
  believed it was and what its binding said could disagree, silently;
- nothing said what a session had been *launched* as, so the drift was
  invisible even to `fabric-status`.

The same shape had already bitten once that day in another dimension: a
session launched on the previous session default kept it for hours after
the default changed, because a session's model is fixed at exec and
nothing distributes a new default to a running process.

## After

**A role is bound from a login shell, never inside a session.**
`bin/fabric-role bind <role>` (wrapping `tools/fabric/role.py`) writes
the binding and installs the role's skills into the workspace; it refuses
to run when the environment says a session is running (`CLAUDECODE`,
`CLAUDE_ENV_FILE`, `AGENT_FABRIC_LAUNCH_PROFILE`), and so does the Python
underneath it, so a Bash tool call that names the file is refused too.
`status` and `list` run anywhere. The `/role` command is deleted and
`bootstrap.sh` removes the copy it once installed.

**The role rides in the system prompt.** `runtime/openrouter/launch`
renders, for the bound role, `$STATE_DIR/launch-prompt.md`
(`tools/fabric/launch_prompt.py`) and passes it to claude as
`--append-system-prompt-file` on both launch paths, plain and broker
(read back live, print and interactive:
`live-checks/2026-09-15-append-system-prompt.md`). The session therefore
holds its role from its first request, through every compaction, and
cannot edit it. The file is byte-stable for the same (agent, host, role)
— no timestamps, no cwd — so the harness's prompt prefix stays cacheable
and a changed digest means changed content. The launcher stamps
`AGENT_FABRIC_LAUNCH_ROLE` and `AGENT_FABRIC_LAUNCH_PROMPT_DIGEST`, and
sends the GZCoord `HELLO` just before exec: a `HELLO` now means a
session exists. A caller's own `--system-prompt*` is refused as
`--settings` is.

**What the prompt carries, in order:** an identity header (agent, host,
role; `bin/fabric-whoami`/`fabric-status` are the authority, the
directory never is; a different role is a relaunch), the role's
**charter**, its **brief**, and two sections every role shares —
`identities/prompt/team.md` (the team's operating rules on top of the
advisory protocol: every message is someone else's job too;
`REPLY-EXPECTED: yes` is always answered; without it, reply only to add
something useful; the lane rule; handovers name their artifact; the
control plane is read-only) and `identities/prompt/memory.md` (the three
places knowledge lives, the exact frontmatter of a memory the drain
takes, the cadence, correction-by-memory for a stale slice).

**What the prompt does not carry: the project.** The remit
(`<working copy>/.agent-fabric/roles/<role>.md`) and the pointer to the
role's `INDEX.md` follow the working copy, which a session changes with
`cd`; they reach the session from the SessionStart hook as
`additionalContext`, at start, on resume and after every compaction,
from the cwd of the moment. The filesystem is context, never identity.

**Drift is said.** `bin/fabric-status` prints `launched as <role>` and a
`DRIFT` line when the binding, the session default or the prompt file
moved under the running session; the session-start hook prints the role
drift at each of its runs. A rebind under a session is never silent.

## Brief versus remit

The **brief** (`identities/roles/<role>/brief.md`, class `brief`, tier 1)
is the third authored role file, beside the charter and the recall guide:
how the role works day to day, in *any* project — who it is, the kind of
thing it knows, its line with each other role, the kind of source it
reads first. It is written without identifiers: no pull request, decision
record, migration or message number, no repository path, no product the
project chose; the stack the role is defined by may be named. It lives
only under `identities/roles/`, is exempt from `derived_from` like the
charter, is refused as a drain target, is listed by the assembler in
every project index, and is `fabric-coordinator`'s to write under the
charter-authority guard.

The **remit** (`.agent-fabric/roles/<role>.md` in the project) carries the
anchored version — the same subjects with their paths, records and pull
requests, the project's concrete lines between roles, and the project's
own read-first sources.

Both were written from the accounts the roles gave of their own work, in
reply to a broadcast (`01a0a594-3719-76b1-97d6-fb8c67e520fd`,
2026-09-15): one sentence went to the brief when it would be true
anywhere, to the remit when it was anchored, and to neither when it was
a wish for something not yet written down — those are a backlog for the
roles that own the surfaces. The replying agents are named in each
file's `origin`. A role with no reply has no brief; the launcher's
placeholder line stands until one is written under the same rule.
