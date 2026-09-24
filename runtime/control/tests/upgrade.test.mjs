// The `upgrade` action, against a fake harness: at the pin nothing moves;
// a running session is stopped gracefully (SIGTERM, never SIGKILL) with the
// launcher's restart marker written first; the install is verified; the
// requester's own session is never stopped; every failure is said.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { scratch } from '../../../tests/scratch.mjs';
import { upgrade, upgradeOnce, checkArgs, markerPath, pinnedVersion, sessionPids } from '../upgrade.mjs';

function fixture({ installed = '2.1.280', pin = '2.1.281', installFails = false, installsWrong = false } = {}) {
  const home = scratch('upgrade-home-');
  const root = scratch('upgrade-root-');
  fs.mkdirSync(path.join(root, 'runtime', 'claude-code'), { recursive: true });
  if (pin) fs.writeFileSync(path.join(root, 'runtime', 'claude-code', 'harness.json'), JSON.stringify({ claude: pin }));
  const dir = path.join(home, 'state');
  const calls = [];
  let current = installed;
  const exec = async (bin, args) => {
    calls.push(args.join(' '));
    if (args[0] === '--version') return { stdout: `${current} (Claude Code)\n` };
    if (args[0] === 'install') { if (installFails) throw new Error('Install failed: network\nmore'); current = installsWrong ? '2.1.279' : args[1]; return { stdout: '' }; }
    throw new Error('unexpected ' + args.join(' '));
  };
  return { home, root, dir, calls, exec, get current() { return current; } };
}
const req = (over = {}) => ({ id: 'req-1', from: 'h/user', op: 'upgrade', args: { piece: 'claude' }, ...over });

test('at the pin: nothing is installed and no session is touched', async () => {
  const f = fixture({ installed: '2.1.281' });
  const killed = [];
  const r = await upgradeOnce(req(), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [111], kill: pid => killed.push(pid), me: 'h/db-admin' });
  assert.deepEqual(r, { status: 'current', piece: 'claude', version: '2.1.281', session: 'running' });
  assert.deepEqual(killed, []); assert.ok(!f.calls.some(c => c.startsWith('install')));
  assert.ok(!fs.existsSync(markerPath(f.dir)));
});

test('a running session: the marker first, then SIGTERM, wait, install, verify, marker done', async () => {
  const f = fixture();
  const order = [];
  let alive = true;
  const kill = (pid, sig) => { order.push(`kill ${pid} ${sig}`); assert.equal(JSON.parse(fs.readFileSync(markerPath(f.dir))).status, 'pending', 'the marker is written before the session is signalled'); alive = false; };
  const r = await upgradeOnce(req(), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [4242], kill, alive: () => alive, sleep: async () => {}, me: 'h/db-admin', now: () => new Date('2026-09-24T21:00:00Z') });
  assert.deepEqual(r, { status: 'upgraded', piece: 'claude', from: '2.1.280', to: '2.1.281', session: 'restarting' });
  assert.deepEqual(order, ['kill 4242 SIGTERM']);
  assert.deepEqual(f.calls, ['--version', 'install 2.1.281', '--version']);
  const m = JSON.parse(fs.readFileSync(markerPath(f.dir)));
  assert.deepEqual([m.status, m.from, m.to, m.installed, m.request_id, m.pids], ['done', '2.1.280', '2.1.281', '2.1.281', 'req-1', [4242]]);
  assert.equal(fs.statSync(markerPath(f.dir)).mode & 0o777, 0o600);
});

test('no session: installed, no marker, nothing signalled', async () => {
  const f = fixture();
  const r = await upgradeOnce(req(), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [], kill: () => assert.fail('nothing to signal'), me: 'h/db-admin' });
  assert.equal(r.status, 'upgraded'); assert.equal(r.session, 'none');
  assert.ok(!fs.existsSync(markerPath(f.dir)));
});

