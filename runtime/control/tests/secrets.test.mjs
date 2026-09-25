// The `secrets-sync` action against a fake fabric-secrets: it applies what
// the login's own Doppler config says, reports the sign-in by fingerprint,
// proves it against the fingerprint it was sent, and — asked to — resumes
// a running session on it through the launcher's restart marker.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { scratch } from '../../../tests/scratch.mjs';
import { secretsSync } from '../secrets.mjs';
import { markerPath } from '../upgrade.mjs';
import { table, rows, ACTION_OK } from '../ctl.mjs';

const TPL = 'sk-ant-oat01-TEMPLATE-FIXTURE';
const fp = v => crypto.createHash('sha256').update(v).digest('hex').slice(0, 12);
function fixture({ writes = TPL, code = 0, report = {}, before = null } = {}) {
  const home = scratch('secrets-home-'); const root = scratch('secrets-root-');
  fs.mkdirSync(path.join(home, '.config', 'agent-fabric'), { recursive: true });
  if (before) fs.writeFileSync(path.join(home, '.config', 'agent-fabric', 'secrets.env'), `export CLAUDE_CODE_OAUTH_TOKEN='${before}'\n`);
  const calls = [];
  const exec = async (bin, args) => {
    calls.push([path.relative(root, bin), ...args]);
    fs.writeFileSync(path.join(home, '.config', 'agent-fabric', 'secrets.env'), writes ? `export CLAUDE_CODE_OAUTH_TOKEN='${writes}'\n` : 'export GH_TOKEN=x\n');
    if (code) { const e = new Error(`Command failed: fabric-secrets sync --json`); e.code = code; e.stdout = JSON.stringify(report); throw e; }
    return { stdout: JSON.stringify(report) };
  };
  return { home, root, calls, exec, dir: path.join(home, 'state') };
}

test('a template in the login\'s config: synced, named by fingerprint, the value nowhere', async () => {
  const f = fixture();
  const r = await secretsSync({ id: 'x' }, { home: f.home, root: f.root, exec: f.exec, sessions: [] });
  assert.deepEqual(f.calls, [['bin/fabric-secrets', 'sync', '--json']], 'the login\'s own fabric-secrets, nothing else');
  assert.deepEqual(r, { status: 'synced', claude_sign_in: { via: 'setup-token', token_sha256_12: crypto.createHash('sha256').update(TPL).digest('hex').slice(0, 12) }, session: 'none' });
  assert.ok(!JSON.stringify(r).includes(TPL));
});

test('no template: its own sign-in; names missing in Doppler are applied around and said; a running session is told to relaunch', async () => {
  const f = fixture({ writes: null, code: 2, report: { missing: ['SSH_PRIVATE_KEY'] } });
  const r = await secretsSync({ id: 'x' }, { home: f.home, root: f.root, exec: f.exec, sessions: [4242] });
  assert.deepEqual(r, { status: 'synced', claude_sign_in: { via: 'none: its next session is refused' }, missing: ['SSH_PRIVATE_KEY'], session: 'running: relaunch to use it' });
});

test('a sync that applied nothing is a failure with its reason; arguments are refused before anything runs', async () => {
  const f = fixture({ code: 3, report: { error: 'config agents_x names AGENT_LOGIN=y, this login is x; nothing applied' } });
  const r = await secretsSync({ id: 'x' }, { home: f.home, root: f.root, exec: f.exec, sessions: [] });
  assert.deepEqual([r.status, r.reason], ['failed', 'config agents_x names AGENT_LOGIN=y, this login is x; nothing applied']);
  const g = fixture();
  const refused = await secretsSync({ id: 'x', args: { config: 'agents_other' } }, { home: g.home, root: g.root, exec: g.exec, sessions: [] });
  assert.equal(refused.status, 'refused'); assert.equal(g.calls.length, 0, 'nothing ran');
});

test('fabric-ctl secrets-sync: one row per account with the sign-in and the session; only synced is success', () => {
  const expected = [{ login: 'flutter-dev-01', host: 'h', address: 'h/flutter-dev-01' }, { login: 'web-dev-01', host: 'h', address: 'h/web-dev-01' }];
  const t = table('secrets-sync', rows(expected, [{ kind: 'reply', from: 'h/flutter-dev-01', op: 'secrets-sync', data: { 'secrets-sync': { status: 'synced', claude_sign_in: { via: 'setup-token', token_sha256_12: '183a68e97389' }, session: 'running: relaunch to use it' } } }])).split('\n');
  assert.match(t[1], /^flutter-dev-01\s+synced\s+setup-token 183a68e97389\s+running: relaunch to use it$/);
  assert.match(t[2], /^web-dev-01\s+no answer$/);
  assert.deepEqual(ACTION_OK['secrets-sync'], ['synced']);
});

