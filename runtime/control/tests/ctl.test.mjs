// fabric-ctl against a fake relay: the request it posts, the replies it
// collects, the table it prints, and the row for an agent that stayed silent.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { parseArgs, rows, table, writeBundles, manifestAgent, partKey } from '../ctl.mjs';
import { whoami } from '../../../communication/gzcoord/scripts/gzmsg.mjs';

const CTL = new URL('../ctl.mjs', import.meta.url).pathname;

test('parseArgs: targets, op, flags, defaults', () => {
  assert.deepEqual(parseArgs(['all']), { targets: ['all'], op: 'status', json: false, timeout: 20, out: null, days: null });
  assert.deepEqual(parseArgs(['db-admin', 'ping', '--json']), { targets: ['db-admin'], op: 'ping', json: true, timeout: 5, out: null, days: null });
  assert.deepEqual(parseArgs(['all', 'memory', '--out', '/tmp/d']), { targets: ['all'], op: 'memory', json: false, timeout: 120, out: '/tmp/d', days: null });
  assert.deepEqual(parseArgs(['all', 'tokens', '--days', '3']), { targets: ['all'], op: 'tokens', json: false, timeout: 60, out: null, days: 3 });
  assert.equal(parseArgs(['all', 'tokens', '--days=14']).days, 14);
  assert.throws(() => parseArgs(['all', 'tokens', '--days', '0']), /--days/);
  assert.throws(() => parseArgs(['all', 'status', '--days', '3']), /--days/, 'a window belongs to tokens only');
  assert.equal(parseArgs(['all', 'memory', '--out=/tmp/d']).out, '/tmp/d');
  assert.throws(() => parseArgs(['all', 'memory']), /--out/, 'a drain needs somewhere to land');
  assert.equal(parseArgs(['a', 'b', 'usage', '--timeout', '3']).timeout, 3);
  assert.deepEqual(parseArgs(['a', 'b', 'usage']).targets, ['a', 'b']);
  assert.throws(() => parseArgs(['all', '--nope']), /unknown option/);
  assert.throws(() => parseArgs(['all', '--timeout', '20s']), /--timeout/);
  assert.throws(() => parseArgs(['all', '--timeout=0']), /--timeout/);
});

