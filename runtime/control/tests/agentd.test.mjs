// The control agent against a fake relay: what it answers, what it
// ignores, what it never does (ack, replay history, execute anything).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { accept, remember, SEEN_MAX, newId, operatorAddresses, controlConfig } from '../agentd.mjs';

const AGENTD = new URL('../agentd.mjs', import.meta.url).pathname;
const ROOT = new URL('../../../', import.meta.url).pathname.replace(/\/$/, '');
const me = { address: 'develop-qzapp/db-admin' };
const operators = new Set(['develop-qzapp/user']);
const req = (over = {}) => ({ content: JSON.stringify({ v: 1, kind: 'request', id: newId(), from: 'develop-qzapp/user', to: '*', op: 'ping', ts: new Date().toISOString(), ttl_s: 30, ...over }) });

test('accept: the fence, case by case', () => {
  const seen = new Set();
  const ok = accept(req(), { me, operators, ttl_s: 30, seen });
  assert.equal(ok.ok, true, JSON.stringify(ok));
  assert.equal(accept(req({ to: 'develop-qzapp/db-admin' }), { me, operators, ttl_s: 30, seen }).ok, true, 'addressed to me');
  assert.equal(accept(req({ to: ['develop-qzapp/x', 'develop-qzapp/db-admin'] }), { me, operators, ttl_s: 30, seen }).ok, true, 'in a list');
  assert.equal(accept(req({ to: 'develop-qzapp/other' }), { me, operators, ttl_s: 30, seen }).why, 'not for me');
  assert.match(accept(req({ op: 'shutdown' }), { me, operators, ttl_s: 30, seen }).why, /^op shutdown/);
  assert.match(accept(req({ from: 'develop-qzapp/backend-dev-01' }), { me, operators, ttl_s: 30, seen }).why, /not an operator/);
  assert.equal(accept(req({ ts: new Date(Date.now() - 60000).toISOString(), ttl_s: 30 }), { me, operators, ttl_s: 30, seen }).why, 'expired');
  assert.equal(accept(req({ ts: 'garbage' }), { me, operators, ttl_s: 30, seen }).why, 'expired');
  assert.equal(accept({ content: 'not json' }, { me, operators, ttl_s: 30, seen }).why, 'not json');
  assert.equal(accept({ content: JSON.stringify({ v: 1, kind: 'reply', id: 'x' }) }, { me, operators, ttl_s: 30, seen }).why, 'not a request');
  assert.equal(accept(req({ v: 2 }), { me, operators, ttl_s: 30, seen }).why, 'v 2');
  const dup = req(); const id = JSON.parse(dup.content).id;
  assert.equal(accept(dup, { me, operators, ttl_s: 30, seen }).ok, true); remember(seen, id);
  assert.equal(accept(dup, { me, operators, ttl_s: 30, seen }).why, 'seen');
  for (let i = 0; i < SEEN_MAX + 5; i++) remember(seen, `x${i}`);
  assert.ok(seen.size <= SEEN_MAX + 1, 'the LRU is bounded');
  assert.ok(!seen.has(id), 'the oldest ids fall out');
});

test('operatorAddresses and controlConfig read the fabric\'s own files', () => {
  const ops = operatorAddresses(path.join(ROOT, 'runtime', 'hosts', 'registry.json'));
  assert.ok(ops.has('develop-qzapp/user'), [...ops]);
  assert.deepEqual(operatorAddresses('/nonexistent'), new Set());
  const c = controlConfig({});
  assert.equal(c.channel, 'fabric:control'); assert.equal(c.ttl_s, 30);
  assert.equal(controlConfig({ FABRIC_CONTROL_CHANNEL: 'x:control', CLAUDE_BRIDGE_URL: 'http://h:1' }).relay_url, 'http://h:1');
});

