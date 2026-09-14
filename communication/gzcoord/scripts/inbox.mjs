#!/usr/bin/env node
// GZCoord inbox: what the relay holds for THIS session, delivered the way
// SPEC §17 says a recipient receives — body read only if addressed to it.
//
// Two modes, one tool:
//   node communication/gzcoord/scripts/inbox.mjs            drain: return at once
//   node communication/gzcoord/scripts/inbox.mjs --wait [S] block up to S seconds
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
import { execFileSync, spawn } from 'node:child_process';
import { parse, validate, loadTaxonomy, findTaxonomy, slugOf, recordedRole, whoami, FABRIC_ROOT } from './gzmsg.mjs';

// Project integration: which relay, which channel, where the token and
// the hosted relay's runtime live. The defaults are gzapp's
// (projects/gzapp/integration/gzcoord/config.json is the committed copy);
// another project overrides them by environment, or by its own
// config.json found through the working copy's project (whoami().project).
function integrationConfig(project) {
  const defaults = { relay_url: 'http://127.0.0.1:8765', channel: 'gzapp:gzcoord',
                     token_env_file: 'infra/local/.env.local', relay_runtime_dir: '.gzcoord' };
  if (!project) return defaults;
  const file = path.join(FABRIC_ROOT, 'projects', project, 'integration', 'gzcoord', 'config.json');
  try { return { ...defaults, ...JSON.parse(fs.readFileSync(file, 'utf8')) }; } catch { return defaults; }
}
// Module-level defaults for callers that import ensureRelay/api directly;
// main() resolves the project's own values.
const RELAY = process.env.CLAUDE_BRIDGE_URL ?? 'http://127.0.0.1:8765';

function gitToplevel() {
  try { return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); }
  catch { return null; }
}
// The working copy the inbox reads its token and integration from. Inside
// a checkout that is the checkout. Outside one — a session started in the
// workspace (projects/) — identity.py reports the project from the binding
// but no working copy, so the binding's own working_copy (the checkout the
// role was activated in) is the root; the cwd is only the last resort.
export function inboxRoot(who) {
  const top = gitToplevel();
  if (top) return top;
  if (who.working_copy) return who.working_copy;
  try {
    const b = JSON.parse(fs.readFileSync(who.binding, 'utf8'));
    if (b.working_copy && fs.existsSync(b.working_copy)) return b.working_copy;
  } catch { /* no binding */ }
  return process.cwd();
}

// The token, from wherever this working copy keeps it; never printed, never logged.
function token(root, cfg = integrationConfig()) {
  if (process.env.CLAUDE_BRIDGE_AUTH_TOKEN) return process.env.CLAUDE_BRIDGE_AUTH_TOKEN;
  const env = path.join(root, cfg.token_env_file);
  if (fs.existsSync(env))
    for (const line of fs.readFileSync(env, 'utf8').split('\n'))
      if (line.startsWith('CLAUDE_BRIDGE_AUTH_TOKEN=')) return line.slice('CLAUDE_BRIDGE_AUTH_TOKEN='.length).trim();
  const local = path.join(root, '.claude/settings.local.json');
  try { const t = JSON.parse(fs.readFileSync(local, 'utf8')).env?.CLAUDE_BRIDGE_AUTH_TOKEN; if (t) return t; } catch {}
  return undefined;
}

