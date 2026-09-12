#!/usr/bin/env node
// GZCoord inbox: what the relay holds for THIS session, delivered the way
// SPEC §17 says a recipient receives — body read only if addressed to it.
//
// Two modes, one tool:
//   node tools/gzcoord/scripts/inbox.mjs            drain: return at once
//   node tools/gzcoord/scripts/inbox.mjs --wait [S] block up to S seconds
//                                                  TOTAL (default 1800 —
//                                                  thirty minutes) and
//                                                  return the moment
//                                                  something lands
//
// The relay's long-poll ceiling is 55 s per HTTP call; --wait chains those
// calls until the TOTAL budget is spent, so one arm covers half an hour
// instead of one poll. Each call is min(55, remaining), and the moment a
// slice returns a message the loop exits and delivers — the wake latency
// is unchanged. A total budget, not a per-call one, is the point: arming
// every 55 seconds was the noise the waiter exists to remove.
//
// The drain runs from the SessionStart hook in .claude/settings.json, so a
// session begins knowing what arrived while it was away. The wait is for a
// session actively expecting a reply: run it as a background task and its
// exit is the notification — the harness wakes the session when it ends.
// It is one-shot by design; a process that never exits never notifies.
// Three exits end it, and all three are followed by a fresh arm: a
// message addressed to this session; the budget expiring on slices that
// held none (quiet, counted, never printed in detail); the budget
// itself. The quiet exit is how the budget is spent, not a signal to
// stop listening.
//
// The WAIT exits only on a message addressed to this session (SPEC §7.1:
// a broadcast, `TO` its address, or `TO-ROLE` its slug). Anything else —
// including a message this session itself sent — passes through the arm
// acknowledged but unprinted, and the arm continues: waking a session for
// its neighbours' traffic is the noise this tool exists to remove, and
// every such wake is context spent on someone else's work. The drain
// (SessionStart) still lists non-addressed messages by their metadata
// line; only the wait is silent about them.
//
// The addressee rule is applied HERE, at delivery, not left to the reader:
// a message whose TO is not this address, whose TO-ROLE is not this role,
// and which is not a broadcast is listed by its metadata line and its body
// is not printed. That is the filter the evaluation said a transport should
// do, enforced where it costs nobody's context (docs/BRIDGE-RELAY-SETUP.md).
//
// Never blocks a session start: relay down, no token, no catalogue — each
// is one line on stderr and exit 0.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { parse, validate, loadTaxonomy, findTaxonomy, slugOf, recordedRole } from './gzmsg.mjs';

const RELAY = process.env.CLAUDE_BRIDGE_URL ?? 'http://127.0.0.1:8765';
const CHANNEL = process.env.GZCOORD_CHANNEL ?? 'gzapp:gzcoord';

function repoRoot() {
  try { return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim(); }
  catch { return process.cwd(); }
}

// The token, from wherever this clone keeps it; never printed, never logged.
function token(root) {
  if (process.env.CLAUDE_BRIDGE_AUTH_TOKEN) return process.env.CLAUDE_BRIDGE_AUTH_TOKEN;
  const env = path.join(root, 'infra/local/.env.local');
  if (fs.existsSync(env))
    for (const line of fs.readFileSync(env, 'utf8').split('\n'))
      if (line.startsWith('CLAUDE_BRIDGE_AUTH_TOKEN=')) return line.slice('CLAUDE_BRIDGE_AUTH_TOKEN='.length).trim();
  const local = path.join(root, '.claude/settings.local.json');
  try { const t = JSON.parse(fs.readFileSync(local, 'utf8')).env?.CLAUDE_BRIDGE_AUTH_TOKEN; if (t) return t; } catch {}
  return undefined;
}

// Who this session is, by the same derivation hello uses: the address from
// the working copy, the role from the active-role record, else from a slug
// the basename carries.
export function identity(root, taxonomy) {
  const instance = path.basename(root);
  const host = os.hostname().split('.')[0];
  const recorded = taxonomy ? recordedRole(taxonomy) : { role: undefined };
  const slug = recorded.role ?? (taxonomy ? slugOf(instance, taxonomy) : undefined);
  return { address: `${host}/${instance}`, instance, slug };
}

// SPEC §7.1 addressing, SPEC §17 reading rule. HELLO and GOODBYE are
// broadcasts by definition and carry no field.
export function forMe(msg, me) {
  const m = msg.metadata;
  if (['HELLO', 'GOODBYE'].includes(msg.type)) return true;
  if (m.BROADCAST === 'true') return true;
  if (m.TO !== undefined) return m.TO === me.address;
  if (m['TO-ROLE'] !== undefined) return me.slug !== undefined && m['TO-ROLE'] === me.slug;
  return false;
}