test('rows and table: an answered account and a silent one', () => {
  const expected = [{ login: 'db-admin', host: 'h', address: 'h/db-admin' }, { login: 'web-dev-01', host: 'h', address: 'h/web-dev-01' }];
  const replies = [{ kind: 'reply', from: 'h/db-admin', op: 'status', latency_ms: 120, data: { identity: { role: 'db-admin', claude_account: { email: 'x@y.z' } }, usage: { status: 'ok', five_hour: { utilization: 12, resets_at: '2026-09-17T10:50:00+00:00' }, seven_day: { utilization: 80, resets_at: '2026-09-21T16:00:00+00:00' } }, fabric: { status: 'ok', head: 'abc1234', behind: 2, dirty: false } } }];
  const rs = rows(expected, replies);
  assert.equal(rs[0].status, 'ok'); assert.equal(rs[0].email, 'x@y.z'); assert.equal(rs[1].status, 'no answer');
  const t = table('status', rs);
  assert.match(t, /db-admin\s+ok\s+x@y.z\s+12%\s+2026-09-17T10:50\s+80%\s+2026-09-21T16:00\s+db-admin\s+abc1234 \(2 behind\)/);
  assert.match(t, /web-dev-01\s+no answer/);
  assert.match(table('ping', rs), /db-admin\s+ok\s+120 ms/);
  // The script table: the workers column — input and answers binned — and `-` when there are none.
  const sc = { status: 'ok', turns: 3, thinking: { letters: 0 }, thinking_blocks: { only: 0, mixed: 0, latin: 0, empty: 3 }, text: { letters: 40, georgian: 100 }, notes: { status: 'none' } };
  const w = { status: 'ok', files: 2, other_subagents: 1, turns: 4, tool_uses: 0, input: { letters: 300, georgian: 100, blocks: { only: 3, mixed: 0, latin: 1, empty: 0 }, language: { status: 'ok', paragraphs: 4, unreliable: 1, shares: { ka: 71.4, en: 28.6 }, dominant: { ka: 3 } } }, text: { letters: 200, georgian: 100, blocks: { only: 4, mixed: 0, latin: 0, empty: 0 }, language: { status: 'unavailable' } } };
  const st = table('script', rows(expected, [{ kind: 'reply', from: 'h/db-admin', op: 'script', data: { script: { ...sc, workers: w } } }]));
  assert.match(st, /workers \(input \/ answers\)/);
  assert.match(st, /db-admin\s+ok\s+none.*2 file\(s\): in 3 only \/ 0 mixed \/ 1 latin — lang ka 71.4%, en 28.6% \(1 unreliable\) \/ out 4 only \/ 0 mixed \/ 0 latin — lang unavailable/);
  const withNotesLang = table('script', rows(expected, [{ kind: 'reply', from: 'h/db-admin', op: 'script', data: { script: { ...sc, notes: { status: 'ok', files: 1, letters: 90, georgian: 100, blocks: { only: 2, mixed: 0, latin: 0, empty: 0 }, language: { status: 'ok', paragraphs: 2, unreliable: 0, shares: { ka: 100 }, dominant: { ka: 2 } } }, workers: { status: 'none', other_subagents: 0 } } } }]));
  assert.match(withNotesLang, /1 file\(s\): 2 only \/ 0 mixed \/ 0 latin — lang ka 100% — georgian 100%/);
  const none = table('script', rows(expected, [{ kind: 'reply', from: 'h/db-admin', op: 'script', data: { script: { ...sc, workers: { status: 'none', other_subagents: 0 } } } }]));
  assert.match(none, /db-admin\s+ok\s+none.*unreadable\s+-\s*$/m);
});

test('tokens table: grouped by Claude account, each login\'s share of the visible direct-path spend, the broker column apart, a login without records named', () => {
  const expected = [{ login: 'a', host: 'h', address: 'h/a' }, { login: 'b', host: 'h', address: 'h/b' }, { login: 'c', host: 'h', address: 'h/c' }, { login: 'd', host: 'h', address: 'h/d' }];
  const tok = (claude, broker, top) => ({ status: 'ok', days: 7, files: 1, requests: { session: 1, subagent: 0 }, models: { [top]: { equiv: claude, requests: 1, input: 0, cache_write: 0, cache_read: 0, output: 0, path: 'claude' } },
    claude: { requests: 3, input: 0, cache_write: 0, cache_read: 4000000, output: 5000, equiv: claude }, broker: { requests: 2, input: 0, cache_write: 0, cache_read: 0, output: 0, equiv: broker } });
  const reply = (login, email, t) => ({ kind: 'reply', from: `h/${login}`, op: 'tokens', data: { identity: { claude_account: email ? { email } : null }, tokens: t } });
  const rs = rows(expected, [reply('a', 'x@y.z', tok(3000000, 100000, 'claude-opus-5')), reply('b', 'x@y.z', tok(1000000, 0, 'claude-sonnet-5')), reply('c', 'q@y.z', tok(500, 0, 'claude-opus-5')), reply('d', 'x@y.z', { status: 'no-records', days: 7 })]);
  const t = table('tokens', rs);
  assert.match(t, /^account\s+status\s+claude account\s+share\s+claude equiv.*top model \(7 days\)/m);
  assert.match(t, /^a\s+ok\s+x@y.z\s+75%\s+3.0M\s+3\s+4.0M\s+5k\s+100k\s+2\s+claude-opus-5 3.0M$/m);
  assert.match(t, /^b\s+ok\s+x@y.z\s+25%\s+1.0M/m);
  assert.match(t, /= x@y.z\s+100%\s+4.0M\s+6$/m, 'an account with two logins gets a sum line');
  assert.match(t, /^c\s+ok\s+q@y.z\s+100%\s+500\b/m, 'the only login on its account holds all of it');
  assert.ok(!/= q@y.z/.test(t), 'no sum line for one login');
  assert.match(t, /^d\s+ok\s+x@y.z\s+tokens no-records$/m);
  assert.ok(t.indexOf('q@y.z') < t.indexOf('x@y.z'), 'accounts in order');
});