test('expect: the synced token must be the template\'s; another one is a failure, and nothing is stopped', async () => {
  const f = fixture();
  assert.equal((await secretsSync({ id: 'x', args: { expect: fp(TPL) } }, { home: f.home, root: f.root, exec: f.exec, sessions: [] })).status, 'synced');
  const g = fixture({ writes: 'sk-ant-oat01-SOMEONE-ELSE' });
  const r = await secretsSync({ id: 'x', args: { expect: fp(TPL), restart: true } }, { home: g.home, root: g.root, exec: g.exec, dir: g.dir, sessions: [7], kill: () => assert.fail('nothing stopped on a mismatch') });
  assert.equal(r.status, 'failed'); assert.match(r.reason, new RegExp(`holds setup-token ${fp('sk-ant-oat01-SOMEONE-ELSE')}, not the expected ${fp(TPL)}; nothing restarted`));
  assert.ok(!fs.existsSync(markerPath(g.dir)));
  for (const args of [{ expect: 'XYZ' }, { restart: 'yes' }, { config: 'agents_other' }, []]) {
    const h = fixture();
    const x = await secretsSync({ id: 'x', args }, { home: h.home, root: h.root, exec: h.exec, sessions: [] });
    assert.equal(x.status, 'refused', JSON.stringify(args)); assert.equal(h.calls.length, 0);
  }
});

test('restart: the marker first, already done, then SIGTERM; the launcher resumes the session on the new sign-in', async () => {
  const OLD = 'sk-ant-oat01-OLD-ACCOUNT';
  const f = fixture({ before: OLD });
  let up = true; const order = [];
  const kill = (pid, sig) => { const m = JSON.parse(fs.readFileSync(markerPath(f.dir))); order.push(`${sig} ${pid} marker=${m.status}`); up = false; };
  const r = await secretsSync({ id: 'req-9', from: 'h/user', args: { expect: fp(TPL), restart: true } }, { home: f.home, root: f.root, exec: f.exec, dir: f.dir, sessions: [55], me: 'h/web-dev-01', kill, alive: () => up, sleep: async () => {}, now: () => new Date('2026-09-25T12:00:00Z') });
  assert.deepEqual([r.status, r.session], ['synced', 'restarting']);
  assert.deepEqual(order, ['SIGTERM 55 marker=done'], 'the marker is written, done, before the session is signalled');
  const m = JSON.parse(fs.readFileSync(markerPath(f.dir)));
  assert.deepEqual([m.piece, m.from, m.installed, m.request_id], ['the Claude account', `setup-token ${fp(OLD)}`, `setup-token ${fp(TPL)}`, 'req-9']);
  assert.ok(!JSON.stringify(m).includes('sk-ant-oat01'), 'fingerprints only, in the marker too');
});

test('restart spares the requester\'s own session, a session already on the token, and forces none that will not stop', async () => {
  const own = fixture({ before: 'sk-ant-oat01-OLD-ACCOUNT' });
  const r1 = await secretsSync({ id: 'x', from: 'h/user', args: { restart: true } }, { home: own.home, root: own.root, exec: own.exec, dir: own.dir, sessions: [1], me: 'h/user', kill: () => assert.fail('own session stopped') });
  assert.equal(r1.session, 'yours: relaunch to use it');
  const same = fixture({ before: TPL });
  const r2 = await secretsSync({ id: 'x', from: 'h/user', args: { restart: true } }, { home: same.home, root: same.root, exec: same.exec, dir: same.dir, sessions: [2], me: 'h/db-admin', kill: () => assert.fail('a session already on it was stopped') });
  assert.equal(r2.session, 'running, already on it');
  const stuck = fixture({ before: 'sk-ant-oat01-OLD-ACCOUNT' });
  const sigs = [];
  const r3 = await secretsSync({ id: 'x', from: 'h/user', args: { restart: true } }, { home: stuck.home, root: stuck.root, exec: stuck.exec, dir: stuck.dir, sessions: [3], me: 'h/db-admin', kill: (p, s) => sigs.push(s), alive: () => true, sleep: async () => {}, stopWaitMs: 0 });
  assert.equal(r3.status, 'synced'); assert.match(r3.session, /did not stop .*nothing forced/);
  assert.deepEqual(sigs, ['SIGTERM']);
  assert.ok(!fs.existsSync(markerPath(stuck.dir)), 'no marker left to resume the session whenever it is ended later');
});
