# Claude Code Host Integration Prompt

Use this prompt on a real host after cloning this repository.

> **GZCoord is active over a human relay; no automated transport exists**
> (see [`../CLAUDE.md`](../CLAUDE.md) and
> [`HUMAN-RELAY-TRANSPORT.md`](HUMAN-RELAY-TRANSPORT.md)). This prompt is
> therefore the brief for whoever builds the automated transport, not a task
> anyone can complete today: step 3 of the goal and the whole live-validation
> section need an adapter that does not yet exist. The first automated
> attempt is retired in
> [`../history/telegram-transport/`](../history/telegram-transport/README.md);
> read it for what went wrong before designing the next one.

---

You are implementing the host/runtime integration for the GZCoord protocol contained in this repository.

Read first, in this order:

1. `CLAUDE.md`
2. `protocol/SPEC.md`
3. `protocol/SEMANTICS.md`
4. `runtime/README.md`
5. `docs/TRANSPORT-ADAPTER-CONTRACT.md`
6. `config/instance.example.yaml`

The architecture is already decided. Do not redesign it into a coordination database, ownership system, task tracker, lock service, or Git abstraction.

## Non-negotiable boundaries

- Git/GitHub and each project repository remain the exclusive authority for code, branches, commits, PRs, reviews, merges, conflicts, ADRs and durable project state.
- GZCoord is a human-readable messaging protocol only.
- Logical agent addresses are `host/instance`.
- Roles are self-declared through HELLO and are not centrally enumerated.
- Model/provider and subagent policy are local instance configuration and must not appear in GZCOORD/1 messages.
- A transport is an adapter, not part of the core protocol.
- Do not add SQLite, PostgreSQL, Redis, a durable peer registry, ownership tables, message workflow states, or a task database.
- Do not fork or patch a third-party transport client unless a proven blocker is documented and explicit approval is obtained.

## Goal

Create the thinnest practical Claude Code host integration that lets multiple instances on the same machine:

1. load their local YAML configuration;
2. use their configured model/runtime outside the protocol;
3. start with a distinct per-instance transport identity and state directory;
4. publish a GZCOORD/1 HELLO automatically or through a simple startup action;
5. receive HELLO messages and maintain an in-memory peer directory;
6. re-announce HELLO once when a previously unknown peer appears, with jitter/cooldown;
7. send human-readable GZCOORD/1 messages to a concrete address or role;
8. include current Git branch/commit only as message context when useful;
9. use existing Git/GitHub tools for any actual repository work;
10. respect the target project's CLAUDE.md before acting on incoming messages.

## Choosing the transport

No automated transport is selected; a human relay carries traffic meanwhile.
Choosing the automated one is the first task, and it is a transport
decision, not a protocol one (`protocol/SPEC.md` §14) — the wire
grammar does not change to accommodate a carrier.

The candidate must satisfy `docs/TRANSPORT-ADAPTER-CONTRACT.md`, and the
one property to establish **before** building anything on it is
**agent-to-agent delivery**: instance B must be able to receive a message
that instance A sent. The retired Telegram attempt failed exactly here, and
failed silently — its two bootstrap validations both passed because neither
exercised that leg. Establish it first, with two real instances.

Per-instance isolation is a requirement of the contract: each instance gets
its own transport identity and its own state directory, never a shared one.

The identity the transport gives an instance must be an agent's, not a
human's. Telegram offered a working route around its bot-to-bot rule — user
accounts — and it was refused because an agent under a human-style identity
can pass as a human to third parties (see the retirement record). A
candidate whose only agent-to-agent path runs through human identities fails
on that ground before delivery is even measured.

Do not ask me to paste credentials into chat. Use protected local
files/environment configuration.

## Implementation preference

Prefer composition over new infrastructure.

A small skill, hook, launcher script, local helper, or MCP convenience tool is acceptable if necessary. Keep persistent data out of the design. The peer directory must be in memory and reconstructable from HELLO.

Use the existing `scripts/gzmsg.mjs` parser/formatter where useful instead of introducing a second wire-format implementation.

## Required checks

Before changing anything, inspect:

- installed Claude Code version;
- installed Bun/Node versions;
- the chosen transport client's version and its current access-configuration contract;
- existing project CLAUDE.md files;
- existing MCP/hooks/settings so they are merged rather than overwritten.

## Required live validation

With two configured instances, prove:

1. A starts and publishes HELLO.
2. B receives A's HELLO.
3. B re-announces once and A learns B.
4. No HELLO loop occurs.
5. A sends an OBSERVATION or REVIEW to B.
6. B receives it as readable GZCOORD/1 text.
7. B can reply.
8. Current branch/commit context comes from Git, not local routing configuration.
9. Changing the local model does not change address or wire message structure.
10. Restarting a process rebuilds the peer directory through HELLO without loading a durable registry.

Validation 2 — B receives A's HELLO — is the one that matters most and the
one the retired transport could never pass. A validation suite that does not
put **two instances** in the channel and watch one receive the other's HELLO
proves nothing about the case the protocol exists for.

If broadcast HELLO cannot be made reliable on the chosen transport, document
the exact limitation and propose the smallest transport-adapter fallback. Do
not alter the core protocol to solve a transport-specific limitation.

## Deliverables

- host integration scripts/configuration;
- exact setup commands;
- no secrets committed;
- tests for HELLO parsing, peer cache, cooldown/loop prevention, direct routing and role routing;
- live validation report;
- concise list of any transport-specific limitations.

At completion, verify that no implementation artifact has accidentally introduced a second source of project authority.
