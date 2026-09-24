// bin/fabric-accounts: the setup and the local look at the observed Claude
// accounts. No token ever reaches the output; login needs a terminal and a
// valid account name, and runs the harness in that account's own config
// directory with no inherited token.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { scratch } from '../../../tests/scratch.mjs';
import { main, describe, listLines, templates } from '../accounts.mjs';
import crypto from 'node:crypto';
import { accountsDir } from '../ops.mjs';

const ACCESS = 'sk-ant-oat01-ACCESS-VALUE', REFRESH = 'sk-ant-ort01-REFRESH-VALUE';
function capture(fn) {
  const out = [], err = [];
  const [log, error] = [console.log, console.error];
  console.log = (...a) => out.push(a.join(' ')); console.error = (...a) => err.push(a.join(' '));
  return Promise.resolve(fn()).then(code => ({ code, out: out.join('\n'), err: err.join('\n') })).finally(() => { console.log = log; console.error = error; });
}
function signIn(dir, { expiresAt, refresh = true, email = 'a@example.org' } = {}) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: ACCESS, ...(refresh && { refreshToken: REFRESH }), expiresAt } }));
  fs.writeFileSync(path.join(dir, '.claude.json'), JSON.stringify({ oauthAccount: { emailAddress: email } }));
}

test('list: each account in words — signed in until, lapsed, no refresh token, not signed in — and never a token', async () => {
  const h = scratch('accounts-home-'); const env = {};
  const dir = accountsDir(h, env);
  const now = Date.parse('2026-09-24T20:00:00Z');
  signIn(path.join(dir, 'claude-live'), { expiresAt: now + 3600e3 });
  signIn(path.join(dir, 'claude-lapsed'), { expiresAt: now - 60e3, email: 'b@example.org' });
  signIn(path.join(dir, 'claude-norefresh'), { expiresAt: now + 3600e3, refresh: false, email: 'c@example.org' });
  fs.mkdirSync(path.join(dir, 'claude-new'));
  const lines = listLines(dir, now).join('\n');
  assert.match(lines, /claude-lapsed\s+b@example\.org\s+sign-in lapsed at 2026-09-24T19:59:00\.000Z \(the next read renews it\)/);
  assert.match(lines, /claude-live\s+a@example\.org\s+signed in until 2026-09-24T21:00:00\.000Z/);
  assert.match(lines, /claude-new\s+-\s+not signed in/);
  assert.match(lines, /claude-norefresh\s+c@example\.org\s+signed in, NO refresh token/);
  assert.ok(!lines.includes(ACCESS) && !lines.includes(REFRESH), 'a token reached the output');
  assert.deepEqual(Object.keys(describe(path.join(dir, 'claude-live'), now)).sort(), ['email', 'expired', 'expires_at', 'refresh_token', 'signed_in', 'slug']);
  const { code, out } = await capture(() => main(['list'], { home: h, env }));
  assert.equal(code, 0); assert.match(out, /claude-live/);
  assert.match(listLines(accountsDir(scratch('accounts-empty-'), {})).join('\n'), /no Claude account observed .* fabric-accounts login <account>/);
});

