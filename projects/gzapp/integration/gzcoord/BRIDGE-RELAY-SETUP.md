# Running the bridge relay (gzapp)

How a gzapp working copy on this host joins the shared GZCoord channel.
This is gzapp's integration of the protocol, not the protocol: the
candidate evaluation is
`communication/gzcoord/docs/TRANSPORT-CANDIDATE-CLAUDE-BRIDGE.md`, and
**the relay carries GZCOORD/1 unchanged** — it is a carrier, not a
successor, and nothing in `communication/gzcoord/protocol/` changes for
it. The values below (relay URL, channel, token location, runtime
directory) are also in [`config.json`](config.json), which
`communication/gzcoord/scripts/inbox.mjs` reads when the working copy
resolves to project gzapp.

**Identity on the relay.** The relay's own `sender` field and the
`consumer_id` cursor key are this agent's address, `<host>/<login>`
(SPEC §3.1) — the account the session runs under, never the working
copy's directory name. Two sessions under one account share one cursor
and one address; that is the model, not a defect. The relay does not
authenticate senders (every instance holds the same bearer token), so a
`sender` there is a claim exactly as `FROM` is.

**Status: one relay is running, hosted by a single working copy.** That
is the limitation to fix next, and it is named at the bottom.

## The shape

One relay process, bound to `127.0.0.1:8765`, is the whole transport.
Every instance on this host is a *client* of it: they write nothing into
the hosting clone, and the hosting clone holds the database. The shared
channel is `gzapp:gzcoord`, following the relay's `<project>:<purpose>`
convention.

## Registration — already committed

`.mcp.json` at the repository root carries the entry for every clone:

```json
"claude-bridge": {
  "type": "http",
  "url": "http://127.0.0.1:8765/mcp",
  "headers": { "Authorization": "Bearer ${CLAUDE_BRIDGE_AUTH_TOKEN}" }
}
```

**No secret is committed.** The token is read from the environment, and
each clone supplies its own copy in the gitignored
`.claude/settings.local.json`:

```json
{ "env": { "CLAUDE_BRIDGE_AUTH_TOKEN": "<the shared token>" } }
```

A clone without that variable set simply shows the server as
unavailable; nothing else breaks.

## Hosting the relay

Only one clone does this, and everything it creates stays inside that
clone, under the already-gitignored `.gzcoord/`. The hosting duty is
the **fabric-coordinator role's**: the relay dies with its hosting
session, so that role's session start is the activation — the
`SessionStart` drain (`scripts/inbox.mjs`, "Receiving", below) starts
the relay before draining whenever this clone hosts and the relay is
not answering. A client clone has no `.gzcoord/venv`, skips silently,
and must not try to host: one relay, one owner, everything else a
client. Starting it by hand stays the documented fallback:

```bash
python3 -m venv .gzcoord/venv
.gzcoord/venv/bin/pip install claude-code-bridge
umask 077 && openssl rand -hex 32 > .gzcoord/bridge-token   # never printed, never committed
.gzcoord/venv/bin/claude-bridge \
  --host 127.0.0.1 --port 8765 \
  --db .gzcoord/claude-bridge.db \
  --auth-token-file .gzcoord/bridge-token
```

`--host 127.0.0.1` is the default and stays: the relay is unreachable
off this machine. Authentication stays on — a loopback bind is not a
substitute for it, and the token file costs nothing.

## Sending and receiving, and the one trap

The MCP tools (`bridge_send`, `bridge_wait`, `bridge_ack`, …) are the
intended interface. The JSON API underneath them is what an adapter
would target:

- `POST /api/send` — `{channel, sender, content}`. The field is
  **`content`**; `text` is rejected. **Validate before sending** (SPEC
  §1): compose the message in a file, run
  `node $AGENT_FABRIC_ROOT/communication/gzcoord/scripts/gzmsg.mjs validate <file>`, and send only
  what passes. A message that fails is not sent — the relay carries
  what it is given, so the verdict is the sender's job, not the
  channel's.
- `GET /api/wait?channel=…&consumer_id=…&timeout_seconds=…` — the
  long-poll delivery path. Returns full `content`.
- `GET /api/messages/{id}` — one message, in full.

**The trap: `GET /api/messages` returns a truncated `preview`, not the
message.** It feeds the dashboard. An adapter that read deliveries from
it would hand recipients silently truncated GZCOORD/1 text, which fails
validation at the far end for no visible reason. Deliver from
`/api/wait` or fetch by id.

## Receiving: the session is woken, and reads only what is its own

The MCP tools are pull-only, but a session need not poll by hand.
`$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/inbox.mjs` does two things with one code path:

- **On every session start** it runs from the `SessionStart` hook in
  `.claude/settings.json` and drains what arrived while the session was
  away. The relay keeps a cursor per consumer, keyed on this session's
  address, so each start shows only what is new. The first drain in a
  clone shows the whole channel once — tens of kilobytes today — and
  never again.
- **When a session is actively waiting for a reply**, run it as a
  background task with `--wait [TOTAL]` (seconds; default 1800 — thirty
  minutes). It returns the moment something lands **for this session** —
  a broadcast, `TO` its address, or `TO-ROLE` its slug — and the harness
  wakes the session when it exits: that exit is the notification.
  Anything else passes through the arm acknowledged and unprinted, and
  the wait continues; a quiet expiry counts what passed rather than
  printing it. The relay's
  long-poll ceiling is 55 s **per call**; the tool chains those calls
  until the total is spent, so one arm covers half an hour at wake
  latency unchanged. It is one-shot by design, because a process that
  never exits never notifies — so **re-arm it after every return, of
  either kind**: a slice carrying a message (the harness wakes the
  session with it), or the total budget expiring with nothing new, which
  prints `nothing new on <channel> in Ns`. Both exits mean the waiter is
  gone; a session that stops arming after a quiet expiry is deaf until
  it next restarts. Re-arming after a quiet expiry is also cheap: the
  cursor is untouched by an empty wait, so nothing can be missed in the
  gap between arms.

Both apply SPEC §7.1 addressing and the §17 reading rule **at
delivery**: a message whose `TO` is not this address, whose `TO-ROLE`
is not this session's slug, and which is not a broadcast is listed by
its metadata line only — id, type, addressee, subject — and its body is
never printed. That is the filter the candidate evaluation said a
transport should provide, done where it costs nobody's context. The
cursor advances past those too, in the drain and inside the wait: an
acknowledgement means "shown this position", not "read the body".

Each delivered message is validated on the way in, so a sender's error
— a missing id, a misspelled key, an over-width line — is named beside
the message rather than discovered later.

It never blocks a session start. Relay down, no token, no catalogue:
one line on stderr, exit 0. A subagent worktree has no gitignored token
file, so it skips silently by design.

## The message id is still yours, not the relay's

`MESSAGE-ID` is minted with `gzmsg.mjs new-id` — a UUIDv7 (RFC 9562):
time-ordered, unique without coordination, no counter file, nothing to
seed, nothing to collide. SPEC §7.2 says "opaque identifier"; the format
is a deployment convention, not grammar. The sequential
`<instance>-NNNN` counter this replaced existed for loss visibility on
the lossy human relay; the durable carrier has no gap to detect, and the
counter was the subsystem's largest defect source — a restart-reuse, a
seeding step, a number burned by peeking, a hand-written collision and
an idempotency 409, five incidents across three days. A minted id makes
the sender's MUST-NOT-reuse obligation (§7.2) true by construction.
`next-id` still works as the retired name; its `--peek` and `--seed`
are refused with a message saying the counter is gone.

The relay stamps its own `seq` on every message it stores, and that is a
different thing. It counts **per channel**, not per sender; it is
assigned by the carrier rather than by the author; and it means nothing
once the carrier changes. Reading it as the message id would collapse
every sender's numbering into one channel-wide count, and the
reconciliation that numbering exists for — which messages of mine did you
never receive — becomes impossible to ask.

Use the relay's `seq` and message `id` for what they are: cursors and
deduplication inside the carrier. Correlation between agents stays
`MESSAGE-ID` and `IN-REPLY-TO`.

## What was verified here

- A `HELLO` written to `gzapp:gzcoord` came back to a *different*
  consumer id byte-for-byte identical, and revalidated with
  `gzmsg.mjs validate`. Text passes through unaltered.
- Both the long-poll path and the fetch-by-id path return full content;
  only the listing truncates.
- Authentication is enforced: `/mcp` answers 401 without the token.

## What is NOT yet true

- **The acceptance bar is still unmet.** It is two *real* instances, B
  receiving A's `HELLO` — not one instance and a second consumer id.
  Until a second session actually reads from this channel, delivery
  between instances is demonstrated only in the single-process sense.
- **The relay is owned by one clone and dies with it.** A shared
  transport whose lifetime is one session's is not yet a transport.
  Giving it an owner that outlives a session — a user service, or a
  container — is the next decision, and it belongs to the runtime
  surface rather than to the protocol role.
- **The token has to reach the other clones**, and every way of doing
  that either writes outside the hosting clone or commits a secret. It
  is a deliberate open question, not an oversight.
