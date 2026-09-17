// runtime/control/agentd.mjs — the control agent: one process per account,
// run as the login under its systemd user unit, answering the
// coordinator's requests on the control channel with what the account can
// say about itself (ops.mjs). The real-time control plane the CEO asked
// for on 2026-09-17: no sudo, no session, no model in the loop.
//
//   node runtime/control/agentd.mjs           the daemon: block, answer, repeat
//   node runtime/control/agentd.mjs --once    answer what is pending, then exit (tests)
//   node runtime/control/agentd.mjs --self    print this account's status locally, no relay
//
// THE CHANNEL. runtime/control/config.json names it (fabric:control) and
// the relay — the same one the fleet's GZCoord traffic rides. A control
// channel carries JSON records, not GZCOORD/1 messages, and no session
// ever drains it (inbox.mjs refuses a channel ending in :control). There
// is no point-to-point delivery: every agent reads every record and
// answers the ones addressed to it (`to` its address, a list holding it,
// or "*"); the coordinator reads the replies by `in_reply_to`.
//
// THE READ. No consumer cursor and no ack: the relay's `since_id` is an
// explicit cursor, so a restart never replays history — the agent primes
// from the newest record on the channel and waits after it, 55 s a poll.
// A `since_id_not_found` (the relay's history was cleared) re-primes.
//
// THE FENCE, v1. A request is answered only when its `from` is a host
// operator's address as runtime/hosts/registry.json places it — read
// again for every record, so a pull that changes the registry counts at
// once, and the identity section asks whoami() per request, so a rebind
// shows without a restart (review, 2026-09-17) — (a claim,
// not a proof — the relay verifies no sender; it stops any other session
// from asking, and signing comes next: an Ed25519 `sig` the coordinator
// makes with a key only its Doppler config holds), its op is one of the
// closed set, its `ts` plus `ttl_s` is not in the past, and its id was
// not seen before (an LRU of 256). Ops take no arguments and no field of
// a request ever reaches a shell; the answer carries no secret (ops.mjs).
//
// Every reply arrives: a section that cannot be read says so inline.
// Relay down: one line on stderr, retry every 30 s; a refused token is
// re-read once from the synced file (a rotation), then reported.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { whoami, FABRIC_ROOT } from '../../communication/gzcoord/scripts/gzmsg.mjs';
import { api, syncedToken, identity as gzIdentity, integrationConfig, inboxRoot, token as gzToken } from '../../communication/gzcoord/scripts/inbox.mjs';
import { OPS, collect, usage } from './ops.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const SEEN_MAX = 256;
export const USAGE_CACHE_MS = 10000;

export function controlConfig(env = process.env, file = path.join(HERE, 'config.json')) {
  let own = {};
  try { own = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* defaults below */ }
  return {
    relay_url: env.CLAUDE_BRIDGE_URL ?? own.relay_url ?? 'http://127.0.0.1:8765',
    channel: env.FABRIC_CONTROL_CHANNEL ?? own.channel ?? 'fabric:control',
    ttl_s: Number(own.ttl_s) > 0 ? Number(own.ttl_s) : 30,
  };
}

// The operators: <host>/<operator> for every host in the registry.
export function operatorAddresses(registry = process.env.AGENT_FABRIC_HOSTS_REGISTRY ?? path.join(FABRIC_ROOT, 'runtime', 'hosts', 'registry.json')) {
  try {
    const d = JSON.parse(fs.readFileSync(registry, 'utf8'));
    return new Set(Object.entries(d.hosts ?? {}).map(([h, v]) => `${h}/${v.operator ?? 'user'}`));
  } catch { return new Set(); }
}

