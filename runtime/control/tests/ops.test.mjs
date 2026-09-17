// The control agent's extractors, against a scratch home: every section
// says what it knows or why not, and no output ever carries a secret value.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { identity, usage, keys, fabric, session, collect, KEY_NAMES, OPS } from '../ops.mjs';

const SECRETS = { OPENROUTER_API_KEY: 'sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789', GH_TOKEN: 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', CLAUDE_BRIDGE_AUTH_TOKEN: 'bridge-token-value-1234567890' };
const ACCESS = 'oauth-access-token-value-XYZ';
function home() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-home-'));
  fs.mkdirSync(path.join(h, '.config', 'agent-fabric'), { recursive: true });
  fs.mkdirSync(path.join(h, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(h, '.config', 'agent-fabric', 'secrets.env'), Object.entries(SECRETS).map(([k, v]) => `export ${k}='${v}'`).join('\n') + '\n');
  fs.writeFileSync(path.join(h, '.claude', '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: ACCESS, refreshToken: 'refresh-XYZ', subscriptionType: 'max' } }));
  fs.writeFileSync(path.join(h, '.claude.json'), JSON.stringify({ oauthAccount: { emailAddress: 'someone@example.org', organizationName: 'Example Org', accountUuid: 'u-1' } }));
  return h;
}
const who = { agent: 'db-admin', host: 'develop-qzapp', role: 'db-admin', project: 'gzapp', working_copy: '/home/db-admin/projects/gzapp' };
function assertNoSecret(obj) {
  const s = JSON.stringify(obj);
  for (const v of [...Object.values(SECRETS), ACCESS, 'refresh-XYZ']) assert.ok(!s.includes(v), `a secret value leaked into the output: ${v.slice(0, 6)}…`);
}

test('identity: the account and the Claude account it is signed into, no secret', () => {
  const h = home();
  const id = identity(h, who);
  assert.deepEqual(id, { agent: 'db-admin', host: 'develop-qzapp', role: 'db-admin', project: 'gzapp', working_copy: '/home/db-admin/projects/gzapp',
                         claude_account: { email: 'someone@example.org', organization: 'Example Org' }, credentials_present: true });
  assertNoSecret(id);
  fs.unlinkSync(path.join(h, '.claude.json'));
  assert.equal(identity(h, who).claude_account, null, 'no profile record: null, not a throw');
});

test('usage: the two windows through the account\'s own token, which goes into one header and nowhere else', async () => {
  const h = home();
  const seen = [];
  const fetchOk = async (url, init) => { seen.push({ url, auth: init.headers.Authorization, beta: init.headers['anthropic-beta'] });
    return { ok: true, status: 200, json: async () => ({ five_hour: { utilization: 12.5, resets_at: '2026-09-17T10:00:00+00:00' }, seven_day: { utilization: 80, resets_at: '2026-09-21T16:00:00+00:00' } }) }; };
  const u = await usage(h, fetchOk);
  assert.deepEqual(u, { status: 'ok', five_hour: { utilization: 12.5, resets_at: '2026-09-17T10:00:00+00:00' }, seven_day: { utilization: 80, resets_at: '2026-09-21T16:00:00+00:00' }, subscription: 'max' });
  assert.equal(seen[0].auth, `Bearer ${ACCESS}`); assert.equal(seen[0].beta, 'oauth-2025-04-20');
  assertNoSecret(u);
  assert.deepEqual(await usage(h, async () => ({ ok: false, status: 401 })), { status: 'read-failed', http: 401 });
  assert.deepEqual(await usage(h, async () => { throw new Error('ECONNREFUSED'); }), { status: 'read-failed' });
  assert.deepEqual(await usage(h, async () => ({ ok: true, status: 200, json: async () => { throw new Error('bad json'); } })), { status: 'unreadable' });
  fs.unlinkSync(path.join(h, '.claude', '.credentials.json'));
  assert.deepEqual(await usage(h, fetchOk), { status: 'no-credentials' });
});

test('keys: names and twelve-digit fingerprints, never a value; an absent key says so', () => {
  const h = home();
  const k = keys(h);
  assert.deepEqual(k.map(x => x.name), KEY_NAMES);
  const or = k.find(x => x.name === 'OPENROUTER_API_KEY');
  assert.equal(or.present, true);
  assert.equal(or.sha256_12, crypto.createHash('sha256').update(SECRETS.OPENROUTER_API_KEY).digest('hex').slice(0, 12));
  assert.deepEqual(k.find(x => x.name === 'OPENAI_API_KEY'), { name: 'OPENAI_API_KEY', present: false });
  assertNoSecret(k);
  assert.deepEqual(keys('/nonexistent').map(x => x.present), [false, false, false, false]);
});

test('fabric: head, branch, behind, dirty, through a fake git; a fetch that fails is said', async () => {
  const calls = [];
  const exec = (cmd, args) => { calls.push(args.slice(2).join(' '));
    const a = args.slice(2).join(' ');
    if (a.startsWith('rev-parse --short')) return 'abc1234\n';
    if (a.startsWith('rev-parse --abbrev-ref')) return 'main\n';
    if (a.startsWith('status')) return '';
    if (a.startsWith('fetch')) throw new Error('offline');
    if (a.startsWith('rev-list')) return '3\n';
    return ''; };
  assert.deepEqual(await fabric('/some/root', exec), { status: 'ok', root: '/some/root', head: 'abc1234', branch: 'main', dirty: false, fetch: 'failed', behind: 3 });
  assert.equal((await fabric('/no/checkout', () => { throw new Error('not a git repository'); })).status, 'not-a-checkout');
  const asyncExec = async (...a) => ({ stdout: exec(...a) });   // the real execFile shape
  assert.equal((await fabric('/some/root', asyncExec)).head, 'abc1234');
});

test('session: counts the harness processes of the uid; none is zero, not a throw', () => {
  const s = session(4242, (cmd, args) => { assert.deepEqual(args, ['-u', '4242', '-x', 'claude']); return '111\n222\n'; });
  assert.equal(s.claude_processes, 2); assert.equal(typeof s.planning, 'boolean');
  assert.equal(session(4242, () => { throw Object.assign(new Error('no match'), { status: 1 }); }).claude_processes, 0);
});

test('collect: status is every section, a single op its own, and a failing section is inline', async () => {
  const h = home();
  const ctx = { home: h, who, fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }), root: '/r', exec: () => { throw new Error('boom'); }, uid: 1 };
  const all = await collect('status', ctx);
  assert.deepEqual(Object.keys(all).sort(), ['fabric', 'identity', 'keys', 'session', 'usage']);
  assert.equal(all.fabric.status, 'not-a-checkout');
  assert.equal(all.session.claude_processes, 0);
  assertNoSecret(all);
  const one = await collect('keys', ctx);
  assert.deepEqual(Object.keys(one), ['keys']);
  assert.ok(OPS.includes('ping') && OPS.includes('status'));
});