test('the requester\'s own session is never stopped: installed under it, and told to relaunch', async () => {
  const f = fixture();
  const r = await upgradeOnce(req({ from: 'h/user' }), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [777], kill: () => assert.fail('own session signalled'), me: 'h/user' });
  assert.deepEqual([r.status, r.session], ['upgraded', 'yours: relaunch to use it']);
  assert.ok(!fs.existsSync(markerPath(f.dir)), 'no restart marker for a session nobody stopped');
});

test('a session that does not stop: not installed, not forced, the marker says failed', async () => {
  const f = fixture();
  const sigs = [];
  const r = await upgradeOnce(req(), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [5], kill: (p, s) => sigs.push(s), alive: () => true, sleep: async () => {}, stopWaitMs: 0, me: 'h/db-admin' });
  assert.equal(r.status, 'failed'); assert.match(r.reason, /did not stop .* nothing forced/);
  assert.deepEqual(sigs, ['SIGTERM'], 'never a second, harder signal');
  assert.ok(!f.calls.some(c => c.startsWith('install')));
  assert.equal(JSON.parse(fs.readFileSync(markerPath(f.dir))).status, 'failed', 'the launcher relaunches on what is installed and says why');
});

test('an install that fails, or lands another version, is a failure with its reason; the marker lets the session come back anyway', async () => {
  for (const [opts, re] of [[{ installFails: true }, /claude install 2\.1\.281: Install failed: network$/], [{ installsWrong: true }, /after install, claude --version says 2\.1\.279/]]) {
    const f = fixture(opts);
    let alive = true;
    const r = await upgradeOnce(req(), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [9], kill: () => { alive = false; }, alive: () => alive, sleep: async () => {}, me: 'h/db-admin' });
    assert.equal(r.status, 'failed'); assert.match(r.reason, re);
    assert.equal(JSON.parse(fs.readFileSync(markerPath(f.dir))).status, 'failed');
  }
});

test('arguments are a closed set; no pin is a refusal; --version overrides the pin; one upgrade at a time', async () => {
  assert.match(checkArgs({ piece: 'fabric' }), /not one of claude/);
  assert.match(checkArgs({ piece: 'claude', version: '2.1.281; rm -rf /' }), /digits/);
  assert.match(checkArgs(null), /no arguments/);
  assert.equal(checkArgs({ piece: 'claude', version: '2.1.282' }), null);
  const f = fixture({ pin: null });
  assert.match((await upgradeOnce(req(), { home: f.home, root: f.root, dir: f.dir, exec: f.exec, sessions: [] })).reason, /no pinned version/);
  const g = fixture();
  const r = await upgradeOnce(req({ args: { piece: 'claude', version: '2.1.279' } }), { home: g.home, root: g.root, dir: g.dir, exec: g.exec, sessions: [] });
  assert.equal(r.to, '2.1.279');
  assert.equal(pinnedVersion(g.root), '2.1.281');
  let release; const gate = new Promise(res => { release = res; });
  const slow = fixture();
  const first = upgrade(req(), { home: slow.home, root: slow.root, dir: slow.dir, sessions: [], exec: async (b, a) => { if (a[0] === 'install') await gate; return slow.exec(b, a); } });
  assert.equal((await upgrade(req({ id: 'req-2' }), {})).status, 'busy');
  release(); assert.equal((await first).status, 'upgraded');
});

test('sessionPids: this uid\'s claude processes, except the daemon\'s own children (the observer\'s /usage runs)', () => {
  const proc = scratch('upgrade-proc-');
  for (const [pid, ppid] of [[100, 50], [200, 999], [300, 60]]) { fs.mkdirSync(path.join(proc, String(pid))); fs.writeFileSync(path.join(proc, String(pid), 'stat'), `${pid} (claude) S ${ppid} 1 1 0 -1`); }
  assert.deepEqual(sessionPids({ self: 999, proc, exec: () => '100\n200\n300\n400\n' }), [100, 300], 'the daemon\'s child and a pid already gone are left out');
  assert.deepEqual(sessionPids({ self: 999, proc, exec: () => { throw new Error('exit 1'); } }), [], 'pgrep finding nothing is no session');
});
