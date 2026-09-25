// runtime/control/presence.mjs — whether accounts have a session, asked of
// their control agents (ops.mjs `presence`), by any placed account. The
// sender's check before a message leaves (communication/gzcoord/scripts/
// send.mjs) is the caller: a message to a login with no session waits in
// the relay until one starts, and the sender is the one who can decide
// whether that is what it wants (the owner, 2026-09-25).
//
// The answer is the process table, not a claim a session made about
// itself: a crash, or a launch that never reached the harness, is never
// "present" — what the HELLO/GOODBYE pair got wrong.

import { api } from '../../communication/gzcoord/scripts/inbox.mjs';
import { controlConfig, newId } from './agentd.mjs';

// How long a sender waits for an answer: a control agent answers within a
// second; the rest is the relay's poll. GZCOORD_PRESENCE_WAIT_MS shortens
// it for a suite's silent-agent case.
export const PRESENCE_WAIT_MS = Number(process.env.GZCOORD_PRESENCE_WAIT_MS) > 0 ? Number(process.env.GZCOORD_PRESENCE_WAIT_MS) : 6000;
const sleep = ms => new Promise(r => setTimeout(r, ms));

// { <address>: <presence> | null } for every address in `expect`; null is
// a control agent that did not answer within waitMs — unknown, never
// "offline". `to` is one address, a list, or '*' (a TO-ROLE is resolved
// by the caller from the roles in the answers).
export async function askPresence({ from, to, expect, token, waitMs = PRESENCE_WAIT_MS, cfg = controlConfig(), call = null }) {
  const c = call ?? ((p, init) => api(token, p, { relayUrl: cfg.relay_url, ...init }));
  const id = newId();
  const request = { v: 1, kind: 'request', id, from, to, op: 'presence', ts: new Date().toISOString(), ttl_s: Math.max(cfg.ttl_s, Math.ceil(waitMs / 1000)) };
  const sent = await c('/api/send', { method: 'POST', body: JSON.stringify({ channel: cfg.channel, sender: from, content: JSON.stringify(request) }) });
  const out = Object.fromEntries(expect.map(a => [a, null]));
  const want = new Set(expect);
  const deadline = Date.now() + waitMs;
  let since = sent.id;
  while (want.size && Date.now() < deadline) {
    const page = await c(`/api/messages?${new URLSearchParams({ channel: cfg.channel, since_id: since, limit: '500', full: '1' })}`);
    for (const rec of page.messages ?? []) {
      since = rec.id;
      let r; try { r = JSON.parse(rec.content); } catch { continue; }
      if (r?.kind === 'reply' && r.in_reply_to === id && want.has(r.from) && r.data?.presence) { out[r.from] = r.data.presence; want.delete(r.from); }
    }
    if (want.size) await sleep(400);
  }
  return out;
}

// Who a message is for, and which of them has no session now. TO: that
// one address. TO-ROLE: every placed account whose binding holds the role
// — reached if ANY of them is running, since the role is addressed, not
// an instance. BROADCAST (and HELLO/GOODBYE): no check; everyone is not
// a set that can be offline.
export async function checkAddressees(metadata, { from, token, placed, ask = askPresence, waitMs = PRESENCE_WAIT_MS }) {
  if (metadata.BROADCAST || (!metadata.TO && !metadata['TO-ROLE'])) return { checked: false };
  if (metadata.TO) {
    const a = metadata.TO.trim();
    if (!placed.includes(a)) return { checked: true, problems: [{ kind: 'not-placed', address: a }] };
    const p = (await ask({ from, to: [a], expect: [a], token, waitMs }))[a];
    return { checked: true, problems: p === null ? [{ kind: 'silent', address: a }] : p.online ? [] : [{ kind: 'offline', address: a, presence: p }] };
  }
  const role = metadata['TO-ROLE'].trim();
  const all = await ask({ from, to: '*', expect: placed, token, waitMs });
  const holders = Object.entries(all).filter(([, p]) => p?.role === role);
  if (holders.some(([, p]) => p.online)) return { checked: true, problems: [] };
  const silent = Object.entries(all).filter(([, p]) => p === null).map(([a]) => a);
  return { checked: true, problems: [{ kind: 'no-holder', role, holders: holders.map(([a]) => a), silent }] };
}