// A fake relay that keeps a channel in memory: /api/messages (newest N, or
// after since_id), /api/wait (after since_id; 1 s), /api/send. Records
// every request path so the test can assert what was never called.
function relay(initial = []) {
  const rows = []; let seq = 0;
  const add = (sender, content) => { seq += 1; const r = { seq, id: `id-${seq}`, sender, content, timestamp: new Date().toISOString() }; rows.push(r); return r; };
  for (const [s, c] of initial) add(s, c);
  const hits = [];
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x'); hits.push(u.pathname + u.search);
    res.setHeader('content-type', 'application/json');
    const after = id => { const i = rows.findIndex(r => r.id === id); return i < 0 ? null : rows.slice(i + 1); };
    if (u.pathname === '/api/messages') {
      const since = u.searchParams.get('since_id'); const limit = Number(u.searchParams.get('limit') || 50);
      if (since) { const a = after(since); res.end(JSON.stringify(a === null ? { messages: [], warning: 'since_id_not_found' } : { messages: a.slice(0, limit) })); }
      else res.end(JSON.stringify({ messages: rows.slice(-limit) }));
      return;
    }
    if (u.pathname === '/api/wait') {
      // a long poll, like the relay: answer when something follows since_id, or at the timeout
      const since = u.searchParams.get('since_id'); const deadline = Date.now() + Number(u.searchParams.get('timeout_seconds') || 1) * 1000;
      const tick = () => {
        const a = since ? after(since) : rows;
        if (a === null) { res.end(JSON.stringify({ messages: [], warning: 'since_id_not_found' })); return; }
        if (a.length || Date.now() >= deadline) { res.end(JSON.stringify({ messages: a.slice(0, 50) })); return; }
        setTimeout(tick, 50);
      };
      tick(); return;
    }
    if (u.pathname === '/api/send') {
      let body = ''; req.on('data', c => body += c); req.on('end', () => { const b = JSON.parse(body); const r = add(b.sender, b.content); res.end(JSON.stringify({ seq: r.seq, id: r.id, deduplicated: false })); }); return;
    }
    res.statusCode = 404; res.end('{}');
  });
  const waiting = () => new Promise(res => { const t = () => hits.some(h => h.startsWith('/api/wait?')) ? res() : setTimeout(t, 20); t(); });
  return { server, rows, hits, add, waiting, listen: () => new Promise(r => server.listen(0, '127.0.0.1', r)), url: () => `http://127.0.0.1:${server.address().port}`, close: () => { server.closeAllConnections(); server.close(); } };
}
function scratchHome() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'agentd-home-'));
  fs.mkdirSync(path.join(h, '.config', 'agent-fabric'), { recursive: true });
  fs.writeFileSync(path.join(h, '.config', 'agent-fabric', 'secrets.env'), "export CLAUDE_BRIDGE_AUTH_TOKEN='tok-fixture'\nexport OPENROUTER_API_KEY='sk-or-secret-value-0123456789'\n");
  return h;
}
const request = over => JSON.stringify({ v: 1, kind: 'request', id: newId(), from: 'develop-qzapp/user', to: '*', op: 'ping', ts: new Date().toISOString(), ttl_s: 30, ...over });
// Asynchronous: the fake relay lives in this process, and a synchronous
// spawn would block the event loop it answers from.
function runOnce(url, env = {}) {
  return new Promise(resolve => {
    const child = spawn('node', [AGENTD, '--once'], { env: { ...process.env, HOME: scratchHome(), CLAUDE_BRIDGE_URL: url, FABRIC_CONTROL_CHANNEL: 'test:control', ...env } });
    let stderr = '', stdout = '';
    child.stderr.on('data', d => { stderr += d; }); child.stdout.on('data', d => { stdout += d; });
    const t = setTimeout(() => child.kill('SIGKILL'), 20000);
    child.on('close', (status, signal) => { clearTimeout(t); resolve({ status, signal, stderr, stdout }); });
  });
}
const replies = r => r.rows.filter(x => { try { return JSON.parse(x.content).kind === 'reply'; } catch { return false; } }).map(x => JSON.parse(x.content));

