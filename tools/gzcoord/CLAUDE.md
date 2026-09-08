# CLAUDE.md — tools/gzcoord

The GZCoord agent communication protocol. The root [`/CLAUDE.md`](../../CLAUDE.md)
covers repo-wide rules; this file covers the state of this subsystem, and the
state is the first thing you need to know about it.

## GZCoord is INACTIVE

**No transport is selected. No session communicates over GZCoord. Nothing in
this directory is running.**

Treat everything here as a specification and a reference implementation on the
shelf, not as a system in operation. Concretely:

- **Do not** wire a session to it, announce a `HELLO`, or act as though a peer
  might answer. Nothing is listening.
- **Do not** read a claim that the repository "uses GZCoord" as current — if
  you find one anywhere, it is stale and should be corrected.
- Sessions coordinate through `origin` alone: git, GitHub, PRs and reviews.
  That was always the authoritative channel (`protocol/SPEC.md` §2) and it is
  now the only one.

## What is still true

The protocol itself was never the problem, and it is not abandoned:

- `protocol/SPEC.md`, `MESSAGE-FORMAT.md`, `SEMANTICS.md` and `CONFORMANCE.md`
  remain the wire contract, and remain valid.
- `scripts/gzmsg.mjs` — the parser, validator and `hello` generator — still
  works and is still tested. Its suite runs in CI on every change under
  `tools/gzcoord/**`, so the implementation stays honest while dormant.
- `docs/TRANSPORT-ADAPTER-CONTRACT.md` is the transport-independent interface
  a future adapter must satisfy. It never named a specific transport.

## What is retired

Telegram was the first transport and is retired
([`history/telegram-transport/`](history/telegram-transport/README.md)).
It could not carry instance↔instance traffic at all: Telegram bots never
receive messages from other bots regardless of privacy mode, so no instance
ever saw another's `HELLO`. The archived documents are history, not
instruction — do not follow them.

The bot-to-bot rule is the obstacle; it is not the reason. There was an
obvious way around it — a full user account per instance instead of a bot —
and it would have worked. It was refused on purpose: an agent holding a
human-style identity can interact with third-party humans while appearing to
be one, by design or by mistake, and no message bus is worth that. The
technical limit reads as something to engineer around. The impersonation
limit is the one that binds, and it binds any transport, not only this one.

The replacement is a new **transport**, designed for agent-to-agent delivery
from the start rather than a chat network adapted to it. It is a carrier for
GZCOORD/1, not a successor to it: the wire contract above is unaffected, and
building the transport does not mean redesigning the grammar the
gzcoord-coordinator role owns. Designing it is the open task;
[`docs/CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md`](docs/CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md)
is the brief.

## Reactivating it

Reactivation needs a **transport decision first** — there is nothing to switch
on until an adapter exists that demonstrably delivers a message from one
instance to another. When that changes, the claim of activity must be updated
in this file, in [`integration/CLAUDE.snippet.md`](integration/CLAUDE.snippet.md),
and in the root `CLAUDE.md` §"Agent communication (GZCoord)" together, or the
tree will disagree with itself again.

## Authority over the spec

Unchanged by dormancy: the **gzcoord-coordinator** role
([`.roles/gzcoord-coordinator/`](../../.roles/gzcoord-coordinator/charter.md))
is the only role that changes `protocol/*`. Other sessions may propose changes
and route them through that role rather than editing the spec directly.