// A tar as the harvester writes it: manifest.json first (ustar header, size in octal), then padding.
function tarWith(manifest, filler = 1200) {
  const body = Buffer.from(JSON.stringify(manifest) + '\n');
  const h = Buffer.alloc(512); h.write('manifest.json', 0); h.write('0000644\0', 100); h.write('0000000\0', 108); h.write('0000000\0', 116);
  h.write(body.length.toString(8).padStart(11, '0') + '\0', 124); h.write('00000000000\0', 136); h.write('        ', 148); h.write('0', 156); h.write('ustar\0', 257); h.write('00', 263);
  let sum = 0; for (const b of h) sum += b; h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148);
  const pad = Buffer.alloc((512 - body.length % 512) % 512);
  return Buffer.concat([h, body, pad, crypto.randomBytes(filler)]);
}

// The bundles a drain answers with, put back together: by slug and part,
// gunzipped, checked against the sha the report named, written under the
// login; anything short, corrupt or wrong-sha is a status, not a file.
test('writeBundles: reassembly, and the three ways a bundle is refused', () => {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'drain-out-'));
  const tar = tarWith({ format: 'agent-fabric-drain/1', agent: 'db-admin', host: 'h' }); const sha = crypto.createHash('sha256').update(tar).digest('hex');
  assert.equal(manifestAgent(tar), 'db-admin'); assert.equal(manifestAgent(crypto.randomBytes(2000)), null);
  const b64 = zlib.gzipSync(tar).toString('base64'); const cut = Math.ceil(b64.length / 2);
  const chunks = [b64.slice(0, cut), b64.slice(cut)];
  const bundle = (slug, wc, over = {}) => ({ slug, working_copy: wc, files: 2, status: 'ok', bytes: tar.length, sha256: sha, parts: 2, ...over });
  const expected = [{ login: 'db-admin', host: 'h', address: 'h/db-admin' }, { login: 'web-dev-01', host: 'h', address: 'h/web-dev-01' }, { login: 'silent', host: 'h', address: 'h/silent' }];
  const replies = [
    { from: 'h/db-admin', data: { memory: { status: 'ok', bundles: [bundle('s-a', '/h/db-admin/projects/gzapp'), bundle('s-b', '/h/db-admin/projects/other', { sha256: 'not-the-sha' }), bundle('s-c', '/h/db-admin/projects/short'), { slug: 's-d', files: 1, status: 'no-working-copy' }] } } },
    { from: 'h/web-dev-01', data: { memory: { status: 'ok', bundles: [bundle('s-e', '/h/web-dev-01/projects/gzapp')] } } },
  ];
  const asMap = (from, list) => { const m = new Map(); for (const p of list) { const k = partKey(from, p); if (!m.has(k)) m.set(k, p); } return m; };
  const parts = { 'h/db-admin': asMap('h/db-admin', [{ slug: 's-b', part: 1, parts: 2, chunk: chunks[0] }, { slug: 's-a', part: 2, parts: 2, chunk: chunks[1] }, { slug: 's-b', part: 2, parts: 2, chunk: chunks[1] },
                                 { slug: 's-a', part: 1, parts: 2, chunk: chunks[0] }, { slug: 's-a', part: 1, parts: 2, chunk: 'a replayed copy of part 1' }, { slug: 's-c', part: 1, parts: 2, chunk: chunks[0] }]),
                  'h/web-dev-01': asMap('h/web-dev-01', [{ slug: 's-e', part: 1, parts: 2, chunk: 'not base64 of a gzip!!' }, { slug: 's-e', part: 2, parts: 2, chunk: '' }, { slug: 's-f', part: 1, parts: 2, chunk: chunks[0] }, { slug: 's-f', part: 2, parts: 2, chunk: chunks[1] }]) };
  replies[1].data.memory.bundles.push(bundle('s-f', '/h/web-dev-01/projects/gzapp2'));   // a bundle whose manifest says db-admin, under web-dev-01's name
  writeBundles(out, expected, replies, parts);
  const [a, b, c, d] = replies[0].data.memory.bundles;
  assert.equal(a.status, 'ok'); assert.equal(a.written, path.join(out, 'db-admin', 'gzapp.tar'));
  assert.deepEqual(fs.readFileSync(a.written), tar, 'parts out of order on the wire, a replayed one ignored, in order in the file');
  assert.equal((fs.statSync(a.written).mode & 0o777), 0o600); assert.equal((fs.statSync(path.join(out, 'db-admin')).mode & 0o777), 0o700);
  // A tree an earlier drain left world-readable is tightened on the next write, not kept.
  fs.chmodSync(a.written, 0o644); fs.chmodSync(path.join(out, 'db-admin'), 0o755); a.status = 'ok'; delete a.written;
  writeBundles(out, expected, replies, parts);
  assert.equal((fs.statSync(a.written).mode & 0o777), 0o600); assert.equal((fs.statSync(path.join(out, 'db-admin')).mode & 0o777), 0o700);
  assert.equal(b.status, 'sha-mismatch'); assert.equal(c.status, 'incomplete'); assert.equal(d.status, 'no-working-copy');
  assert.equal(replies[1].data.memory.bundles[0].status, 'unreadable');
  assert.equal(replies[1].data.memory.bundles[1].status, 'wrong-agent'); assert.equal(replies[1].data.memory.bundles[1].manifest_agent, 'db-admin');
  assert.deepEqual(fs.readdirSync(path.join(out, 'db-admin')), ['gzapp.tar'], 'a refused bundle leaves no file');
  assert.ok(!fs.existsSync(path.join(out, 'web-dev-01')) && !fs.existsSync(path.join(out, 'silent')));
  const rs = rows(expected, replies);
  const t = table('memory', rs);
  assert.match(t, /db-admin\s+ok\s+gzapp\s+2 memories\s+ok -> .*gzapp\.tar/);
  assert.match(t, /db-admin\s+ok\s+other\s+2 memories\s+sha-mismatch/);
  assert.match(t, /web-dev-01\s+ok\s+gzapp2\s+2 memories\s+wrong-agent: manifest names db-admin/);
  const failed = table('memory', rows(expected, [{ from: 'h/silent', data: { memory: { status: 'failed', error: 'boom' } } }, { from: 'h/db-admin', data: { memory: { status: 'ok', bundles: [{ slug: 'x', working_copy: '/h/db-admin/projects/gzapp', files: 3, status: 'harvest-failed', error: 'harvest_memory: refusing rather than guessing where these belong:\n  leaky.md: carries a credential by shape' }] } } }]));
  assert.match(failed, /silent\s+ok\s+memory failed: boom/);
  assert.match(failed, /db-admin\s+ok\s+gzapp\s+3 memories\s+harvest-failed: .*leaky\.md: carries a credential by shape/);
  assert.match(t, /db-admin\s+ok\s+s-d\s+1 memories\s+no-working-copy/);
  assert.match(t, /silent\s+no answer/);
  assert.match(table('memory', rows(expected, [{ from: 'h/silent', data: { memory: { status: 'ok', bundles: [] } } }])), /silent\s+ok\s+no memory/);
});