// Who this session is, by the same derivation hello uses: the instance
// half of the address is the AGENT — the Linux login, from
// runtime/identity.py via whoami() — never the working copy's basename;
// the host is the short hostname; the role comes from the agent's runtime
// binding, else from a slug the login happens to carry. The working copy
// the session runs in is context (SPEC §3.1) and plays no part here.
export function identity(me = whoami(), taxonomy) {
  const instance = me.agent;
  const host = me.host ?? os.hostname().split('.')[0];
  const recorded = taxonomy ? recordedRole(taxonomy, me) : { role: undefined };
  const slug = recorded.role ?? (taxonomy ? slugOf(instance, taxonomy) : undefined);
  return { address: `${host}/${instance}`, instance, slug, project: me.project };
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

// The relay dies with its hosting session, and the hosting working copy —
// the one holding the relay runtime (venv) and the token — is the
// fabric-coordinator's (a project integration rule, not a protocol
// one). So the host's session start IS the activation: if the relay is
// not answering, bring it up before draining, exactly as the runbook
// says. Working copies without the venv return false and skip silently:
// they are clients, not hosts, and nothing in a client session may try
// to host.
export function ensureRelay(root, relayUrl = RELAY, runtimeDir = '.gzcoord') {
  const bin = path.join(root, runtimeDir, 'venv', 'bin', 'claude-bridge');
  if (!fs.existsSync(bin)) return { hosted: false, started: false };
  try { execFileSync('curl', ['-sf', '-m', '2', `${relayUrl}/status`], { stdio: 'ignore' }); return { hosted: true, started: false }; }
  catch { /* down or unreachable: start it */ }
  const tokenFile = path.join(root, runtimeDir, 'bridge-token');
  const db = path.join(root, runtimeDir, 'claude-bridge.db');
  if (!fs.existsSync(tokenFile)) return { hosted: true, started: false, note: `no ${runtimeDir}/bridge-token; cannot start` };
  const out = fs.openSync(path.join(root, runtimeDir, 'bridge.log'), 'a');
  const child = spawn(bin, [
    '--host', '127.0.0.1', '--port', '8765',
    '--db', db, '--auth-token-file', tokenFile,
  ], { detached: true, stdio: ['ignore', out, out], unref: true });
  for (let waited = 0; waited < 8000; waited += 500) {
    try { execFileSync('curl', ['-sf', '-m', '1', `${relayUrl}/status`], { stdio: 'ignore' });
      return { hosted: true, started: true, pid: child.pid }; } catch { /* not up yet */ }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
  }
  return { hosted: true, started: false, note: 'relay did not answer within 8s; check .gzcoord/bridge.log' };
}

async function api(tok, pathAndQuery, { relayUrl = RELAY, ...init } = {}) {
  const r = await fetch(`${relayUrl}${pathAndQuery}`, {
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
// Alert keywords: reasons to stop waiting on a message that is NOT
// addressed to this session. Whole-token, case-insensitive, matched
// against the full message text (metadata + body — PR numbers live in
// REFERENCES). Guardrails against the abusable shape: 3+ characters (a
// 1–2 char token fires on nearly everything), at most 8 per arm, and a
// message from the armed session's own address never counts — a session
// must not wake on its own echo.
export const KEYWORD_MIN = 3;
export const KEYWORD_MAX = 8;
export function checkKeywords(keywords = []) {
  const seen = [];
  for (const k of keywords) {
    if (typeof k !== 'string' || k.length < KEYWORD_MIN)
      throw new Error(`keyword ${JSON.stringify(k)} is shorter than ${KEYWORD_MIN} characters — a short token fires on nearly everything`);
    if (seen.includes(k)) continue;
    if (seen.length >= KEYWORD_MAX) throw new Error(`at most ${KEYWORD_MAX} keywords per arm`);
    seen.push(k);
  }
  return seen;
}
export function keywordHit(text, keywords, ownAddress) {
  if (!keywords.length || !text) return false;
  const tokens = new Set(text.toLowerCase().split(/[^a-z0-9_-]+/).filter(Boolean));
  if (ownAddress)
    // The exemption removes each TOKEN of the own address — the address is
    // never one token, and a keyword naming another session's instance half
    // must still fire on that session's message.
    for (const t of ownAddress.toLowerCase().split(/[^a-z0-9_-]+/).filter(Boolean)) tokens.delete(t);
  return keywords.some(k => tokens.has(k.toLowerCase()));
}

export async function waitLoop({ fetchPage, ack, waitTotal, forMeFn = forMe, keywords = [], ownAddress }) {
  let waited = 0;
  let hit = null;
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
    // A keyword hit is a reason to stop waiting on a message that is not
    // addressed to this session. A delivered message wins the exit (it is
    // shown in full); a keyword on a passing message names it and exits
    // with code 3. A message from my own address never hits — a session
    // must not wake on its own echo.
    if (!delivered && !hit)
      for (const { rec, msg, isMine } of classified)
        if (!isMine && msg && keywordHit(rec.content, keywords, ownAddress)) { hit = rec; break; }
    if (delivered || hit || waitTotal === 0 || waited >= waitTotal)
      return { classified, waited, delivered, keywordHit: hit, othersPassed: classified.filter(c => !c.isMine).length };
    // Nothing for this session, no keyword hit: the cursor is past the
    // slice, and the remaining budget keeps waiting.
  }
}

export async function main(argv = process.argv.slice(2)) {
  const waitIdx = argv.indexOf('--wait');
  const waitTotal = waitIdx >= 0 ? (Number(argv[waitIdx + 1]) || 1800) : 0;
  // --keyword K, repeatable, validated BEFORE the arm starts: a bad
  // keyword refused at arm time costs nothing, refused mid-wait wastes
  // the budget.
  const keywords = checkKeywords(argv.flatMap((a, i) => a === '--keyword' ? [argv[i + 1]] : []));
  // Who this session is (the login) and which project it is working in
  // (from the working copy's remote, or the binding) — the second selects
  // the project's integration: relay, channel, where the token and runtime
  // live. Those live in the project's WORKING COPY: when the session was
  // started outside one (the workspace, projects/), the working copy the
  // binding names is the root, not the current directory.
  const who = whoami();
  const root = inboxRoot(who);
  const cfg = integrationConfig(who.project);
  const relayUrl = process.env.CLAUDE_BRIDGE_URL ?? cfg.relay_url;
  const channel = process.env.GZCOORD_CHANNEL ?? cfg.channel;
  // Activate what this session owns before anything else: the hosting
  // working copy starts its relay here, so a session restart is also the relay's.
  const up = ensureRelay(root, relayUrl, cfg.relay_runtime_dir);
  if (up.started) console.error(`gzcoord inbox: relay started (pid ${up.pid})`);
  else if (up.note) console.error(`gzcoord inbox: ${up.note}`);
  const tok = token(root, cfg);
  if (!tok) { console.error(`gzcoord inbox: no CLAUDE_BRIDGE_AUTH_TOKEN in the environment, ${cfg.token_env_file} or .claude/settings.local.json — skipping`); return 0; }
  const taxPath = findTaxonomy(root);
  const taxonomy = taxPath ? loadTaxonomy(taxPath) : undefined;
  const me = identity(who, taxonomy);

  // Drain mode spends 1 s on the cursor page and lists everything; wait
  // mode chains slices until a message ADDRESSED TO THIS SESSION lands,
  // passing others' traffic through acknowledged and unprinted.
  let res;
  const CHANNEL = channel;
  try {
    const ack = id => api(tok, '/api/ack', { method: 'POST', body: JSON.stringify({ consumer_id: me.address, channel: CHANNEL, message_id: id }), relayUrl });
    const fetchPage = async slice => api(tok, `/api/wait?${new URLSearchParams({ channel: CHANNEL, consumer_id: me.address, timeout_seconds: String(slice), limit: '50' })}`, { relayUrl });
    res = await waitLoop({ fetchPage, ack, waitTotal, forMeFn: msg => forMe(msg, me), keywords, ownAddress: me.address });
  } catch (e) {
    console.error(`gzcoord inbox: relay unreachable at ${relayUrl} (${e.message}) — skipping`);
    return 0;
  }
  if (res.keywordHit && waitIdx >= 0) {
    const m = res.classified.find(c => c.rec.id === res.keywordHit.id);
    console.log(`gzcoord inbox: keyword watch on ${CHANNEL} — a message matching one of [${keywords.join(', ')}] landed (not addressed to you, metadata only):`);
    console.log(`  ${(m?.msg ? oneLine(m.msg) : `${res.keywordHit.id} (unparsable)  from ${res.keywordHit.sender}`)}`);
    process.exit(3);
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
