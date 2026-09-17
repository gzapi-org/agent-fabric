# The control plane: a daemon per account, a channel on the relay, `fabric-ctl`

Decided by the CEO on 2026-09-17, after the first fleet usage table was
made by hand and the second (`bin/fabric-usage`) could only be made by
the coordinator's login, through sudo, one host at a time: "we have to
extend it really as a real time control plane — when a message is
received by a process on the agent, it will answer with the required
data." What "received" means there is the whole design.

## What "received" means on the control channel

**A daemon, never a session.** Every account runs
`runtime/control/agentd.mjs` under a systemd *user* unit
(`runtime/control/agent-fabric-agentd.service`, installed and enabled by
`bootstrap.sh` at every moveto entry). It is alive whether or not a
Claude session is: the account lingers (`docs/live-checks/2026-09-17-control-plane.md`
§persistence), so its user manager exists from boot. A request reaches
the daemon, the daemon reads what the account can say about itself
(`runtime/control/ops.mjs`), and posts the answer. No harness, no model,
no prompt, no sudo is in the loop, and nothing a request carries is ever
executed: the ops are a closed enum and take no arguments.

**A channel no session drains.** The records ride the same relay as the
fleet's GZCoord traffic (the coordinator workspace's `projects/.gzcoord/`),
on a channel of their own, `fabric:control` (`runtime/control/config.json`).
They are not GZCOORD/1 messages — one JSON object per relay message — and
the inbox runtime refuses any channel whose name ends in `:control`
(`inbox.mjs`, `send.mjs`: exit 2, nothing read or sent), so a session's
watch cannot be pointed at machine records by mistake, and the protocol
that sessions coordinate over stays exactly what it was
(`communication/gzcoord/protocol/`: the grammar is frozen, and this is
not a message type).

**No delivery, only reading.** The relay has no point-to-point delivery:
every reader sees every record on a channel. Addressing is by
convention — `to` is an address, a list, or `*` — and each daemon answers
only what names it; the coordinator reads the replies by `in_reply_to`.
The daemon keeps no consumer cursor and never acks: it primes from the
newest record on the channel at start and long-polls after it
(`since_id`), so a restart never replays history and a request posted
while a daemon was down is simply not answered — which `fabric-ctl`
reports as a `no answer` row, never as a short table.

## The wire

```json
{"v":1,"kind":"request","id":"<uuidv7>","from":"<host>/<login>","to":"*","op":"status","ts":"<iso>","ttl_s":30}
{"v":1,"kind":"reply","id":"<uuidv7>","in_reply_to":"<request id>","from":"<host>/<login>","op":"status","ts":"<iso>","ok":true,
 "data":{"identity":{...},"usage":{...},"keys":[...],"fabric":{...},"session":{...},"agentd":{"pid":1,"started":"<iso>","uptime_s":1}}}
```

Ops: `ping`, `identity` (agent, host, role, project, working copy, the
Claude account signed in — email and organisation from the harness's own
profile record — and whether a credentials file exists), `usage` (the
five-hour and seven-day windows, read with the account's own OAuth
token, which goes into one request header and nowhere else), `keys`
(name, presence and twelve hex digits of the sha256 of each synced key —
enough to tell two keys apart, never a value), `fabric` (head, branch,
how far behind `origin/main`, dirty), `session` (Claude processes as the
login; whether one is planning), `script` (the letters of the account's
own notes — `${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/notes/`,
which the language-culture charter requires in the locale's language —
and of its session records, visible text and stored thinking apart,
counted by Unicode script over the last 24 h and binned per paragraph
or block: the signature of the language a holder works in, asked for by
the CEO for that role; counts and shares only, never text, and not part
of `status` since it reads megabytes. The reasoning itself is not on
disk — most thinking blocks are stored with no text and the rest as
short summaries — which is why the notes are the signature and the
transcript's text share the second number. `workers`, in the same
reply: the locale worker's transcripts — the subagent records stored
beside each session, `<session>/subagents/agent-*.jsonl`, of which the
worker's are the ones whose sidecar `agent-*.meta.json` says
`agentType: locale-worker`; every other subagent is counted, not read.
Its user records are the worker's input, composed by the bridge — less
the `<system-reminder>` spans the harness injects into every subagent —
so a Latin paragraph there is English that reached the worker, the leak
the construction of `docs/language-culture-bridge.md` exists to prevent;
its text blocks are the answers; a `tool_use` other than the hand-back
is `tool_uses`. Both binned per paragraph like the notes), `memory` (the drain: the
account's own daemon runs `tools/fabric/harvest_memory.py --bundle`
over each memory directory the harness keeps for it, matched to the
working copy it was written from by slug, and answers with each bundle
gzipped and base64 in follow-up records of at most 90 KiB — the relay's
message limit is 128 KiB — after a first record carrying the sizes, the
sha256 of every tar and the harvest report: claims, `needs_rendering`,
the skipped names. The way out of god mode (the CEO, 2026-09-17): until
this op a drain read another account's home through sudo; now only the
account reads its memory, and the coordinator receives the result. The
harvester refuses the whole drain when a memory carries a credential by
shape, so no secret reaches the channel; a memory directory with no
working copy beside it, or with two that share its slug, is named and
left where it is; the op passes `--all`, so the watermark governs only
the sudo fallback; not part of `status`), `status` (all but `script` and `memory`). A section that
cannot be read says so inline (`{"status":"no-credentials"}`), so a reply
always arrives and its gaps are named. The relay's `sender` field is
client-supplied and carries the same address, for a human reading the
channel.

