// runtime/control/ctl.mjs — the coordinator's side of the control plane:
// post one request on the control channel, read the replies, print them.
// Front door: bin/fabric-ctl.
//
//   fabric-ctl <login|all> [status|usage|identity|keys|fabric|session|script|ping] [--json] [--timeout S]
//   fabric-ctl <login|all> memory --out <dir>       each account's drain bundles, <dir>/<login>/<working copy>.tar
//
// A login becomes an address through the registry's placement
// (<host>/<login>); `all` is every placement, addressed as "*". The
// request goes out once; the replies are read from the relay's history
// after the request's own id (since_id, no cursor, nothing left behind)
// every half second until every expected address has answered or the
// timeout is spent (20 s; 5 s for ping). An address that stayed silent is
// a row that says so, and the exit code is 1 — a table is never short.
// Stateless: a run leaves one request record and the agents' replies on
// the channel, and nothing else anywhere.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { whoami, FABRIC_ROOT } from '../../communication/gzcoord/scripts/gzmsg.mjs';
import { api, syncedToken, identity as gzIdentity, integrationConfig, inboxRoot, token as gzToken } from '../../communication/gzcoord/scripts/inbox.mjs';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { OPS } from './ops.mjs';
import { controlConfig, newId, operatorAddresses } from './agentd.mjs';

export function placements(registry = process.env.AGENT_FABRIC_HOSTS_REGISTRY ?? path.join(FABRIC_ROOT, 'runtime', 'hosts', 'registry.json')) {
  const d = JSON.parse(fs.readFileSync(registry, 'utf8'));
  return Object.entries(d.placement ?? {}).map(([login, host]) => ({ login, host, address: `${host}/${login}` }));
}

export function parseArgs(argv) {
  const out = { targets: [], op: 'status', json: false, timeout: null, out: null, days: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--timeout') out.timeout = Number(argv[++i]);
    else if (a.startsWith('--timeout=')) out.timeout = Number(a.slice(10));
    else if (a === '--out') out.out = argv[++i];
    else if (a.startsWith('--out=')) out.out = a.slice(6);
    else if (a === '--days') out.days = Number(argv[++i]);
    else if (a.startsWith('--days=')) out.days = Number(a.slice(7));
    else if (a === '-h' || a === '--help') out.help = true;
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else if (OPS.includes(a) && out.targets.length) out.op = a;
    else out.targets.push(a);
  }
  if (out.timeout === null) out.timeout = out.op === 'ping' ? 5 : out.op === 'memory' ? 120 : out.op === 'tokens' ? 60 : 20;
  if (out.days !== null && (out.op !== 'tokens' || !Number.isFinite(out.days) || out.days <= 0)) throw new Error('--days takes a positive number of days, with tokens only');
  if (out.op === 'memory' && !out.out) throw new Error('memory takes --out <dir>: where the drain bundles are written');
  if (!Number.isFinite(out.timeout) || out.timeout <= 0) throw new Error('--timeout takes seconds, a positive number');
  return out;
}