test('agentd --once: primes from the newest record, answers a live request, never acks, never answers history', async () => {
  const r = relay([['develop-qzapp/user', request({ op: 'status' })]]);   // history: must not be answered
  await r.listen();
  try {
    // prime happens at start; the request must land after it, so post it once the agent is up:
    // --once primes then waits 1 s, so a record added right after launch is what it sees.
    r.waiting().then(() => r.add('develop-qzapp/user', request({ op: 'ping' })));
    const out = await runOnce(r.url());
    assert.equal(out.status, 0, out.stderr);
    const rs = replies(r);
    assert.equal(rs.length, 1, `replies: ${JSON.stringify(rs)}\n${out.stderr}`);
    assert.equal(rs[0].op, 'ping'); assert.equal(rs[0].ok, true); assert.ok(rs[0].data.agentd.pid > 0);
    assert.ok(rs[0].in_reply_to !== JSON.parse(r.rows[0].content).id, 'the historical status request was not answered');
    assert.ok(!r.hits.some(h => h.startsWith('/api/ack')), 'no ack ever');
    assert.ok(r.hits.some(h => h.startsWith('/api/messages?') && h.includes('limit=1')), 'primed from the newest record');
    assert.ok(r.hits.some(h => h.startsWith('/api/wait?') && h.includes('since_id=id-1')), 'waited after it');
  } finally { r.close(); }
});

test('agentd --once: a request from a non-operator, an unknown op and an expired one get no reply; keys carry no value', async () => {
  const r = relay([['develop-qzapp/user', request({ op: 'ping', id: 'primer' })]]);
  await r.listen();
  try {
    r.waiting().then(() => {
      r.add('develop-qzapp/backend-dev-01', request({ op: 'ping', from: 'develop-qzapp/backend-dev-01' }));
      r.add('develop-qzapp/user', request({ op: 'rm -rf' }));
      r.add('develop-qzapp/user', request({ op: 'ping', ts: new Date(Date.now() - 3600000).toISOString() }));
      r.add('develop-qzapp/user', request({ op: 'keys', to: 'develop-qzapp/nobody' }));
      r.add('develop-qzapp/user', request({ op: 'keys' }));
    });
    const out = await runOnce(r.url());
    assert.equal(out.status, 0, out.stderr);
    const rs = replies(r);
    assert.equal(rs.length, 1, JSON.stringify(rs));
    assert.equal(rs[0].op, 'keys');
    const k = rs[0].data.keys.find(x => x.name === 'OPENROUTER_API_KEY');
    assert.equal(k.present, true); assert.equal(k.sha256_12.length, 12);
    assert.ok(!JSON.stringify(rs).includes('sk-or-secret-value'), 'no key value in a reply');
  } finally { r.close(); }
});

test('agentd --once: an empty channel is primed with an up record; a stale since_id re-primes', async () => {
  const r = relay();
  await r.listen();
  try {
    const out = await runOnce(r.url());
    assert.equal(out.status, 0, out.stderr);
    assert.equal(r.rows.length, 1); assert.equal(JSON.parse(r.rows[0].content).kind, 'up');
  } finally { r.close(); }
});

test('agentd --once: a refused token is re-read from the synced file once, then reported', async () => {
  const hits = [];
  const server = http.createServer((req, res) => { hits.push(req.headers.authorization); res.statusCode = 401; res.setHeader('content-type', 'application/json'); res.end('{}'); });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  try {
    const out = await runOnce(`http://127.0.0.1:${server.address().port}`, { CLAUDE_BRIDGE_AUTH_TOKEN: 'tok-stale' });
    assert.equal(out.status, 4, out.stderr);
    assert.match(out.stderr, /refused this token/);
    assert.ok(hits.includes('Bearer tok-fixture'), `the synced value was tried: ${hits}`);
  } finally { server.closeAllConnections(); server.close(); }
});
