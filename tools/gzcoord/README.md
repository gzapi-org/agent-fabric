# GZCoord for GZAPP

GZCoord is a small, transport-agnostic, human-readable messaging protocol for autonomous software-development agents collaborating on the same Git/GitHub-governed project.

This directory is intentionally embedded in the GZAPP repository under `tools/gzcoord/`. It is not a second repository and it is not a source of authority for project state.

## Boundary

- **Git/GitHub** are authoritative for source, branches, commits, PRs, reviews, merges, conflicts, ADRs and history.
- **Repository `CLAUDE.md`** governs how agents operate on the repository.
- **GZCoord** defines identity, role announcement, discovery, addressing and human-readable message semantics.
- **Transport adapters** deliver messages. **No transport is currently selected** — the first attempt is retired (`history/telegram-transport/`) and the protocol is inactive until a replacement is chosen. The interface an adapter must satisfy is `docs/TRANSPORT-ADAPTER-CONTRACT.md`.
- **Local runtime config** contains model/provider and subagent policy; those values are not sent in messages.

## Identity

Every agent instance has the logical address:

```text
<host>/<instance>
```

Example:

```text
develop-gzapp/gzapp
```

The address is logical, but it is not arbitrary: `host` is the machine's short hostname and `instance` is the basename of the Git working copy the session started in and works in — one clone per session here, so the folder name *is* the session id (`protocol/SPEC.md` §3.1). The derivation runs one way. The address is still not a filesystem path, and no peer may reconstruct one from it or act outside its own working copy.

## Discovery

An agent self-defines its role by announcing `HELLO`:

```text
[GZCOORD/1] HELLO
FROM: develop-gzapp/gzapp
ROLE: Application Architect
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
FROM: develop-gzapp/backend
ROLE: Backend Engineer
TO: develop-gzapp/gzapp
TO-ROLE: Application Architect
PROJECT: gzapp
BRANCH: feature/stop-resolution
COMMIT: a81c142
SUBJECT: Stop resolution contract change

CONTEXT:
The passenger and advertising flows currently represent the resolved stop differently.

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

In a GZAPP deployment, `role.name`/`specialties` come from the role
this working copy currently holds under `.roles/` (see
`.roles/taxonomy.json`) — GZCoord keeps no separate role catalog; see
`runtime/README.md` "Role sourcing".

## Integration

1. Copy this directory to `gzapp/tools/gzcoord/`.
2. Add/reference `integration/CLAUDE.snippet.md` in the root repository `CLAUDE.md`.
3. Configure the concrete instance outside Git.
4. Configure the selected transport adapter.
5. Validate messages with `node tools/gzcoord/scripts/gzmsg.mjs validate <file>`.

See `docs/PROJECT-TREE.md` for the intended layout and `protocol/SPEC.md` for the normative protocol.