// The drain bundles: <out>/<login>/<working copy>.tar, each reassembled from its
// parts, gunzipped, checked against the sha256 the first reply named, and
// checked to be that login's — the tar's manifest names who harvested it,
// and a reply is only a record on a channel every token holder can write,
// so a bundle whose manifest says another agent is refused as `wrong-agent`
// rather than filed under a name it did not come from. A bundle that does
// not verify is not written, and the row says so. Directories 0700, files
// 0600: a drain is other people's memory.
export function manifestAgent(tar) {
  // The harvester writes manifest.json as the first member: a 512-byte
  // header (name at 0, size in octal at 124), then the bytes.
  if (tar.length < 512 || tar.subarray(0, 100).toString('utf8').replace(/\0.*$/s, '') !== 'manifest.json') return null;
  const size = parseInt(tar.subarray(124, 136).toString('utf8').replace(/\0.*$/s, '').trim(), 8);
  try { return JSON.parse(tar.subarray(512, 512 + size).toString('utf8')).agent ?? null; } catch { return null; }
}
export function partKey(from, p) { return `${from}\u0000${p?.slug}\u0000${p?.part}`; }
export function writeBundles(out, expected, replies, parts) {
  for (const e of expected) {
    const r = replies.find(x => x.from === e.address); if (!r) continue;
    const got = [...(parts[e.address] ?? new Map()).values()];
    for (const b of r.data?.memory?.bundles ?? []) {
      if (b.status !== 'ok') continue;
      const mine = got.filter(p => p.slug === b.slug).sort((x, y) => x.part - y.part);
      if (mine.length !== b.parts || mine.some((p, i) => p.part !== i + 1)) { b.written = null; b.status = 'incomplete'; continue; }
      let tar;
      try { tar = zlib.gunzipSync(Buffer.from(mine.map(p => p.chunk).join(''), 'base64')); } catch { b.status = 'unreadable'; continue; }
      const sha = crypto.createHash('sha256').update(tar).digest('hex');
      if (sha !== b.sha256) { b.status = 'sha-mismatch'; continue; }
      const agent = manifestAgent(tar);
      if (agent !== e.login) { b.status = 'wrong-agent'; b.manifest_agent = agent; continue; }
      // mkdir's mode and writeFile's apply only on creation: a directory or a
      // tar left by an earlier drain keeps its mode unless set again.
      const dir = path.join(out, e.login); fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); fs.chmodSync(dir, 0o700);
      const file = path.join(dir, `${path.basename(b.working_copy)}.tar`); fs.writeFileSync(file, tar, { mode: 0o600 }); fs.chmodSync(file, 0o600); b.written = file;
    }
  }
}

// One row per expected address from the replies collected.
export function rows(expected, replies) {
  const by = new Map(replies.map(r => [r.from, r]));
  return expected.map(e => {
    const r = by.get(e.address);
    if (!r) return { account: e.login, host: e.host, status: 'no answer' };
    const d = r.data ?? {};
    return { account: e.login, host: e.host, status: 'ok', op: r.op, latency_ms: r.latency_ms ?? null,
             email: d.identity?.claude_account?.email ?? null, role: d.identity?.role ?? null,
             five_hour: d.usage?.five_hour ?? null, seven_day: d.usage?.seven_day ?? null, usage_status: d.usage?.status ?? null,
             keys: d.keys ?? null, fabric: d.fabric ?? null, session: d.session ?? null, script: d.script ?? null, tokens: d.tokens ?? null, memory: d.memory ?? null, agentd: d.agentd ?? null };
  });
}

