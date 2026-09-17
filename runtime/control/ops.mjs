// runtime/control/ops.mjs — what a control agent can say about its own
// account, as pure extractors: each takes its inputs (a home, a fetch, an
// exec) so a test runs them against a scratch home and a fake relay, and
// each returns only fixed, whitelisted keys — never a value from a secret.
// The fingerprints are the one place a secret is read: hashed in place,
// twelve hex digits of its sha256, enough to tell two keys apart and
// nothing else (the CEO, 2026-09-17: "the username it logs in with, or
// the api key hash").
//
// A section that cannot be read says so inline ({status: ...}) rather than
// throwing: a reply always arrives, and its gaps are named.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { whoami } from '../../communication/gzcoord/scripts/gzmsg.mjs';
import { syncedVar, holdStatus } from '../../communication/gzcoord/scripts/inbox.mjs';

export const OPS = ['ping', 'identity', 'usage', 'keys', 'fabric', 'session', 'status'];
export const KEY_NAMES = ['OPENROUTER_API_KEY', 'OPENAI_API_KEY', 'GH_TOKEN', 'CLAUDE_BRIDGE_AUTH_TOKEN'];
export const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

// Who this account is, and which Claude account it is signed into.
export function identity(home = os.homedir(), who = whoami()) {
  const claude = readJson(path.join(home, '.claude.json'))?.oauthAccount ?? null;
  return {
    agent: who.agent ?? null, host: who.host ?? null, role: who.role ?? null,
    project: who.project ?? null, working_copy: who.working_copy ?? null,
    claude_account: claude ? { email: claude.emailAddress ?? null, organization: claude.organizationName ?? null } : null,
    credentials_present: fs.existsSync(path.join(home, '.claude', '.credentials.json')),
  };
}

// The five-hour and seven-day windows, read with the account's own OAuth
// token, which goes into one header and nowhere else.
export async function usage(home = os.homedir(), fetchFn = globalThis.fetch, url = USAGE_URL) {
  const creds = readJson(path.join(home, '.claude', '.credentials.json'));
  const tok = creds?.claudeAiOauth?.accessToken;
  if (!tok) return { status: 'no-credentials' };
  let r;
  try {
    r = await fetchFn(url, { headers: { Authorization: `Bearer ${tok}`, 'anthropic-beta': 'oauth-2025-04-20' }, signal: AbortSignal.timeout(15000) });
  } catch { return { status: 'read-failed' }; }
  if (!r.ok) return { status: 'read-failed', http: r.status };
  let u;
  try { u = await r.json(); } catch { return { status: 'unreadable' }; }
  const win = w => (w && typeof w === 'object') ? { utilization: w.utilization ?? null, resets_at: w.resets_at ?? null } : null;
  return { status: 'ok', five_hour: win(u.five_hour), seven_day: win(u.seven_day), subscription: creds?.claudeAiOauth?.subscriptionType ?? null };
}

// Which keys the account holds, by name and fingerprint; never a value.
export function keys(home = os.homedir(), names = KEY_NAMES) {
  return names.map(name => {
    const v = syncedVar(name, home);
    return v ? { name, present: true, sha256_12: crypto.createHash('sha256').update(v).digest('hex').slice(0, 12) } : { name, present: false };
  });
}

// The fabric checkout the account runs on: head, branch, how far behind
// origin/main, and whether the tree is clean. A fetch that cannot reach
// origin is said, not hidden. Asynchronous: the fetch may take its whole
// 10 s budget and the daemon keeps reading the channel meanwhile (exec
// may return a string or a {stdout}; a test passes a synchronous fake).
const execFileP = promisify(execFile);
export async function fabric(root = process.env.AGENT_FABRIC_ROOT ?? path.join(os.homedir(), 'projects', 'agent-fabric'), exec = execFileP) {
  const git = async (...a) => { const r = await exec('git', ['-C', root, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 10000 }); return (typeof r === 'string' ? r : r.stdout).trim(); };
  const out = { root };
  try { out.head = await git('rev-parse', '--short', 'HEAD'); } catch { return { ...out, status: 'not-a-checkout' }; }
  try { out.branch = await git('rev-parse', '--abbrev-ref', 'HEAD'); } catch { out.branch = null; }
  try { out.dirty = (await git('status', '--porcelain')).length > 0; } catch { out.dirty = null; }
  try { await git('fetch', '-q', 'origin', 'main'); out.fetch = 'ok'; } catch { out.fetch = 'failed'; }
  try { out.behind = Number(await git('rev-list', '--count', 'HEAD..origin/main')); } catch { out.behind = null; }
  return { status: 'ok', ...out };
}

// Whether a harness runs as this account, and whether it is planning.
export function session(uid = process.getuid(), exec = execFileSync) {
  let n = 0;
  try { n = exec('pgrep', ['-u', String(uid), '-x', 'claude'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim().split('\n').filter(Boolean).length; }
  catch { n = 0; }   // pgrep exits 1 when nothing matches
  return { claude_processes: n, planning: holdStatus().held };
}

// Everything, for `status`; the sections a request names, otherwise.
export async function collect(op, ctx = {}) {
  const wants = op === 'status' ? ['identity', 'usage', 'keys', 'fabric', 'session'] : [op];
  const data = {};
  const guard = async (name, fn) => { try { data[name] = await fn(); } catch (e) { data[name] = { status: 'failed', error: String(e?.message ?? e).slice(0, 200) }; } };
  await Promise.all(wants.map(name => {
    if (name === 'identity') return guard(name, () => identity(ctx.home, ctx.who));   // ctx.who unset: whoami() per request, so a rebind shows
    if (name === 'usage') return guard(name, () => ctx.usageCached ? ctx.usageCached() : usage(ctx.home, ctx.fetch));
    if (name === 'keys') return guard(name, () => keys(ctx.home));
    if (name === 'fabric') return guard(name, () => fabric(ctx.root, ctx.exec));
    if (name === 'session') return guard(name, () => session(ctx.uid, ctx.exec));
    return Promise.resolve();
  }));
  return data;
}
