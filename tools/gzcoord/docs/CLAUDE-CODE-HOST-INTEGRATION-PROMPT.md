# Claude Code Host Integration Prompt

Use this prompt on a real host after cloning this repository.

---

You are implementing the host/runtime integration for the GZCoord protocol contained in this repository.

Read first, in this order:

1. `CLAUDE.md`
2. `protocol/SPEC.md`
3. `docs/architecture.md`
4. `runtime/README.md`
5. `adapters/telegram/README.md`
6. `config/instance.example.yaml`

The architecture is already decided. Do not redesign it into a coordination database, ownership system, task tracker, lock service, or Git abstraction.

## Non-negotiable boundaries

- Git/GitHub and each project repository remain the exclusive authority for code, branches, commits, PRs, reviews, merges, conflicts, ADRs and durable project state.
- GZCoord is a human-readable messaging protocol only.
- Logical agent addresses are `host/instance`.
- Roles are self-declared through HELLO and are not centrally enumerated.
- Model/provider and subagent policy are local instance configuration and must not appear in GZCOORD/1 messages.
- Telegram is an adapter, not part of the core protocol.
- Do not add SQLite, PostgreSQL, Redis, a durable peer registry, ownership tables, message workflow states, or a task database.
- Do not fork or patch the official Claude Code Telegram plugin unless a proven blocker is documented and explicit approval is obtained.

## Goal

Create the thinnest practical Claude Code host integration that lets multiple instances on the same machine:

1. load their local YAML configuration;
2. use their configured model/runtime outside the protocol;
3. start with a distinct Telegram bot/state directory;
4. publish a GZCOORD/1 HELLO automatically or through a simple startup action;
5. receive HELLO messages and maintain an in-memory peer directory;
6. re-announce HELLO once when a previously unknown peer appears, with jitter/cooldown;
7. send human-readable GZCOORD/1 messages to a concrete address or role;
8. include current Git branch/commit only as message context when useful;
9. use existing Git/GitHub tools for any actual repository work;
10. respect the target project's CLAUDE.md before acting on incoming messages.

## Telegram first

Use the official `telegram@claude-plugins-official` plugin.

There must be one bot token and one `TELEGRAM_STATE_DIR` per Claude Code instance.

For the dedicated private coordination supergroup, validate the discovery configuration described in `adapters/telegram/README.md`:

- Bot-to-Bot Communication Mode;
- participating bots in the same private supergroup;
- receiving bots configured as required for ordinary bot messages;
- Group Privacy Mode disabled where necessary for broadcast HELLO;
- official plugin group configured `--no-mention`;
- numeric sender allowlist restricted to participating bots and approved humans.

Do not ask me to paste tokens into chat. Use protected local files/environment configuration.

## Implementation preference

Prefer composition over new infrastructure.

A small skill, hook, launcher script, local helper, or MCP convenience tool is acceptable if necessary. Keep persistent data out of the design. The peer directory must be in memory and reconstructable from HELLO.

Use the existing `scripts/gzmsg.mjs` parser/formatter where useful instead of introducing a second wire-format implementation.

## Required checks

Before changing anything, inspect:

- installed Claude Code version;
- installed Bun/Node versions;
- official Telegram plugin version and its current access configuration contract;
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

If broadcast HELLO cannot be made reliable with the official plugin, document the exact Telegram/plugin limitation and propose the smallest transport-adapter fallback. Do not alter the core protocol to solve a Telegram-specific limitation.

## Deliverables

- host integration scripts/configuration;
- exact setup commands;
- no secrets committed;
- tests for HELLO parsing, peer cache, cooldown/loop prevention, direct routing and role routing;
- live validation report;
- concise list of any transport-specific limitations.

At completion, verify that no implementation artifact has accidentally introduced a second source of project authority.
