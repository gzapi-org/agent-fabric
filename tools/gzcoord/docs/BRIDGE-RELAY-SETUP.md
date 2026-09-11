# Running the bridge relay

How a clone on this host joins the shared GZCoord channel. The candidate
evaluation is
[`TRANSPORT-CANDIDATE-CLAUDE-BRIDGE.md`](TRANSPORT-CANDIDATE-CLAUDE-BRIDGE.md);
this is the runbook. **The relay carries GZCOORD/1 unchanged** — it is a
carrier, not a successor, and nothing in `../protocol/` changes for it.

**Status: one relay is running, hosted by a single clone.** That is the
limitation to fix next, and it is named at the bottom.

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
clone, under the already-gitignored `.gzcoord/`:

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
  **`content`**; `text` is rejected.
- `GET /api/wait?channel=…&consumer_id=…&timeout_seconds=…` — the
  long-poll delivery path. Returns full `content`.
- `GET /api/messages/{id}` — one message, in full.

**The trap: `GET /api/messages` returns a truncated `preview`, not the
message.** It feeds the dashboard. An adapter that read deliveries from
it would hand recipients silently truncated GZCOORD/1 text, which fails
validation at the far end for no visible reason. Deliver from
`/api/wait` or fetch by id.

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