function relay() {
  const rows = []; let seq = 0; const hits = [];
  const add = (sender, content) => { seq += 1; const r = { seq, id: `id-${seq}`, sender, content, timestamp: 'T' }; rows.push(r); return r; };
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x'); hits.push(u.pathname + u.search); res.setHeader('content-type', 'application/json');
    if (u.pathname === '/api/messages') { const since = u.searchParams.get('since_id'); const i = rows.findIndex(r => r.id === since); res.end(JSON.stringify(since && i < 0 ? { messages: [], warning: 'since_id_not_found' } : { messages: since ? rows.slice(i + 1) : rows })); return; }   // the relay's shape
    if (u.pathname === '/api/send') { let b = ''; req.on('data', c => b += c); req.on('end', () => { const j = JSON.parse(b); const r = add(j.sender, j.content); res.end(JSON.stringify({ seq: r.seq, id: r.id })); }); return; }
    res.statusCode = 404; res.end('{}');
  });
  return { rows, hits, add, listen: () => new Promise(r => server.listen(0, '127.0.0.1', r)), url: () => `http://127.0.0.1:${server.address().port}`, close: () => { server.closeAllConnections(); server.close(); } };
}
function run(url, registry, args) {
  return new Promise(resolve => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-home-'));
    const child = spawn('node', [CTL, ...args], { env: { ...process.env, HOME: home, CLAUDE_BRIDGE_URL: url, CLAUDE_BRIDGE_AUTH_TOKEN: 'tok', FABRIC_CONTROL_CHANNEL: 'test:control', AGENT_FABRIC_HOSTS_REGISTRY: registry } });
    let out = '', err = ''; child.stdout.on('data', d => { out += d; }); child.stderr.on('data', d => { err += d; });
    child.on('close', status => resolve({ status, out, err }));
  });
}
// The placements live on THIS host with THIS login as its operator, whatever
// they are (CI runs as runner): fabric-ctl refuses to send as a non-operator.
const ME = whoami();
const H = ME.host;
const registryFile = (operator = ME.agent) => { const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'reg-')), 'registry.json');
  fs.writeFileSync(f, JSON.stringify({ hosts: { [H]: { operator } }, placement: { 'db-admin': H, 'web-dev-01': H, 'edge-hosting': H } })); return f; };