test('login: refuses a bad name and a missing terminal; otherwise runs the harness in the account\'s own 0700 directory, no inherited token', async () => {
  const h = scratch('accounts-login-');
  const env = { PATH: '/usr/bin', CLAUDE_CODE_OAUTH_TOKEN: 'sk-ant-oat01-inherited', ANTHROPIC_API_KEY: 'sk-ant-api-x', KEEP: 'yes' };
  let r = await capture(() => main(['login', 'Not/A Name'], { home: h, env, stdinTTY: true, spawn: () => assert.fail('no harness for a bad name') }));
  assert.equal(r.code, 2);
  r = await capture(() => main(['login', 'claude-a'], { home: h, env, stdinTTY: false, spawn: () => assert.fail('no harness without a terminal') }));
  assert.equal(r.code, 2); assert.match(r.err, /real terminal/);
  const target = path.join(accountsDir(h, env), 'claude-a');
  let seen;
  r = await capture(() => main(['login', 'claude-a'], { home: h, env, stdinTTY: true, spawn: (bin, args, opts) => { seen = opts; signIn(target, { expiresAt: Date.now() + 8 * 3600e3 }); return { status: 0 }; } }));
  assert.equal(r.code, 0, r.err);
  assert.equal(seen.env.CLAUDE_CONFIG_DIR, target);
  assert.equal(seen.cwd, target);
  assert.ok(!('CLAUDE_CODE_OAUTH_TOKEN' in seen.env) && !('ANTHROPIC_API_KEY' in seen.env), 'an inherited token reached the login harness');
  assert.equal(seen.env.KEEP, 'yes', 'the rest of the environment is kept (a terminal needs it)');
  assert.equal(fs.statSync(target).mode & 0o777, 0o700);
  assert.match(r.err, /claude-a signed in as a@example\.org/);
  fs.mkdirSync(path.join(accountsDir(h, env), 'claude-held'), { recursive: true });
  fs.writeFileSync(path.join(accountsDir(h, env), 'claude-held', '.fabric-read.lock'), `${process.ppid}\n`);
  r = await capture(() => main(['login', 'claude-held'], { home: h, env, stdinTTY: true, spawn: () => assert.fail('a /login over a running read') }));
  assert.equal(r.code, 1); assert.match(r.err, /being read right now/);
  assert.ok(!fs.existsSync(path.join(target, '.fabric-read.lock')), 'login released its lock');
  r = await capture(() => main(['login', 'claude-b'], { home: h, env, stdinTTY: true, spawn: () => ({ status: 0 }) }));
  assert.equal(r.code, 1, 'a harness closed without /login is not a success'); assert.match(r.err, /not signed in/);
});

test('read: one line per account from the op; any account not ok is exit 1; none observed is said', async () => {
  const h = scratch('accounts-read-');
  const read = async () => ({ status: 'ok', accounts: [
    { slug: 'claude-a', email: 'a@example.org', status: 'ok', limits: [{ kind: 'session', percent: 11, resets_at: '2026-09-24T18:49:59Z' }, { kind: 'weekly_scoped', percent: 86, resets_at: '2026-09-28T15:59:59Z', model: 'Opus' }] },
    { slug: 'claude-b', email: null, status: 'failed', error: 'Failed to refresh OAuth token' }] });
  const r = await capture(() => main(['read'], { home: h, env: {}, read }));
  assert.equal(r.code, 1);
  assert.match(r.out, /a@example\.org\s+ok\s+session 11% resets 2026-09-24T18:49; weekly_scoped 86% \(Opus\) resets 2026-09-28T15:59/);
  assert.match(r.out, /claude-b\s+failed\s+Failed to refresh OAuth token/);
  const none = await capture(() => main(['read'], { home: h, env: {}, read: async () => ({ status: 'none' }) }));
  assert.equal(none.code, 1); assert.match(none.out, /no Claude account observed/);
  assert.equal((await capture(() => main(['bogus'], { home: h, env: {} }))).code, 2);
});

test('templates: each Doppler template by fingerprint, read with the observer\'s token; the value goes into a hash and nowhere else', async () => {
  const TOK = { 'claude-accounts_claude-a': 'sk-ant-oat01-AAAA', 'claude-accounts_claude-b': '' };
  const calls = [];
  const exec = (bin, args) => {
    calls.push([bin, ...args]);
    if (args[0] === 'configs') return JSON.stringify([{ name: 'claude-accounts' }, { name: 'claude-accounts_claude-b' }, { name: 'claude-accounts_claude-a' }]);
    const cfg = args[args.indexOf('--config') + 1];
    if (!TOK[cfg]) throw new Error('Doppler Error: Could not find requested secret');
    return TOK[cfg] + '\n';   // doppler --plain ends with a newline; the fingerprint must not include it
  };
  const t = templates({ exec });
  const fp = crypto.createHash('sha256').update('sk-ant-oat01-AAAA').digest('hex').slice(0, 12);
  assert.deepEqual(t, [{ account: 'claude-a', config: 'claude-accounts_claude-a', token_sha256_12: fp }, { account: 'claude-b', config: 'claude-accounts_claude-b', token_sha256_12: null }]);
  assert.ok(calls.every(c => c.includes('--project') && c.includes('agent-fabric')), 'every doppler call names the project');
  const r = await capture(() => main(['templates'], { home: scratch('accounts-tpl-'), env: {}, exec }));
  assert.equal(r.code, 1, 'a template without a token is not a clean answer');
  assert.match(r.out, new RegExp(`claude-a\\s+setup-token ${fp}`));
  assert.match(r.out, /claude-b\s+no CLAUDE_CODE_OAUTH_TOKEN/);
  assert.ok(!r.out.includes('sk-ant-oat01-AAAA'));
});
