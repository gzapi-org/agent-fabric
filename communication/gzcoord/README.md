# GZCoord

GZCoord is a small, transport-agnostic, human-readable messaging protocol for autonomous software-development agents collaborating on the same Git/GitHub-governed project.

This directory is agent-fabric's communication subsystem (`communication/gzcoord/`): the protocol, its reference runtime and tests. It is not a source of authority for any project's state. Project-specific integration — how one managed repository hosts a relay, what its `CLAUDE.md` says, how it installs the hooks — lives with that project under `projects/<project-id>/integration/gzcoord/`.

## Boundary

- **Git/GitHub** are authoritative for source, branches, commits, PRs, reviews, merges, conflicts, ADRs and history.
- **A message is never committed.** The channel is coordination, not
  record: a `MESSAGE-ID` may be *cited* in a commit or PR body, but the
  messages themselves stay out of the repository — the durable,
  ordered record is the relay, and committing chatter would make every
  message a blocking artifact while 14 sessions collide on one file.
  What a message *decides* is not decided until it lands in the
  artifact it concerns — the PR body, the commit body, the contract's
  `change_summary`, the ADR — citing the id. A decision that lives only
  on the channel is a decision nobody can hold.
- **Repository `CLAUDE.md`** governs how agents operate on the repository.
- **GZCoord** defines identity, role announcement, discovery, addressing and human-readable message semantics.
- **Transport adapters** deliver messages. **The current transport is a Claude-Bridge relay** hosted on the developer host by the fabric-coordinator's working copy (a project's integration says where: `projects/<id>/integration/gzcoord/`), drained at session start by `scripts/inbox.mjs`; when the relay is down, a person copies messages between session terminals (`docs/HUMAN-RELAY-TRANSPORT.md`). The first automated attempt before the relay is retired (`history/telegram-transport/`). The interface an automated adapter must satisfy is `docs/TRANSPORT-ADAPTER-CONTRACT.md`.
- **Local runtime config** contains model/provider and subagent policy; those values are not sent in messages.

## Identity

Every agent instance has the logical address:

```text
<host>/<instance>
```

Example:

```text
develop-gzapp/architect-cto
```

The address is logical, but it is not arbitrary: `host` is the machine's short hostname and `instance` is the login of the operating-system account the session runs under — the agent, as agent-fabric's `runtime/identity.py` resolves it (`protocol/SPEC.md` §3.1). The working copy the session is in is context, never identity: rename it, move it, or open another project and the address stays. The derivation runs one way. The address is not a filesystem path or a home directory, and no peer may reconstruct one from it or act outside its own working copy.

## Discovery

An agent self-defines its role by announcing `HELLO`:

```text
[GZCOORD/1] HELLO
FROM: develop-gzapp/architect-cto
ROLE: architect-cto
PROJECT: gzapp
SPECIALTIES: architecture, ADR, contracts, system design
CAPABILITIES: github, code-review, repository-analysis

ABOUT:
I review architectural consistency, cross-component contracts and design decisions.
```

There is no authoritative role registry. Peers may keep an ephemeral routing cache learned from `HELLO` traffic.

## Normal message

```text
[GZCOORD/1] REVIEW
FROM: develop-gzapp/backend-dev
ROLE: backend-dev
TO: develop-gzapp/architect-cto
PROJECT: gzapp
BRANCH: feature/stop-resolution
COMMIT: a81c142
SUBJECT: Stop resolution contract change

CONTEXT:
The passenger and advertising flows currently represent the resolved
stop differently.

REFERENCES:
- github-pr: #184
- path: contracts/common/stop-resolution.yaml

REQUEST:
Please review the architectural impact before merge.
```

The message is parseable, but it remains readable without tooling.

## Local configuration

Copy `config/instance.example.yaml` outside Git, e.g. to:

```text
~/.config/gzcoord/gzapp.yaml
```

Model/provider, subagent limits and transport credentials are local execution details. They are not part of GZCOORD/1.

`role.name`/`specialties` come from the role the agent currently holds
(its runtime binding; slugs from agent-fabric's
`identities/roles/catalog.json`) — GZCoord keeps no separate role
catalog; see `runtime/README.md` "Identity sourcing" and "Role sourcing".

## Integration

1. Keep this directory where it is: agent-fabric is the control plane, and every managed repository uses the same copy.
2. Add the project's snippet to its root `CLAUDE.md` — gzapp's is `projects/gzapp/integration/gzcoord/CLAUDE.snippet.md`.
3. Configure the concrete instance outside Git.
4. Configure the selected transport adapter (gzapp's relay: `projects/gzapp/integration/gzcoord/BRIDGE-RELAY-SETUP.md`).
5. Validate messages with `node communication/gzcoord/scripts/gzmsg.mjs validate <file>`.

See `docs/PROJECT-TREE.md` for the layout and `protocol/SPEC.md` for the normative protocol.
