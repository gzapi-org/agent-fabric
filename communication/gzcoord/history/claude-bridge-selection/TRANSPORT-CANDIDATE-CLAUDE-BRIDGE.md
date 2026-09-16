# Transport candidate — Claude Bridge

> Historical (2026-09-16): this candidate was selected and is the
> current transport; see `README.md` beside this file. The text below is
> the evaluation as written before the selection.

**Status: candidate, evaluated, not selected.** This records one
candidate against
[`TRANSPORT-ADAPTER-CONTRACT.md`](../../docs/TRANSPORT-ADAPTER-CONTRACT.md) so the
decision has something to stand on. Selecting a transport, and building
the adapter, belong to whoever owns the runtime surface — not to the
fabric-coordinator role (formerly gzcoord-coordinator), which owns the protocol the adapter carries.

Evaluated from the project's own documentation
(<https://github.com/constripacity/Claude-Bridge>), not from a running
deployment. Every "not verified" below means exactly that.

## What it is

A self-hosted relay that lets coding-agent sessions on different
machines exchange ordered messages through named channels. SQLite-backed,
with an MCP interface, a small JSON API, a dashboard and a terminal UI.
It calls no model API, and it needs neither a shared filesystem nor a
shared process between agents.

## Against the adapter contract

| contract | Claude Bridge |
|---|---|
| `connect()` / `disconnect()` | an MCP client attaches to the relay |
| `broadcast(text)` | write to a channel every instance reads |
| `send(peer, text)` | write to that peer's channel; point-to-point also available as a task queue where exactly one worker claims each item |
| `onMessage(sender, text)` | **pull, not push** — `bridge_wait` long-polls up to 55 seconds; the dashboard and TUI get server-sent events, an agent does not |
| native sender identity | **not provided.** The client supplies its own `sender` string, and authentication is one shared bearer token rather than a per-identity credential |
| broadcast reach | satisfied, by channel subscription |
| direct delivery | satisfied |
| reply context | native — message ids, `correlation_id`, thread ids |
| security, allowlist | a shared bearer token; TLS optional on the network listener; a local stdio mode binds no listener at all |
| loop prevention | idempotency keys for safe retries, at-least-once delivery with acknowledgement |
| adapter state | a durable consumer cursor per instance, held centrally in the relay's SQLite rather than locally |

## What it clears, and it is the one that matters

The first transport was not retired for its bot-to-bot limit. It was
retired because the way around that limit was to give each instance a
human's account, and an agent wearing a human identity can interact with
third parties while appearing to be one
([`../history/telegram-transport/`](../history/telegram-transport/README.md)).
That limit binds every candidate.

This one does not reach it. The relay is self-hosted, the identity an
instance carries is an agent's — a name like `mac-worker`, chosen by the
deployment — and no third-party human network is involved at any point.
There is no account for an agent to wear.

## What it does not provide, stated plainly

**A transport-native sender identity.** The contract asks for a stable
one "when the transport provides one", precisely so that a claimed
`FROM` is never what authenticates (SPEC §17; the same boundary the
adapter contract draws under "Security"). Here the transport's own
`sender` field is also a claim, and every instance holds the same bearer
token, so any instance can present any sender name.

That is not disqualifying, and it is not a defect in the candidate — it
is a property of a single-token relay. It means the deployment gets
delivery, not authentication, and the honest thing is to write that down
rather than let a later reader assume the adapter closed a gap it never
closed. A per-instance credential, if the project grows one, would close
it.

**Push.** A GZCoord session is not a daemon. The human relay's one real
advantage is that a pasted message arrives in the prompt whether or not
the session asked for it; a long poll means something has to decide when
to wait. That is the host-integration problem
[`CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md`](CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md)
already describes, and it is the substantial work here — not the wire
format, and not the relay itself.

## What the protocol needs: nothing

The addressing rules are already shaped for a filter that decides by
string equality, which is what a channel mapping is:

- `TO: <host>/<instance>` — one channel per instance.
- `TO-ROLE: <slug>` — one channel per catalogue slug (SPEC §4).
- `BROADCAST: true` — one channel every instance reads.

Exactly one of the three is present on any message (SPEC §7.1), so the
mapping is total and unambiguous, and a misaddressed message can be
dropped before delivery rather than read and discarded — the rule SPEC
§17 states for the recipient, enforced where it costs nobody's context.

`gzmsg.mjs normalize` becomes dead weight under any automated transport:
it exists to undo what a terminal copy does to a message. That it is
relay-specific, and nothing else is, is the evidence the relay-specific
parts were scoped correctly.

## The acceptance bar, unchanged and unmet

Two real instances, and instance B receives instance A's `HELLO`. The
retired transport failed exactly there and failed silently, because both
of its bootstrap validations passed without ever exercising that leg. No
amount of documentation substitutes for running it.

Until that is demonstrated, the current transport is the human relay
([`HUMAN-RELAY-TRANSPORT.md`](../../docs/HUMAN-RELAY-TRANSPORT.md)), and the three
activity claims named in [`../CLAUDE.md`](../CLAUDE.md) stay as they are.

## Not verified

- Anything about behaviour under load, ordering across channels, or loss.
  The wire grammar is frozen until an automated transport exercises it
  precisely because a human relay cannot test those.
- Whether `bridge_wait` can be driven from a Claude Code session without
  a supervising process, which is the question that decides whether this
  is a transport or a mailbox.
- The project's release maturity, licence and maintenance posture.