const pct = w => (w && w.utilization != null) ? `${Number(w.utilization).toFixed(0).padStart(3)}%` : '   -';
const at = w => (w && w.resets_at) ? String(w.resets_at).slice(0, 16) : '-';
export function table(op, rs) {
  const lines = [];
  if (op === 'ping') {
    lines.push(`${'account'.padEnd(22)} ${'status'.padEnd(10)} latency`);
    for (const r of rs) lines.push(`${r.account.padEnd(22)} ${r.status.padEnd(10)} ${r.latency_ms != null ? r.latency_ms + ' ms' : ''}`.trimEnd());
    return lines.join('\n');
  }
  if (op === 'memory') {
    lines.push(`${'account'.padEnd(22)} ${'status'.padEnd(10)} bundles`);
    for (const r of rs) {
      if (r.status !== 'ok') { lines.push(`${r.account.padEnd(22)} ${r.status}`); continue; }
      if (r.memory && r.memory.status !== 'ok') { lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} memory ${r.memory.status}${r.memory.error ? `: ${r.memory.error}` : ''}`); continue; }
      const bs = r.memory?.bundles ?? [];
      if (!bs.length) { lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} no memory`); continue; }
      for (const b of bs) {
        const rep = b.report ? `${b.report.claims} claim(s), ${b.report.needs_rendering.length} need rendering, ${b.report.skipped_no_roles_class.length} skipped` : 'no report';
        const why = b.status === 'harvest-failed' ? `: ${String(b.error ?? '').trim().split('\n').slice(-2).join(' ')}` : b.status === 'wrong-agent' ? `: manifest names ${b.manifest_agent ?? 'nobody'}` : '';
        lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} ${(b.working_copy ? path.basename(b.working_copy) : b.slug).padEnd(24)} ${b.files} memories  ${b.status}${why}${b.written ? ` -> ${b.written}` : ''}  ${b.status === 'ok' ? rep : ''}`.trimEnd());
      }
    }
    return lines.join('\n');
  }
  if (op === 'script') {
    const top = s => !s || s.status !== 'ok' ? null : s;
    // The shares are the numeric entries but `letters` and `files`; the section's status, blocks and language ride beside them.
    const fmt = sh => !sh || !sh.letters ? '-' : Object.entries(sh).filter(([k, v]) => typeof v === 'number' && k !== 'letters' && k !== 'files').slice(0, 3).map(([k, v]) => `${k} ${v}%`).join(', ') + ` (${sh.letters} letters)`;
    const bins = b => !b ? '-' : `${b.only} only / ${b.mixed} mixed / ${b.latin} latin`;
    const lang = l => !l ? '' : l.status !== 'ok' ? ' — lang unavailable' : !l.paragraphs ? '' : ' — lang ' + (Object.entries(l.shares).slice(0, 3).map(([k, v]) => `${k} ${v}%`).join(', ') || '-') + (l.unreliable ? ` (${l.unreliable} unreliable)` : '');
    const notes = n => !n || n.status !== 'ok' ? 'none' : `${n.files} file(s): ${bins(n.blocks)}${lang(n.language)} — ${fmt(n)}`;
    // The workers: the locale worker's input (the bridge's leak signal) and its answers, paragraphs by script.
    const workers = w => !w || w.status !== 'ok' ? '-' : `${w.files} file(s): in ${bins(w.input.blocks)}${lang(w.input.language)} / out ${bins(w.text.blocks)}${lang(w.text.language)}`;
    lines.push(`${'account'.padEnd(22)} ${'status'.padEnd(10)} ${'notes (the signature: paragraphs by script)'.padEnd(70)} ${'turns'.padStart(5)}  ${'text, by script'.padEnd(44)} ${'thinking (stored text only)'.padEnd(40)} workers (input / answers)`);
    for (const r of rs) {
      if (r.status !== 'ok') { lines.push(`${r.account.padEnd(22)} ${r.status}`); continue; }
      const s = top(r.script);
      const th = s => !s.thinking_blocks ? '-' : `${bins(s.thinking_blocks)} / ${s.thinking_blocks.empty} unreadable`;
      if (!s) { lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} ${notes(r.script?.notes).padEnd(70)} ${(r.script?.status ?? '-')}`); continue; }
      lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} ${notes(s.notes).padEnd(70)} ${String(s.turns).padStart(5)}  ${fmt(s.text).padEnd(44)} ${th(s).padEnd(40)} ${workers(s.workers)}`);
    }
    return lines.join('\n');
  }
  if (op === 'tokens') {
    // Grouped by Claude account: a login's share is its direct-path
    // equivalents over the account's, from the logins that answered — the
    // meter counts what this host cannot see, so the shares are of the
    // visible spend. The broker column is the login's own key, no share.
    const M = n => n >= 1e9 ? `${(n / 1e9).toFixed(2)}G` : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(0)}k` : String(n);
    const ok = rs.filter(r => r.status === 'ok' && r.tokens?.status === 'ok');
    const days = ok[0]?.tokens?.days ?? '-';
    const byAccount = new Map();
    for (const r of ok) { const k = r.email ?? '(no Claude account)'; (byAccount.get(k) ?? byAccount.set(k, []).get(k)).push(r); }
    lines.push(`${'account'.padEnd(22)} ${'status'.padEnd(10)} ${'claude account'.padEnd(30)} ${'share'.padStart(6)}  ${'claude equiv'.padStart(12)} ${'requests'.padStart(8)} ${'cache read'.padStart(10)} ${'output'.padStart(8)}  ${'broker equiv'.padStart(12)} ${'requests'.padStart(8)}  top model (${days} days)`);
    for (const [email, group] of [...byAccount.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      const sum = group.reduce((n, r) => n + r.tokens.claude.equiv, 0);
      for (const r of group.sort((a, b) => b.tokens.claude.equiv - a.tokens.claude.equiv)) {
        const t = r.tokens; const top = Object.entries(t.models)[0];
        const share = sum ? `${(100 * t.claude.equiv / sum).toFixed(0).padStart(5)}%` : '     -';
        lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} ${email.padEnd(30)} ${share}  ${M(t.claude.equiv).padStart(12)} ${String(t.claude.requests).padStart(8)} ${M(t.claude.cache_read).padStart(10)} ${M(t.claude.output).padStart(8)}  ${M(t.broker.equiv).padStart(12)} ${String(t.broker.requests).padStart(8)}  ${top ? `${top[0]} ${M(top[1].equiv)}` : '-'}`.trimEnd());
      }
      if (group.length > 1) lines.push(`${''.padEnd(22)} ${''.padEnd(10)} ${`= ${email}`.padEnd(30)} ${' 100%'.padStart(6)}  ${M(sum).padStart(12)} ${String(group.reduce((n, r) => n + r.tokens.claude.requests, 0)).padStart(8)}`);
    }
    for (const r of rs) if (!(r.status === 'ok' && r.tokens?.status === 'ok')) lines.push(`${r.account.padEnd(22)} ${r.status !== 'ok' ? r.status : `ok         ${(r.email ?? '-').padEnd(30)} tokens ${r.tokens?.status ?? '-'}`}`);
    return lines.join('\n');
  }
  lines.push(`${'account'.padEnd(22)} ${'status'.padEnd(10)} ${'claude account'.padEnd(30)} ${'5h'.padStart(4)}  ${'5h resets (UTC)'.padEnd(16)} ${'7d'.padStart(4)}  ${'7d resets (UTC)'.padEnd(16)} ${'role'.padEnd(18)} fabric`);
  for (const r of rs) {
    if (r.status !== 'ok') { lines.push(`${r.account.padEnd(22)} ${r.status}`); continue; }
    const fab = r.fabric?.status === 'ok' ? `${r.fabric.head}${r.fabric.behind ? ` (${r.fabric.behind} behind)` : ''}${r.fabric.dirty ? ' dirty' : ''}` : (r.fabric?.status ?? '-');
    const usage = r.usage_status === 'ok' ? `${pct(r.five_hour)}  ${at(r.five_hour).padEnd(16)} ${pct(r.seven_day)}  ${at(r.seven_day).padEnd(16)}` : `${(r.usage_status ?? '-').padEnd(42)}`;
    lines.push(`${r.account.padEnd(22)} ${'ok'.padEnd(10)} ${(r.email ?? '-').padEnd(30)} ${usage} ${(r.role ?? '-').padEnd(18)} ${fab}`);
  }
  return lines.join('\n');
}

export async function main(argv = process.argv.slice(2), { registry, fetchImpl } = {}) {
  let args;
  try { args = parseArgs(argv); } catch (e) { console.error(`fabric-ctl: ${e.message}`); return 2; }
  if (args.help || !args.targets.length) { console.error('usage: fabric-ctl <login|all> [status|usage|identity|keys|fabric|session|script|ping] [--json] [--timeout S]\n       fabric-ctl <login|all> tokens [--days N]\n       fabric-ctl <login|all> memory --out <dir>'); return args.help ? 0 : 2; }
  const all = placements(registry);
  let expected;
  if (args.targets.length === 1 && args.targets[0] === 'all') expected = all;
  else {
    expected = [];
    for (const t of args.targets) {
      const p = all.find(x => x.login === t);
      if (!p) { console.error(`fabric-ctl: ${t} is not a placed account (runtime/hosts/registry.json)`); return 2; }
      expected.push(p);
    }
  }
  const who = whoami();
  const me = gzIdentity(who);
  if (!operatorAddresses().has(me.address)) { console.error(`fabric-ctl: ${me.address} is not a host operator in runtime/hosts/registry.json — no agent would answer; not sent`); return 2; }
  const cfg = controlConfig();
  const gz = integrationConfig(who.project);
  const tok = gzToken(inboxRoot(who), gz.configured ? gz : undefined) ?? syncedToken();
  if (!tok) { console.error('fabric-ctl: no CLAUDE_BRIDGE_AUTH_TOKEN (fabric-secrets sync)'); return 3; }
  const q = o => new URLSearchParams(o).toString();
  const call = (p, init) => api(tok, p, { relayUrl: cfg.relay_url, ...init });

  const id = newId();
  const request = { v: 1, kind: 'request', id, from: me.address, to: expected === all ? '*' : expected.map(e => e.address), op: args.op, ts: new Date().toISOString(), ttl_s: Math.max(cfg.ttl_s, Math.ceil(args.timeout)), ...(args.days ? { days: args.days } : {}) };
  let sent;
  try { sent = await call('/api/send', { method: 'POST', body: JSON.stringify({ channel: cfg.channel, sender: me.address, content: JSON.stringify(request) }) }); }
  catch (e) { console.error(`fabric-ctl: relay ${e.status ? `refused (HTTP ${e.status})` : `unreachable at ${cfg.relay_url}`}`); return 3; }
  const t0 = Date.now();
  const replies = []; const parts = {};
  const want = new Set(expected.map(e => e.address));   // no reply yet
  // A memory reply is complete only when every part it announced arrived.
  // Distinct parts, keyed by slug and number, the first record for a key
  // winning: a replayed or duplicated part neither completes a reply early
  // nor breaks its reassembly.
  const short = () => args.op === 'memory' ? replies.filter(r => (parts[r.from]?.size ?? 0) < (r.data?.parts ?? 0)).length : 0;
  const deadline = t0 + args.timeout * 1000;
  let since = sent.id;
  while (Date.now() < deadline && (want.size || short())) {
    let page;
    try { page = await call(`/api/messages?${q({ channel: cfg.channel, since_id: since, limit: '500', full: '1' })}`); }
    catch (e) { console.error(`fabric-ctl: relay read failed (${e.message})`); break; }
    if (page.warning === 'since_id_not_found') { console.error('fabric-ctl: the relay no longer holds the request (history cleared); the replies cannot be read'); break; }
    for (const rec of page.messages ?? []) {
      since = rec.id;
      let r; try { r = JSON.parse(rec.content); } catch { continue; }
      if (r?.kind !== 'reply' || r.in_reply_to !== id) continue;
      if (r.data?.part) { const m = (parts[r.from] ??= new Map()); const k = partKey(r.from, r.data.part); if (!m.has(k)) m.set(k, r.data.part); continue; }
      if (want.has(r.from)) { r.latency_ms = Date.now() - t0; replies.push(r); want.delete(r.from); }
    }
    if (want.size || short()) await new Promise(r => setTimeout(r, 500));
  }
  let refused = 0;
  if (args.op === 'memory') {
    writeBundles(args.out, expected, replies, parts);
    for (const r of replies) { if (r.data?.memory && r.data.memory.status !== 'ok') refused += 1; for (const b of r.data?.memory?.bundles ?? []) if (b.status !== 'ok' && b.status !== 'no-working-copy') refused += 1; }
  }
  const rs = rows(expected, replies);
  if (args.json) for (const r of rs) console.log(JSON.stringify(r));
  else console.log(table(args.op, rs));
  return want.size || short() || refused ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(c => process.exit(c)).catch(e => { console.error(`fabric-ctl: ${e.message}`); process.exit(1); });
