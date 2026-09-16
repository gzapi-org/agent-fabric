#!/usr/bin/env node
// GZCoord inbox: what the relay holds for THIS session, delivered the way
// SPEC §17 says a recipient receives — body read only if addressed to it.
//
// Two modes, one tool:
//   node communication/gzcoord/scripts/inbox.mjs            drain: return at once
//   node communication/gzcoord/scripts/inbox.mjs --follow   the watch: block for the
//                                        life of the session, print each delivery
//                                        as it lands, never return on a quiet spell
//   node communication/gzcoord/scripts/inbox.mjs --wait [S] block up to S seconds
//   node communication/gzcoord/scripts/inbox.mjs --replay <seq|message-id>
//                                        re-read ONE message already past the cursor
//                                        (the cursor does not move; a body not
//                                        addressed to this session is not shown)
//   node communication/gzcoord/scripts/inbox.mjs --held   is this account's inbox
//                                        held (the session is planning)? exit 0
//                                        held, 1 not; one line either way
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
// session begins knowing what arrived while it was away. The wait is the
// PRIMITIVE of the watch, not the watch: one arm returns on a message
// addressed to this session or when the budget expires quiet, and the
// harness wakes the session with the return. It is one-shot by design —
// a process that never exits never notifies — and the procedure around
// it is --follow: one process for the life of the session, armed once at
// its first turn under a persistent Monitor and forgotten (owner rule,
// 2026-09-13; skills/gzcoord-receive). It prints a delivery when one
// lands and nothing on a quiet spell — no budget, no expiry line, no
// shell loop around it, no restart every half hour. It says once when
// the relay stops answering and once when it is back, and exits 4 on a
// refused token (a rotation: sync, then arm again). The session re-arms
// nothing except after a resume, which the harness does not restore. The
// earlier shapes — a hand-re-armed --wait, then a shell loop around
// --wait 1800 — are retired: the first went deaf when a session forgot,
// the second produced a quiet-expiry line to filter every thirty minutes.
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
//
// THE HOLD (2026-09-16). A plan is written from the context the session
// had when it entered plan mode; a delivery landing mid-plan is context
// the plan was not asked to absorb. The harness cannot pause
// notifications, but a delivery is a notification only because this
// watch polls and prints — so while the session plans, the watch does not
// poll. The session says so through a marker the plan-hold hook writes
// (runtime/claude-code/hooks/plan-hold.sh: ~/.cache/agent-fabric/hold/
// <pid>.json, one per planning session, naming the harness pid and its
// start time); the watch honours a marker while that harness is alive and
// checks before every slice, cutting a slice already in flight the moment
// one appears. Nothing is consumed while held — the
// relay keeps the cursor and re-shows what was not acknowledged — and the
// first poll after the marker clears delivers everything at once, at the
// session's next turn boundary. Held is a line on stderr, never stdout:
// stdout is what the Monitor turns into notifications.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { parse, validate, normalize, loadTaxonomy, findTaxonomy, slugOf, recordedRole, whoami, FABRIC_ROOT } from './gzmsg.mjs';