test('fabric-ctl all usage: two of three answer — table, a no-answer row, exit 1; --json one line each', async () => {
  const r = relay(); await r.listen();
  let done = false;
  try {
    const reg = registryFile();
    const answer = () => {
      if (done) return;
      const req = r.rows.find(x => { try { return JSON.parse(x.content).kind === 'request'; } catch { return false; } });
      if (!req) return setTimeout(answer, 50);
      done = true;
      const id = JSON.parse(req.content).id;
      const reply = (from, extra) => r.add(from, JSON.stringify({ v: 1, kind: 'reply', id: 'r-' + from, in_reply_to: id, from, op: 'usage', ok: true, data: extra }));
      reply(`${H}/db-admin`, { usage: { status: 'ok', five_hour: { utilization: 4, resets_at: '2026-09-17T10:50:00+00:00' }, seven_day: { utilization: 14, resets_at: '2026-09-21T16:00:00+00:00' } } });
      reply(`${H}/web-dev-01`, { usage: { status: 'no-credentials' } });
      r.add(`${H}/edge-hosting`, JSON.stringify({ v: 1, kind: 'reply', id: 'x', in_reply_to: 'someone-else', from: `${H}/edge-hosting`, op: 'usage', ok: true, data: {} }));   // not our request
    };
    setTimeout(answer, 50);
    const out = await run(r.url(), reg, ['all', 'usage', '--timeout', '3']);
    assert.equal(out.status, 1, out.err);
    assert.match(out.out, /db-admin\s+ok\s+-\s+4%\s+2026-09-17T10:50\s+14%/);
    assert.match(out.out, /web-dev-01\s+ok\s+-\s+no-credentials/);
    assert.match(out.out, /edge-hosting\s+no answer/);
    const req = JSON.parse(r.rows[0].content);
    assert.equal(req.kind, 'request'); assert.equal(req.op, 'usage'); assert.equal(req.to, '*'); assert.match(req.from, /^[^/]+\/[^/]+$/, 'from is this login\'s own address, whatever the login is (CI runs as runner)');
    assert.ok(!r.hits.some(h => h.startsWith('/api/ack') || h.startsWith('/api/wait')), 'history reads only, no cursor');
    const j = await run(r.url(), reg, ['db-admin', 'ping', '--json', '--timeout', '1']);
    assert.equal(j.status, 1); assert.deepEqual(JSON.parse(j.out.trim()), { account: 'db-admin', host: H, status: 'no answer' });
    // Not the operator: refused before anything is posted.
    const n = r.rows.length;
    const no = await run(r.url(), registryFile('someone-else'), ['db-admin', 'ping', '--timeout', '1']);
    assert.equal(no.status, 2, no.err); assert.match(no.err, /not a host operator/); assert.equal(r.rows.length, n, 'nothing was sent');
    // The relay lost the request (history cleared): said, and the run ends early.
    r.rows.length = 0;   // the earlier runs' records
    const clear = () => { if (r.rows.some(x => x.content.includes('"request"'))) { r.rows.length = 0; return; } setTimeout(clear, 20); };
    setTimeout(clear, 20);
    const t0 = Date.now();
    const lost = await run(r.url(), reg, ['db-admin', 'ping', '--timeout', '5']);
    assert.ok(Date.now() - t0 < 4000, 'ended before the timeout');
    assert.equal(lost.status, 1); assert.match(lost.err, /history cleared/);
  } finally { done = true; r.close(); }
});

