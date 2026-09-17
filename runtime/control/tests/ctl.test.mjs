// fabric-ctl against a fake relay: the request it posts, the replies it
// collects, the table it prints, and the row for an agent that stayed silent.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { parseArgs, rows, table } from '../ctl.mjs';

const CTL = new URL('../ctl.mjs', import.meta.url).pathname;

test('parseArgs: targets, op, flags, defaults', () => {
  assert.deepEqual(parseArgs(['all']), { targets: ['all'], op: 'status', json: false, timeout: 20 });
  assert.deepEqual(parseArgs(['db-admin', 'ping', '--json']), { targets: ['db-admin'], op: 'ping', json: true, timeout: 5 });
  assert.equal(parseArgs(['a', 'b', 'usage', '--timeout', '3']).timeout, 3);
  assert.deepEqual(parseArgs(['a', 'b', 'usage']).targets, ['a', 'b']);
  assert.throws(() => parseArgs(['all', '--nope']), /unknown option/);
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
});

function relay() {
  const rows = []; let seq = 0; const hits = [];
  const add = (sender, content) => { seq += 1; const r = { seq, id: `id-${seq}`, sender, content, timestamp: 'T' }; rows.push(r); return r; };
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x'); hits.push(u.pathname + u.search); res.setHeader('content-type', 'application/json');
    if (u.pathname === '/api/messages') { const since = u.searchParams.get('since_id'); const i = rows.findIndex(r => r.id === since); res.end(JSON.stringify({ messages: i < 0 ? rows : rows.slice(i + 1) })); return; }
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
const registryFile = () => { const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'reg-')), 'registry.json');
  fs.writeFileSync(f, JSON.stringify({ hosts: { h: { operator: 'user' } }, placement: { 'db-admin': 'h', 'web-dev-01': 'h', 'edge-hosting': 'h' } })); return f; };

test('fabric-ctl all usage: two of three answer — table, a no-answer row, exit 1; --json one line each', async () => {
  const r = relay(); await r.listen();
  try {
    const reg = registryFile();
    const answer = () => {
      const req = r.rows.find(x => { try { return JSON.parse(x.content).kind === 'request'; } catch { return false; } });
      if (!req) return setTimeout(answer, 50);
      const id = JSON.parse(req.content).id;
      const reply = (from, extra) => r.add(from, JSON.stringify({ v: 1, kind: 'reply', id: 'r-' + from, in_reply_to: id, from, op: 'usage', ok: true, data: extra }));
      reply('h/db-admin', { usage: { status: 'ok', five_hour: { utilization: 4, resets_at: '2026-09-17T10:50:00+00:00' }, seven_day: { utilization: 14, resets_at: '2026-09-21T16:00:00+00:00' } } });
      reply('h/web-dev-01', { usage: { status: 'no-credentials' } });
      r.add('h/edge-hosting', JSON.stringify({ v: 1, kind: 'reply', id: 'x', in_reply_to: 'someone-else', from: 'h/edge-hosting', op: 'usage', ok: true, data: {} }));   // not our request
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
    assert.equal(j.status, 1); assert.deepEqual(JSON.parse(j.out.trim()), { account: 'db-admin', host: 'h', status: 'no answer' });
  } finally { r.close(); }
});