async function api(tok, pathAndQuery, init = {}) {
  const r = await fetch(`${RELAY}${pathAndQuery}`, {
    ...init,
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
  if (!r.ok) throw new Error(`${pathAndQuery} -> HTTP ${r.status}`);
  return r.json();
}

function oneLine(msg, raw) {
  const m = msg.metadata;
  const to = m.TO ? `TO ${m.TO}` : m['TO-ROLE'] ? `TO-ROLE ${m['TO-ROLE']}` : 'broadcast';
  return `${m['MESSAGE-ID'] ?? '(no id)'}  ${msg.type}  ${to}  ${m.SUBJECT ?? ''}`.trimEnd();
}

// One arm of the waiter. `delivered` iff some slice carried a message
// for this session. Every slice's messages are acknowledged before the
// loop continues or returns, so the cursor always advances past what was
// shown — and past what was passed: an acknowledgement means "shown this
// position", not "read the body".
export async function waitLoop({ fetchPage, ack, waitTotal, forMeFn = forMe }) {
  let waited = 0;
  for (;;) {
    const slice = waitTotal === 0 ? 1 : Math.min(55, Math.max(1, waitTotal - waited));
    const page = await fetchPage(slice);
    waited += slice;
    const classified = [];
    let delivered = false;
    for (const rec of page.messages ?? []) {
      let msg = null;
      try { msg = parse(rec.content); } catch { /* not GZCOORD/1: never addressed */ }
      const isMine = msg ? forMeFn(msg) : false;
      classified.push({ rec, msg, isMine });
      if (isMine) delivered = true;
    }
    for (const { rec } of classified) { try { await ack(rec.id); } catch { /* the next arm re-shows it */ } }
    if (delivered || waitTotal === 0 || waited >= waitTotal)
      return { classified, waited, delivered, othersPassed: classified.filter(c => !c.isMine).length };
    // Nothing for this session in the slice: the cursor is past it, and
    // the remaining budget keeps waiting.
  }
}

export async function main(argv = process.argv.slice(2)) {
  const waitIdx = argv.indexOf('--wait');
  const waitTotal = waitIdx >= 0 ? (Number(argv[waitIdx + 1]) || 1800) : 0;
  const root = repoRoot();
  const tok = token(root);
  if (!tok) { console.error('gzcoord inbox: no CLAUDE_BRIDGE_AUTH_TOKEN in the environment, infra/local/.env.local or .claude/settings.local.json — skipping'); return 0; }
  const taxPath = findTaxonomy(root);
  const taxonomy = taxPath ? loadTaxonomy(taxPath) : undefined;
  const me = identity(root, taxonomy);

  // Drain mode spends 1 s on the cursor page and lists everything; wait
  // mode chains slices until a message ADDRESSED TO THIS SESSION lands,
  // passing others' traffic through acknowledged and unprinted.
  let res;
  try {
    const ack = id => api(tok, '/api/ack', { method: 'POST', body: JSON.stringify({ consumer_id: me.address, channel: CHANNEL, message_id: id }) });
    const fetchPage = async slice => api(tok, `/api/wait?${new URLSearchParams({ channel: CHANNEL, consumer_id: me.address, timeout_seconds: String(slice), limit: '50' })}`);
    res = await waitLoop({ fetchPage, ack, waitTotal, forMeFn: msg => forMe(msg, me) });
  } catch (e) {
    console.error(`gzcoord inbox: relay unreachable at ${RELAY} (${e.message}) — skipping`);
    return 0;
  }
  if (!res.delivered && waitIdx >= 0)
    console.log(`gzcoord inbox: nothing for you on ${CHANNEL} in ${res.waited}s (${res.othersPassed} passed for others)`);
  if (!res.delivered) return 0;

  const mine = [], others = [];
  for (const { rec, msg, isMine } of res.classified) {
    if (!msg) { others.push({ rec, line: `${rec.id}  (not a GZCOORD/1 message)  from ${rec.sender}` }); continue; }
    (isMine ? mine : others).push({ rec, msg });
  }

  const out = [];
  out.push(`gzcoord inbox for ${me.address}${me.slug ? ` (${me.slug})` : ''}: ${mine.length} for you, ${others.length} not addressed to you, on ${CHANNEL}`);
  for (const { rec, msg } of mine) {
    const v = validate(rec.content, { taxonomy });
    const flags = [...(v.errors.map(e => `INVALID: ${e}`)), ...v.warnings.map(w => `warning: ${w}`)];
    out.push('', `--- relay seq ${rec.seq}, from ${rec.sender}, ${rec.timestamp}${flags.length ? `\n    ${flags.join('\n    ')}` : ''}`, '```text', rec.content.replace(/\n$/, ''), '```');
  }
  if (others.length) {
    out.push('', 'Not addressed to you — listed, bodies not read (SPEC §17):');
    for (const o of others) out.push(`  ${o.line ?? oneLine(o.msg)}`);
  }
  console.log(out.join('\n'));

  // The cursor is already advanced past everything shown — waitLoop
  // acknowledges every slice it sees, delivered or passed.
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) main().then(c => process.exit(c)).catch(e => { console.error(`gzcoord inbox: ${e.message}`); process.exit(0); });