export function newId() {
  // UUIDv7: time-ordered, unique by construction; the same shape gzmsg new-id mints.
  const t = BigInt(Date.now());
  const b = crypto.randomBytes(16);
  b[0] = Number((t >> 40n) & 0xffn); b[1] = Number((t >> 32n) & 0xffn); b[2] = Number((t >> 24n) & 0xffn);
  b[3] = Number((t >> 16n) & 0xffn); b[4] = Number((t >> 8n) & 0xffn); b[5] = Number(t & 0xffn);
  b[6] = (b[6] & 0x0f) | 0x70; b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// Is this record a request this agent answers? The reason when not, for
// the log; never an error, never a reply.
export function accept(rec, { me, operators, ttl_s, seen, now = Date.now() }) {
  let r;
  try { r = JSON.parse(rec.content); } catch { return { ok: false, why: 'not json' }; }
  if (!r || r.kind !== 'request') return { ok: false, why: 'not a request' };
  if (r.v !== 1) return { ok: false, why: `v ${r.v}` };
  if (typeof r.id !== 'string' || !r.id) return { ok: false, why: 'no id' };
  if (seen.has(r.id)) return { ok: false, why: 'seen' };
  const to = Array.isArray(r.to) ? r.to : [r.to];
  if (!to.includes('*') && !to.includes(me.address)) return { ok: false, why: 'not for me' };
  if (!OPS.includes(r.op)) return { ok: false, why: `op ${String(r.op).slice(0, 20)}` };
  if (typeof r.from !== 'string' || !operators.has(r.from)) return { ok: false, why: `from ${String(r.from).slice(0, 40)} is not an operator` };
  const ts = Date.parse(r.ts);
  const ttl = Number(r.ttl_s) > 0 ? Math.min(Number(r.ttl_s), 3600) : ttl_s;
  if (!Number.isFinite(ts) || ts + ttl * 1000 < now) return { ok: false, why: 'expired' };
  return { ok: true, request: r };
}

// A pull that changes the daemon's own code must reach the daemon: a
// loaded module never reloads, so the process ends itself (after a 2 s
// quiet period, a pull writes several files) and the unit's Restart=
// starts the next one on the new tree. What is watched is the two
// directories the daemon imports from, never a file's content.
export function watchSource(onChange, dirs = [HERE, path.join(FABRIC_ROOT, 'communication', 'gzcoord', 'scripts')]) {
  let timer = null;
  const arm = (ev, name) => { if (!name || !/\.(mjs|json)$/.test(String(name))) return; clearTimeout(timer); timer = setTimeout(onChange, 2000); };
  return dirs.map(d => { try { const w = fs.watch(d, arm); w.unref(); return w; } catch { return null; } });
}

export function remember(seen, id) {
  seen.add(id);
  if (seen.size > SEEN_MAX) seen.delete(seen.values().next().value);
}

// A reply is one record; a `memory` reply is several: the first carries
// the bundles' reports and sizes, then one record per part
// ({part, parts, slug, chunk}) — the relay's message limit is 128 KiB and
// a drain is bigger. The coordinator reassembles by slug and part and
// verifies the sha256 the first record names.
export async function answer(request, ctx) {
  const data = request.op === 'ping' ? {} : await collect(request.op, ctx);
  const head = () => ({ v: 1, kind: 'reply', id: newId(), in_reply_to: request.id, from: ctx.me.address, op: request.op, ts: new Date().toISOString(), ok: true });
  const meta = { agentd: { pid: process.pid, started: ctx.started, uptime_s: Math.round((Date.now() - Date.parse(ctx.started)) / 1000) } };
  if (request.op !== 'memory' || !data.memory?.bundles) return { ...head(), data: { ...data, ...meta } };
  const parts = [];
  const bundles = data.memory.bundles.map(b => { const { _parts, ...rest } = b; for (let i = 0; i < (_parts ?? []).length; i++) parts.push({ slug: b.slug, part: i + 1, parts: _parts.length, chunk: _parts[i] }); return rest; });
  const first = { ...head(), data: { memory: { ...data.memory, bundles }, ...meta, parts: parts.length } };
  return { ...first, _followups: parts.map(p => ({ ...head(), data: { part: p } })) };
}

export async function main(argv = process.argv.slice(2)) {
  const once = argv.includes('--once');
  const self = argv.includes('--self');
  const who = whoami();
  const me = gzIdentity(who);
  const cfg = controlConfig();
  const started = new Date().toISOString();
  let usageAt = 0, usageLast = null;
  const usageCached = async () => { if (Date.now() - usageAt > USAGE_CACHE_MS) { usageLast = await usage(); usageAt = Date.now(); } return usageLast; };
  const ctx = { me, started, usageCached };   // no `who`: identity() resolves it per request
  if (self) { const { _followups, ...r } = await answer({ id: 'self', op: 'status' }, ctx); console.log(JSON.stringify(r, null, 2)); return 0; }

  const root = inboxRoot(who);
  const gz = integrationConfig(who.project);
  let tok = gzToken(root, gz.configured ? gz : undefined) ?? syncedToken();
  if (!tok) { console.error('agentd: no CLAUDE_BRIDGE_AUTH_TOKEN (fabric-secrets sync) — nothing to read with'); return 3; }
  if (operatorAddresses().size === 0) { console.error('agentd: no host operator in runtime/hosts/registry.json — nothing could ever be answered; not starting'); return 3; }
  const seen = new Set();
  // What is not logged: every reply on the channel (not a request), a
  // request for another account (not for me) and a duplicate (seen) —
  // fifteen daemons times fifteen replies per fabric-ctl would be noise.
  // Every other refusal is one line, so a refused operator can be found.
  const QUIET = new Set(['not a request', 'not for me', 'seen']);
  const q = o => new URLSearchParams(o).toString();
  const call = async (p, init) => {
    try { return await api(tok, p, { relayUrl: cfg.relay_url, ...init }); }
    catch (e) {
      const fresh = (e.status === 401 || e.status === 403) ? syncedToken() : undefined;
      if (fresh && fresh !== tok) { tok = fresh; console.error('agentd: token refused; retrying with the synced value'); return api(tok, p, { relayUrl: cfg.relay_url, ...init }); }
      throw e;
    }
  };
  const post = content => call('/api/send', { method: 'POST', body: JSON.stringify({ channel: cfg.channel, sender: me.address, content: JSON.stringify(content) }) });

  let last = null, down = false;
  const prime = async () => {
    const page = await call(`/api/messages?${q({ channel: cfg.channel, limit: '1' })}`);
    const rows = page.messages ?? page;
    if (rows.length) { last = rows[rows.length - 1].id; return; }
    const up = await post({ v: 1, kind: 'up', from: me.address, ts: new Date().toISOString() });
    last = up.id;
  };
  console.error(`agentd: ${me.address} on ${cfg.channel} at ${cfg.relay_url}; operators: ${[...operatorAddresses()].join(' ')}`);
  if (!once) watchSource(() => { console.error('agentd: source changed; exiting for systemd to restart on the new code'); process.exit(0); });
  for (;;) {
    try {
      if (!last) await prime();
      const page = await call(`/api/wait?${q({ channel: cfg.channel, since_id: last, timeout_seconds: once ? '3' : '55', limit: '50' })}`);
      if (down) { console.error('agentd: relay is back'); down = false; }
      if (page.warning === 'since_id_not_found') { last = null; continue; }
      const rows = page.messages ?? [];
      for (const rec of rows) {
        last = rec.id;
        const a = accept(rec, { me, operators: operatorAddresses(), ttl_s: cfg.ttl_s, seen });
        if (!a.ok) { if (!QUIET.has(a.why)) console.error(`agentd: ignored a record ${JSON.stringify(a.why)}`); continue; }
        remember(seen, a.request.id);
        const reply = await answer(a.request, ctx);
        const { _followups, ...firstReply } = reply;
        await post(firstReply);
        for (const f of _followups ?? []) await post(f);
        console.error(`agentd: answered ${a.request.op} for ${a.request.from} (${a.request.id.slice(0, 8)})`);
      }
      if (once) return 0;
    } catch (e) {
      if (e.status === 401 || e.status === 403) { console.error(`agentd: the relay refused this token (HTTP ${e.status}); rotated? run bin/fabric-secrets sync`); if (once) return 4; }
      else if (!down) { console.error(`agentd: relay unreachable at ${cfg.relay_url} (${e.message}) — retrying every 30 s`); down = true; }
      if (once) return 1;
      await new Promise(r => setTimeout(r, 30000));
    }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(c => process.exit(c)).catch(e => { console.error(`agentd: ${e.message}`); process.exit(1); });