// Project integration: which relay, which channel, where the token and
// the hosted relay's runtime live. It comes from the PROJECT —
// projects/<id>/integration/gzcoord/config.json, found through the
// working copy's project (whoami().project) — or from the environment
// (CLAUDE_BRIDGE_URL and GZCOORD_CHANNEL together). Nothing else: a
// project with neither is NOT configured, and both entry points say so
// and stop. Until 2026-09-16 the defaults here were one project's, so a
// working copy of any other project silently joined that project's channel
// with its token file — project truth in generic code (review, 2026-09-16).
// token_env_file is relative to the working copy (a clone carries its
// own token); relay_runtime_dir is relative to the WORKSPACE — the
// projects/ directory the fabric checkout sits in — because the relay's
// database, token and venv are host state, not project state: they must
// not live inside any repository, gitignored or not.
export const WORKSPACE = path.dirname(FABRIC_ROOT);
export function relayRuntimeDir(cfg, workspace = WORKSPACE) {
  return path.resolve(workspace, cfg.relay_runtime_dir ?? '.gzcoord');
}
export function integrationConfig(project, env = process.env) {
  const file = project ? path.join(FABRIC_ROOT, 'projects', project, 'integration', 'gzcoord', 'config.json') : null;
  if (file) {
    try {
      const own = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (own.relay_url && own.channel)
        return { configured: true, source: file, relay_runtime_dir: '.gzcoord', ...own,
                 relay_url: env.CLAUDE_BRIDGE_URL ?? own.relay_url, channel: env.GZCOORD_CHANNEL ?? own.channel };
    } catch { /* no file, or not JSON: the environment may still configure it */ }
  }
  if (env.CLAUDE_BRIDGE_URL && env.GZCOORD_CHANNEL)
    return { configured: true, source: 'environment', relay_url: env.CLAUDE_BRIDGE_URL, channel: env.GZCOORD_CHANNEL, relay_runtime_dir: '.gzcoord' };
  const where = project ? `projects/${project}/integration/gzcoord/config.json` : 'a registered project (this working copy resolves to none)';
  return { configured: false, source: null,
           reason: `no GZCoord integration configured for ${project ? `project ${project}` : 'this working copy'}: ` +
                   `${where} with relay_url and channel, or CLAUDE_BRIDGE_URL and GZCOORD_CHANNEL in the environment` };
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
// The environment comes first: fabric-secrets sync exports the token
// there from the account's Doppler config, which is how an enrolled
// account gets it. The file lookups serve a clone provisioned by hand.
export function token(root, cfg = integrationConfig()) {
  // The synced file first: it is what fabric-secrets sync writes, and the
  // environment is only a copy of it taken when the session's shell
  // started — a snapshot the harness never refreshes, so after a rotation
  // it stays wrong for the life of the session while the file is current
  // (web-dev-01, 2026-09-14: one refused call per re-arm, for hours).
  const synced = syncedToken();
  if (synced) return synced;
  if (process.env.CLAUDE_BRIDGE_AUTH_TOKEN) return process.env.CLAUDE_BRIDGE_AUTH_TOKEN;
  const env = cfg.token_env_file ? path.join(root, cfg.token_env_file) : null;
  if (env && fs.existsSync(env))
    for (const line of fs.readFileSync(env, 'utf8').split('\n'))
      if (line.startsWith('CLAUDE_BRIDGE_AUTH_TOKEN=')) return line.slice('CLAUDE_BRIDGE_AUTH_TOKEN='.length).trim();
  const local = path.join(root, '.claude/settings.local.json');
  try { const t = JSON.parse(fs.readFileSync(local, 'utf8')).env?.CLAUDE_BRIDGE_AUTH_TOKEN; if (t) return t; } catch {}
  // The hosting workspace holds the token the relay itself reads
  // (projects/.gzcoord/bridge-token, mode 0600): a session there — in
  // whichever working copy, or in none — is the host and needs no copy.
  try { const t = fs.readFileSync(path.join(relayRuntimeDir(cfg), 'bridge-token'), 'utf8').trim(); if (t) return t; } catch {}
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

// The relay dies with its hosting session, and the hosting workspace —
// the one whose runtime dir holds the relay's venv, token and database
// (projects/.gzcoord/, outside every repository) — is the
// fabric-coordinator's (a project integration rule, not a protocol
// one). So the host's session start IS the activation: if the relay is
// not answering, bring it up before draining, exactly as the runbook
// says. Workspaces without the venv return false and skip silently:
// they are clients, not hosts, and nothing in a client session may try
// to host.
export function ensureRelay(runtimeDir, relayUrl = RELAY) {
  const bin = path.join(runtimeDir, 'venv', 'bin', 'claude-bridge');
  if (!fs.existsSync(bin)) return { hosted: false, started: false };
  try { execFileSync('curl', ['-sf', '-m', '2', `${relayUrl}/status`], { stdio: 'ignore' }); return { hosted: true, started: false }; }
  catch { /* down or unreachable: start it */ }
  const tokenFile = path.join(runtimeDir, 'bridge-token');
  const db = path.join(runtimeDir, 'claude-bridge.db');
  if (!fs.existsSync(tokenFile)) return { hosted: true, started: false, note: `no ${tokenFile}; cannot start` };
  const out = fs.openSync(path.join(runtimeDir, 'bridge.log'), 'a');
  const child = spawn(bin, [
    '--host', '127.0.0.1', '--port', '8765',
    '--db', db, '--auth-token-file', tokenFile,
  ], { detached: true, stdio: ['ignore', out, out], unref: true });
  for (let waited = 0; waited < 8000; waited += 500) {
    try { execFileSync('curl', ['-sf', '-m', '1', `${relayUrl}/status`], { stdio: 'ignore' });
      return { hosted: true, started: true, pid: child.pid }; } catch { /* not up yet */ }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
  }
  return { hosted: true, started: false, note: `relay did not answer within 8s; check ${path.join(runtimeDir, 'bridge.log')}` };
}

export async function api(tok, pathAndQuery, { relayUrl = RELAY, ...init } = {}) {
  const r = await fetch(`${relayUrl}${pathAndQuery}`, {
    ...init,
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
  if (!r.ok) { const e = new Error(`${pathAndQuery} -> HTTP ${r.status}`); e.status = r.status; throw e; }
  return r.json();
}

// The synced token file, read fresh. The environment is a copy of it
// taken when the shell started — and in Claude Code every Bash call runs
// from a snapshot of the session's first shell, so after a rotation the
// environment keeps the dead value for the life of the session however
// many times fabric-secrets sync runs (web-dev-01, 2026-09-14). On a 401
// the inbox re-reads this file and retries once; only when the file
// agrees with the refused value is the rotation reported.
export function syncedToken(home = os.homedir()) {
  try {
    for (const line of fs.readFileSync(path.join(home, '.config', 'agent-fabric', 'secrets.env'), 'utf8').split('\n')) {
      const m = /^export CLAUDE_BRIDGE_AUTH_TOKEN=(.*)$/.exec(line);
      if (!m) continue;
      let v = m[1].trim();
      if ((v.startsWith("'") && v.endsWith("'")) || (v.startsWith('"') && v.endsWith('"'))) v = v.slice(1, -1);
      return v || undefined;
    }
  } catch { /* not enrolled, or no sync yet */ }
  return undefined;
}

// A 401 is not "unreachable": the relay answered and refused the token.
// After a rotation every session started before it holds the dead value
// in its environment, and the fix is a re-sync, not a retry — say so, and
// exit 4 so a watch loop can stop instead of printing the same line for
// the rest of the session (web-dev-01, 2026-09-14).
function explainRelayError(e, relayUrl) {
  if (e.status === 401 || e.status === 403)
    return { line: `gzcoord inbox: the relay at ${relayUrl} refused this token (HTTP ${e.status}) — it was rotated; run bin/fabric-secrets sync and re-arm the watch (the inbox reads the synced file itself)`, code: 4 };
  return { line: `gzcoord inbox: relay unreachable at ${relayUrl} (${e.message}) — skipping`, code: 0 };
}

// Re-read one message that is already past this session's cursor — the
// case where a read was piped through something that dropped the body.
// Reads the channel's recent history (no consumer id, so no cursor moves),
// and shows the body only when the message is addressed to this session:
// SPEC §17 does not stop applying because the read is a replay.
async function replay(tok, relayUrl, channel, which, me) {
  const page = await api(tok, `/api/messages?${new URLSearchParams({ channel, limit: '500', full: '1' })}`, { relayUrl });
  const list = page.messages ?? page;
  // By relay seq, or by the GZCoord MESSAGE-ID inside the body (the
  // relay's own id is a transport detail nobody quotes).
  const midOf = r => { try { return parse(normalize(r.content)).metadata?.['MESSAGE-ID']; } catch { return undefined; } };
  const rec = list.find(r => String(r.seq) === String(which) || r.id === which || midOf(r) === which);
  if (!rec) { console.error(`gzcoord inbox: no message ${which} in the last ${list.length} on ${channel}`); return 1; }
  const text = normalize(rec.content);
  const when = rec.timestamp ?? rec.ts ?? '';
  let msg = null; try { msg = parse(text); } catch { /* shown as metadata only */ }
  if (!msg || !forMe(msg, me)) {
    console.log(`relay seq ${rec.seq}, from ${rec.sender}, ${when} — not addressed to ${me.address}; body not shown (SPEC §17)`);
    if (msg) console.log(`  ${oneLine(msg, text)}`);
    return 2;
  }
  console.log(`--- relay seq ${rec.seq}, from ${rec.sender}, ${when} (replay; cursor unchanged)`);
  console.log('```text'); console.log(text.replace(/\n$/, '')); console.log('```');
  return 0;
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

// The hold markers: written by the plan-hold hook (one per planning
// session, <pid>.json under the login's own hold directory), read here.
// The account is held while ANY marker names a live harness of this
// login: the pid answers a signal as this uid (EPERM is another login's
// process, never our harness) and, when both sides know it, has the
// start time the marker recorded (a reused pid is not the harness). The
// directory and each file must be this login's, or nothing there is a
// hold — another login must not be able to hold or release this inbox.
export function holdDir(home = os.homedir()) {
  return process.env.AGENT_FABRIC_HOLD_DIR ?? path.join(home, '.cache', 'agent-fabric', 'hold');
}
export function pidStart(pid) {
  try { return fs.readFileSync(`/proc/${pid}/stat`, 'utf8').replace(/.*\) /s, '').split(' ')[19] ?? ''; } catch { return ''; }
}
export function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}
export function holdStatus(dir = holdDir(), { isAlive = pidAlive, startOf = pidStart, uid = process.getuid() } = {}) {
  let st;
  try { st = fs.lstatSync(dir); } catch { return { held: false, reason: 'no hold directory', sessions: [] }; }
  if (st.isSymbolicLink() || !st.isDirectory()) return { held: false, reason: 'hold directory is not a directory', sessions: [] };
  if (st.uid !== uid) return { held: false, reason: 'hold directory is not this login\'s', sessions: [] };
  const sessions = [], stale = [];
  for (const name of fs.readdirSync(dir)) {
    if (!/^\d+\.json$/.test(name)) continue;
    const file = path.join(dir, name);
    let m;
    try {
      if (fs.lstatSync(file).uid !== uid) { stale.push(`${name}: not this login's`); continue; }
      m = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch { stale.push(`${name}: unreadable`); continue; }
    if (!Number.isInteger(m.pid) || m.pid <= 0) { stale.push(`${name}: names no pid`); continue; }
    if (!isAlive(m.pid)) { stale.push(`${name}: session ${m.pid} is gone`); continue; }
    const now = startOf(m.pid);
    if (m.start && now && String(m.start) !== String(now)) { stale.push(`${name}: pid ${m.pid} reused`); continue; }
    sessions.push({ pid: m.pid, session_id: m.session_id, since: m.since });
  }
  if (!sessions.length) return { held: false, reason: stale.length ? stale.join('; ') : 'no marker', sessions };
  return { held: true, sessions };
}

export const HOLD_POLL_MS = 1000;
// `held` is consulted before every slice, once a second during one, and
// once more when the slice returns: a hold that begins mid-slice aborts
// the fetch, and a page that landed in the same second as the hold is
// dropped unread (nothing was acknowledged, so the relay re-shows it);
// the loop then waits, polling nothing, until the hold clears. `onHold`
// is told once per transition, for the stderr line. The guard's own
// sleep is cut when the slice ends, so a delivery waits for no tick.
export async function waitLoop({ fetchPage, ack, waitTotal, forMeFn = forMe, keywords = [], ownAddress,
                                 held = () => false, onHold = () => {}, holdPollMs = HOLD_POLL_MS, sleep = ms => new Promise(r => setTimeout(r, ms)) }) {
  let waited = 0;
  let hit = null;
  let wasHeld = false;
  for (;;) {
    if (held()) {
      if (!wasHeld) { onHold(true); wasHeld = true; }
      await sleep(holdPollMs);
      continue;
    }
    if (wasHeld) { onHold(false); wasHeld = false; }
    const slice = waitTotal === 0 ? 1 : Math.min(55, Math.max(1, waitTotal - waited));
    const ctl = new AbortController();
    let page;
    const tick = () => new Promise(r => { const t = setTimeout(() => { ctl.signal.removeEventListener('abort', done); r(); }, holdPollMs); const done = () => { clearTimeout(t); r(); }; ctl.signal.addEventListener('abort', done, { once: true }); });
    const guard = (async () => { for (;;) { await tick(); if (ctl.signal.aborted) return; if (held()) { ctl.abort(); return; } } })();
    try { page = await fetchPage(slice, ctl.signal); }
    catch (e) { if (ctl.signal.aborted) page = { messages: [] }; else { ctl.abort(); throw e; } }
    finally { ctl.abort(); await guard; }
    if (held()) page = { messages: [] };   // landed as the hold began: unread, unacknowledged, re-shown later
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

// One delivery (or drain) as the session reads it: what is for me in
// full, what is not by its metadata line (SPEC §17).
//
// THE NOTIFICATION CAP. What the watch prints reaches the session as a
// Monitor notification, and the harness shows about 3,000 characters of
// one event, then "...(truncated)" — the rest exists only in the task's
// output file, which the session does not know to open (architect-cto,
// 2026-09-16, four deliveries cut inside REQUEST or VERIFIED; measured
// here at 3,017 characters shown). So --follow renders under a cap of
// its own: a delivery that fits is printed whole; one that does not
// keeps every metadata line, cuts the body at a line boundary, and says
// where it cut and how to read the whole message (--replay, which moves
// no cursor). The cut is ours, at a place we choose, and the last line
// is the instruction; the harness's cut lands anywhere and says only
// "truncated". The drain (SessionStart hook context) is not a
// notification and is rendered whole.
export const NOTIFICATION_CAP = 2800;
export const REPLAY_CMD = 'node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/inbox.mjs" --replay';
function cutAtLine(text, max) {
  // Always at a line boundary: a body whose first line alone is longer
  // than the budget keeps nothing of it (the notice says where to read).
  if (text.length <= max) return text;
  const nl = text.lastIndexOf('\n', max);
  return nl < 0 ? '' : text.slice(0, nl);
}
const SECTION_RE = /^[A-Z][A-Z0-9-]*:$/;
// The metadata block ends at the first section marker (SPEC §6: the
// blank line before it MAY be absent), not at a blank line.
export function splitMessage(text) {
  const lines = text.replace(/\r\n/g, '\n').replace(/\n$/, '').split('\n');
  const at = lines.findIndex((l, k) => k > 0 && SECTION_RE.test(l));
  if (at < 0) return { meta: lines.join('\n').replace(/\n+$/, ''), body: '' };
  let metaEnd = at;
  while (metaEnd > 0 && lines[metaEnd - 1] === '') metaEnd -= 1;
  return { meta: lines.slice(0, metaEnd).join('\n'), body: lines.slice(at).join('\n') };
}
const MAX_FLAG_LINES = 4;
export function render(res, me, channel, taxonomy, { cap = Infinity } = {}) {
  const mine = [], others = [];
  for (const { rec, msg, isMine } of res.classified) {
    if (!msg) { others.push({ rec, line: `${rec.id}  (not a GZCOORD/1 message)  from ${rec.sender}` }); continue; }
    (isMine ? mine : others).push({ rec, msg });
  }
  const head = `gzcoord inbox for ${me.address}${me.slug ? ` (${me.slug})` : ''}: ${mine.length} for you, ${others.length} not addressed to you, on ${channel}`;
  const parts = mine.map(({ rec }) => {
    // The message has arrived: the terminal-copy width warning does not apply.
    const v = validate(rec.content, { taxonomy, maxColumns: 0 });
    let flags = [...(v.errors.map(e => `INVALID: ${e}`)), ...v.warnings.map(w => `warning: ${w}`)];
    // Only under a cap: the drain shows every validator line.
    if (Number.isFinite(cap) && flags.length > MAX_FLAG_LINES) flags = [...flags.slice(0, MAX_FLAG_LINES), `… and ${flags.length - MAX_FLAG_LINES} more validator lines`];
    const title = `--- relay seq ${rec.seq}, from ${rec.sender}, ${rec.timestamp}${flags.length ? `\n    ${flags.join('\n    ')}` : ''}`;
    const text = rec.content.replace(/\n$/, '');
    return { rec, title, text, ...splitMessage(text) };
  });
  const otherLines = others.map(o => `  ${o.line ?? oneLine(o.msg)}`);
  const othersBlock = others.length ? ['', 'Not addressed to you — listed, bodies not read (SPEC §17):', ...otherLines] : [];
  const whole = [head, ...parts.flatMap(p => ['', p.title, '```text', p.text, '```']), ...othersBlock].join('\n');
  if (whole.length <= cap) return whole;

  // Over the cap. Metadata whole and others listed if that fits; the
  // bodies share what is left, each cut at a line and ending with the
  // replay command for its seq. Nothing is claimed to be elsewhere.
  const seqs = list => list.length ? `seq ${list[0].rec.seq}–${list[list.length - 1].rec.seq}` : '';
  const notice = p => `[gzcoord: body cut here to fit one notification — the whole message: ${REPLAY_CMD} ${p.rec.seq}]`;
  const othersCount = others.length ? ['', `${others.length} not addressed to you (${seqs(others)}), not listed here: over the notification cap.`] : [];
  const layout = othersTail => [head, ...parts.flatMap(p => ['', p.title, '```text', p.meta, '', notice(p), '```']), ...othersTail].join('\n').length;
  let othersTail = othersBlock;
  if (layout(othersTail) > cap) othersTail = othersCount;
  const fixed = layout(othersTail);
  if (fixed > cap) {
    // Too many messages for one notification: one line each, read by seq,
    // and the tail says how many lines this listing itself dropped.
    const lines = [head, `(over the notification cap: each message by its seq, read it with: ${REPLAY_CMD} <seq>)`];
    const rows = parts.map(p => `  seq ${p.rec.seq}  ${oneLine(parse(p.rec.content))}`);
    const tailFor = n => n < parts.length ? `  … and ${parts.length - n} more for you (${seqs(parts.slice(n))}), each read with --replay <seq>` : '';
    const othersLine = others.length ? `  and ${others.length} not addressed to you (${seqs(others)})` : '';
    let n = 0;
    while (n < rows.length && [...lines, ...rows.slice(0, n + 1), tailFor(n + 1), othersLine].filter(Boolean).join('\n').length <= cap) n += 1;
    return [...lines, ...rows.slice(0, n), tailFor(n), othersLine].filter(Boolean).join('\n');
  }
  let budget = cap - fixed;
  const shares = parts.map(() => 0);
  // shortest bodies first: what they do not need goes to the longer ones
  const order = parts.map((p, i) => i).sort((a, b) => parts[a].body.length - parts[b].body.length);
  order.forEach((i, k) => { const share = Math.floor(budget / (order.length - k)); const take = Math.min(share, parts[i].body.length + 2); shares[i] = take; budget -= take; });
  const out = [head];
  for (const [i, p] of parts.entries()) {
    const cut = cutAtLine(p.body, Math.max(0, shares[i] - 2));
    const fits = cut.length >= p.body.length;
    out.push('', p.title, '```text', fits ? p.text : p.meta + (cut ? '\n\n' + cut : ''), ...(fits ? [] : ['', notice(p)]), '```');
  }
  return [...out, ...othersTail].join('\n');
}

export async function main(argv = process.argv.slice(2)) {
  const waitIdx = argv.indexOf('--wait');
  const follow = argv.includes('--follow');
  const replayIdx = argv.indexOf('--replay');
  const replayWhich = replayIdx >= 0 ? argv[replayIdx + 1] : null;
  if (replayIdx >= 0 && !replayWhich) { console.error('usage: inbox.mjs --replay <seq|message-id>'); return 1; }
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
  if (argv.includes('--held')) {
    const h = holdStatus();
    console.log(h.held ? `held: ${who.agent}'s inbox is held by ${h.sessions.map(x => `session ${x.session_id ?? '?'} (pid ${x.pid}) since ${x.since ?? '?'}`).join(', ')}` : `not held: ${h.reason}`);
    return h.held ? 0 : 1;
  }
  const root = inboxRoot(who);
  const cfg = integrationConfig(who.project);
  // Not configured is not an error at a session start, and not a guess
  // either: one line, exit 0, no relay, no channel.
  if (!cfg.configured) { console.error(`gzcoord inbox: ${cfg.reason} — skipping`); return 0; }
  const relayUrl = cfg.relay_url;
  const channel = cfg.channel;
  // Activate what this session owns before anything else: the hosting
  // working copy starts its relay here, so a session restart is also the relay's.
  const up = ensureRelay(relayRuntimeDir(cfg), relayUrl);
  if (up.started) console.error(`gzcoord inbox: relay started (pid ${up.pid})`);
  else if (up.note) console.error(`gzcoord inbox: ${up.note}`);
  let tok = token(root, cfg);
  if (!tok) { console.error(`gzcoord inbox: no CLAUDE_BRIDGE_AUTH_TOKEN in the environment, ${cfg.token_env_file ?? '(no token_env_file configured)'}, .claude/settings.local.json or the relay runtime dir — skipping`); return 0; }
  const taxPath = findTaxonomy(root);
  const taxonomy = taxPath ? loadTaxonomy(taxPath) : undefined;
  const me = identity(who, taxonomy);
  // Once: a refused token is retried with the synced file's value when
  // that differs from what the environment carried.
  const withFreshToken = async fn => {
    try { return await fn(tok); }
    catch (e) {
      const fresh = (e.status === 401 || e.status === 403) ? syncedToken() : undefined;
      if (fresh && fresh !== tok) { tok = fresh; console.error('gzcoord inbox: token refused; retrying with the synced value from secrets.env'); return fn(tok); }
      throw e;
    }
  };
  if (replayWhich) {
    try { return await withFreshToken(t => replay(t, relayUrl, channel, replayWhich, me)); }
    catch (e) { const x = explainRelayError(e, relayUrl); console.error(x.line); return x.code || 1; }
  }

  // Drain mode spends 1 s on the cursor page and lists everything; wait
  // mode chains slices until a message ADDRESSED TO THIS SESSION lands,
  // passing others' traffic through acknowledged and unprinted.
  const CHANNEL = channel;
  const ack = id => api(tok, '/api/ack', { method: 'POST', body: JSON.stringify({ consumer_id: me.address, channel: CHANNEL, message_id: id }), relayUrl });
  const fetchPage = async (slice, signal) => api(tok, `/api/wait?${new URLSearchParams({ channel: CHANNEL, consumer_id: me.address, timeout_seconds: String(slice), limit: '50' })}`, { relayUrl, signal });
  const held = () => holdStatus().held;
  const onHold = h => console.error(h ? `gzcoord watch: inbox held — the session is planning; nothing is polled until the plan is approved` : 'gzcoord watch: hold released; polling again');

  if (follow) {
    // The watch. Each arm waits an hour of slices; a delivery is printed
    // and the next arm starts at once; a quiet hour starts the next arm
    // silently. Transport trouble is one line each way; a refused token
    // ends the watch with exit 4 so the harness reports it once.
    let down = false;
    for (;;) {
      let r;
      try {
        r = await withFreshToken(() => waitLoop({ fetchPage, ack, waitTotal: 3600, forMeFn: msg => forMe(msg, me), keywords: [], ownAddress: me.address, held, onHold }));
      } catch (e) {
        const x = explainRelayError(e, relayUrl);
        if (x.code === 4) { console.error(x.line); return 4; }
        if (!down) { console.log(`gzcoord watch: relay unreachable at ${relayUrl} — waiting for it (this line prints once)`); down = true; }
        await new Promise(r => setTimeout(r, 30000));
        continue;
      }
      if (down) { console.log('gzcoord watch: relay is back; watching again'); down = false; }
      if (r.delivered) console.log(render(r, me, CHANNEL, taxonomy, { cap: NOTIFICATION_CAP }));
    }
  }

  let res;
  try {
    res = await withFreshToken(() => waitLoop({ fetchPage, ack, waitTotal, forMeFn: msg => forMe(msg, me), keywords, ownAddress: me.address }));
  } catch (e) {
    const x = explainRelayError(e, relayUrl); console.error(x.line); return x.code;
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
  console.log(render(res, me, CHANNEL, taxonomy));
  // The cursor is already advanced past everything shown — waitLoop
  // acknowledges every slice it sees, delivered or passed.
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) main().then(c => process.exit(c)).catch(e => { console.error(`gzcoord inbox: ${e.message}`); process.exit(0); });