## The fence, v1 — and the signing that follows

A daemon answers a request only when `from` is a host operator's address
as `runtime/hosts/registry.json` places it (read again for every record,
so a registry change counts at once), `op` is in the closed set,
`ts + ttl_s` is not in the past, and `id` was not seen (an LRU of 256).
Every refusal but the routine ones (a reply, a request for another
account, a duplicate) is one line in the daemon's journal, so a refused
operator can be found. That is a fence, not a proof: the relay verifies
no sender, and any holder of the shared relay token can write the
operator's address — and, the other way, can post a *reply* in another
account's name that `fabric-ctl` prints as that account's row. It stops
the accident — another session's watch, a typo, a replay of history —
and it bounds what a forged request can obtain to the same non-secret
facts; the table is as honest as the least trusted holder of the relay
token until replies are signed too. Signing is the next commit, as its
own change: an Ed25519 key the coordinator alone holds (its Doppler
config), the public key committed under `runtime/control/`, `sig` over
the canonical request fields, and a daemon that finds the public key
drops unsigned requests; replies get a per-account key the same way. Not
HMAC: a shared secret in every account's config lets every account forge
the coordinator.

## The coordinator's side

`bin/fabric-ctl <login|all> [status|usage|identity|keys|fabric|session|script|ping] [--json] [--timeout S]`
posts one request and reads the replies after its own id every half
second until every placed address has answered or the timeout is spent
(20 s; 5 s for ping); exit 1 when any address stayed silent. Stateless:
a run leaves its request and the replies on the channel, nothing
anywhere else. `bin/fabric-usage` stays as the sudo fallback for a host
whose daemons are down. A run by a login that is not a host operator is
refused before anything is posted: no daemon would answer it.

`bin/fabric-ctl <login|all> memory --out <dir>` is the drain (timeout
120 s): a reply counts as complete only when every part it announced has
arrived; the parts are reassembled by slug and order, gunzipped and
checked against the sha256 the first record named and against the
login: a reply is only a record any token holder could write, so a tar
whose manifest names another agent is `wrong-agent`, never filed under
a name it did not come from. A duplicated or replayed part record is
ignored. Each verified tar lands at `<dir>/<login>/<working copy>.tar`
(directory 0700, file 0600 — other people's memory) — the shape
`tools/fabric/assemble.py --bundle` takes. A bundle that is short,
unreadable or wrong is a status in the row (`incomplete`, `unreadable`,
`sha-mismatch`, `wrong-agent`, `harvest-failed` with the harvester's
reason) and no file; exit 1 when any account is silent or any bundle
refused.
`bin/fabric-host <host> drain <login>` stays as the sudo fallback for a
host whose daemons are down. The drain cycle is in `memory/README.md`.

## Why the accounts had to be persisted first

This host is a Qubes AppVM with `rw-only` persistence: `/home` survives
a reboot, the root volume — `/etc/passwd` included — does not, and the
fifteen accounts had existed only there since the first was made. A
daemon per account is worth nothing on accounts that vanish at boot.
Binding the account files under `/rw/bind-dirs` was ruled out by
reading shadow-utils, not by guessing: a bound single file is a
mountpoint, and `useradd`'s `rename(2)` of `passwd+` over it fails with
EBUSY, breaking every later account. The mechanism that works is the
one the host already used for `/tmp`: a boot script under
`/rw/config/rc.local.d/` that re-adds the snapshotted lines
(`runtime/provisioning/platform/qubes/agent-fabric-accounts.rc`), fed by
`persist-accounts.sh` at every account's creation and by `bin/fabric-host
<host> persist` for the ones that already existed — the six record files
and the login's supplementary groups (`members`), a login whose uid the
template has meanwhile taken skipped whole and named. Linger is enabled
in the same step, on every platform: that is what gives the account a
user manager at boot, and the manager is what starts the daemon. The
Qubes marker is read on any distribution (`platform/detect.sh`:
`fedora-qubes`, `debian-qubes`). Nothing removes a login from the
snapshot yet: a `userdel` on such a host is undone at the next boot
until a `--forget` exists, which waits for the first removal.

## A second host

The relay binds `127.0.0.1`, and every daemon on this host reaches it
there (`runtime/control/config.json`). A second host needs a URL its
daemons can reach — `hosts.<h>.control_relay_url` in the registry,
exported as `CLAUDE_BRIDGE_URL` to the unit — and the same channel; the
fence already keys on the registry's operator per host. Not built until
a second host exists.