test('fabric-ctl db-admin memory --out: the report record, then the parts, collected until every announced part is in; the tar lands under the login', async () => {
  const r = relay(); await r.listen();
  let done = false;
  try {
    const reg = registryFile();
    const tar = tarWith({ format: 'agent-fabric-drain/1', agent: 'db-admin', host: H }, 4000); const sha = crypto.createHash('sha256').update(tar).digest('hex');
    const b64 = zlib.gzipSync(tar).toString('base64'); const cut = Math.ceil(b64.length / 3);
    const chunks = [b64.slice(0, cut), b64.slice(cut, 2 * cut), b64.slice(2 * cut)];
    const answer = () => {
      if (done) return;
      const req = r.rows.find(x => { try { return JSON.parse(x.content).kind === 'request'; } catch { return false; } });
      if (!req) return setTimeout(answer, 50);
      done = true;
      const id = JSON.parse(req.content).id; const from = `${H}/db-admin`;
      const rec = data => r.add(from, JSON.stringify({ v: 1, kind: 'reply', id: 'r-' + Math.random(), in_reply_to: id, from, op: 'memory', ok: true, data }));
      rec({ memory: { status: 'ok', bundles: [{ slug: 's-1', working_copy: '/home/db-admin/projects/gzapp', files: 7, status: 'ok', bytes: tar.length, gzip_bytes: 4100, sha256: sha, parts: 3,
                                                 report: { claims: 5, counts: { in_scope: 7, total: 7 }, needs_rendering: ['ka-a', 'ka-b'], skipped_no_roles_class: ['private'] } }] }, parts: 3 });
      rec({ part: { slug: 's-1', part: 1, parts: 3, chunk: chunks[0] } });
      rec({ part: { slug: 's-1', part: 1, parts: 3, chunk: chunks[0] } });   // replayed: must not count as the second part
      // the last two parts arrive a moment later: the poll must keep going past the first record
      setTimeout(() => { rec({ part: { slug: 's-1', part: 2, parts: 3, chunk: chunks[1] } }); rec({ part: { slug: 's-1', part: 3, parts: 3, chunk: chunks[2] } }); }, 800);
    };
    setTimeout(answer, 50);
    const out = fs.mkdtempSync(path.join(os.tmpdir(), 'drain-'));
    const res = await run(r.url(), reg, ['db-admin', 'memory', '--out', out, '--timeout', '8']);
    assert.equal(res.status, 0, res.err + res.out);
    assert.equal(JSON.parse(r.rows[0].content).op, 'memory');
    const file = path.join(out, 'db-admin', 'gzapp.tar');
    assert.deepEqual(fs.readFileSync(file), tar);
    assert.match(res.out, /db-admin\s+ok\s+gzapp\s+7 memories\s+ok -> .*gzapp\.tar\s+5 claim\(s\), 2 need rendering, 1 skipped/);
    // --json: the row carries the report and where the tar went, never a chunk
    done = false; r.rows.length = 0; setTimeout(answer, 50);
    const j = await run(r.url(), reg, ['db-admin', 'memory', '--out', out, '--json', '--timeout', '8']);
    assert.equal(j.status, 0, j.err);
    const row = JSON.parse(j.out.trim());
    assert.equal(row.memory.bundles[0].written, file); assert.deepEqual(row.memory.bundles[0].report.needs_rendering, ['ka-a', 'ka-b']);
    assert.ok(!j.out.includes(chunks[0].slice(0, 40)), 'no chunk in the output');
    // One announced part never arrives: the run waits to its timeout, the bundle is incomplete, nothing is written, exit 1.
    fs.rmSync(path.join(out, 'db-admin'), { recursive: true });
    done = false; r.rows.length = 0; let last = false;
    const shortAnswer = () => { if (done) return; const req = r.rows.find(x => x.content.includes('"request"')); if (!req) return setTimeout(shortAnswer, 50); done = true; last = true;
      const id = JSON.parse(req.content).id; const from = `${H}/db-admin`;
      const rec = data => r.add(from, JSON.stringify({ v: 1, kind: 'reply', id: 'r-' + Math.random(), in_reply_to: id, from, op: 'memory', ok: true, data }));
      rec({ memory: { status: 'ok', bundles: [{ slug: 's-1', working_copy: '/home/db-admin/projects/gzapp', files: 7, status: 'ok', bytes: tar.length, sha256: sha, parts: 3, report: null }] }, parts: 3 });
      rec({ part: { slug: 's-1', part: 1, parts: 3, chunk: chunks[0] } }); rec({ part: { slug: 's-1', part: 3, parts: 3, chunk: chunks[2] } }); };
    setTimeout(shortAnswer, 50);
    const s = await run(r.url(), reg, ['db-admin', 'memory', '--out', out, '--timeout', '2']);
    assert.ok(last); assert.equal(s.status, 1, s.err + s.out);
    assert.match(s.out, /db-admin\s+ok\s+gzapp\s+7 memories\s+incomplete/);
    assert.ok(!fs.existsSync(file), 'nothing written for a short bundle');
    // A daemon whose whole memory section failed: the row says so and the exit code is 1, as for a refused bundle.
    done = false; r.rows.length = 0;
    const failedAnswer = () => { if (done) return; const req = r.rows.find(x => x.content.includes('"request"')); if (!req) return setTimeout(failedAnswer, 50); done = true;
      const id = JSON.parse(req.content).id; const from = `${H}/db-admin`;
      r.add(from, JSON.stringify({ v: 1, kind: 'reply', id: 'r-f', in_reply_to: id, from, op: 'memory', ok: true, data: { memory: { status: 'failed', error: 'boom' }, parts: 0 } })); };
    setTimeout(failedAnswer, 50);
    const f = await run(r.url(), reg, ['db-admin', 'memory', '--out', out, '--timeout', '5']);
    assert.equal(f.status, 1, f.err + f.out); assert.match(f.out, /db-admin\s+ok\s+memory failed: boom/);
  } finally { done = true; r.close(); }
});
