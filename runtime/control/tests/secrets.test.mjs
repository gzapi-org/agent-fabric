// The `secrets-sync` action against a fake fabric-secrets: it applies what
// the login's own Doppler config says, reports the sign-in by fingerprint,
// never stops a session, and says when one needs a relaunch.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { scratch } from '../../../tests/scratch.mjs';
import { secretsSync } from '../secrets.mjs';
import { table, rows, ACTION_OK } from '../ctl.mjs';

const TPL = 'sk-ant-oat01-TEMPLATE-FIXTURE';
function fixture({ writes = TPL, code = 0, report = {} } = {}) {
  const home = scratch('secrets-home-'); const root = scratch('secrets-root-');
  fs.mkdirSync(path.join(home, '.config', 'agent-fabric'), { recursive: true });
  const calls = [];
  const exec = async (bin, args) => {
    calls.push([path.relative(root, bin), ...args]);
    fs.writeFileSync(path.join(home, '.config', 'agent-fabric', 'secrets.env'), writes ? `export CLAUDE_CODE_OAUTH_TOKEN='${writes}'\n` : 'export GH_TOKEN=x\n');
    if (code) { const e = new Error(`Command failed: fabric-secrets sync --json`); e.code = code; e.stdout = JSON.stringify(report); throw e; }
    return { stdout: JSON.stringify(report) };
  };
  return { home, root, calls, exec };
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
