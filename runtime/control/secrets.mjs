// runtime/control/secrets.mjs — the control agent's second ACTION: re-sync
// this account's secrets from Doppler (bin/fabric-secrets sync), so a change
// the coordinator made to the login's config — which Claude account it runs
// on (`fabric-accounts assign`, docs/claude-accounts.md) — reaches the
// account without anyone logging in to it.
//
// An action, signed, for the same reason `upgrade` is: it changes what the
// account's next session runs on. It takes no arguments — what it applies is
// whatever the login's own Doppler config says, read with the login's own
// read-only token — and it stops nothing: a running session keeps the
// sign-in it started with, and the reply says it needs a relaunch.
//
// What comes back names the sign-in by fingerprint, never by value.

import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { syncedVar } from '../../communication/gzcoord/scripts/inbox.mjs';
import { sessionPids } from './upgrade.mjs';

const execFileP = promisify(execFile);
export const SYNC_TIMEOUT_MS = 120000;

// fabric-secrets sync's exit codes: 0 applied, 2 applied with names
// missing in Doppler (the env file is still written), 1 Doppler unreadable,
// 3 the config names another login. Only the first two changed anything.
const APPLIED = new Set([0, 2]);

export async function secretsSync(request, {
  home = os.homedir(), root = process.env.AGENT_FABRIC_ROOT ?? path.join(home, 'projects', 'agent-fabric'),
  exec = execFileP, sessions = null,
} = {}) {
  if (request.args !== undefined && (typeof request.args !== 'object' || request.args === null || Object.keys(request.args).length))
    return { status: 'refused', reason: 'secrets-sync takes no arguments' };
  let code = 0, out = '';
  try {
    const r = await exec(path.join(root, 'bin', 'fabric-secrets'), ['sync', '--json'], { encoding: 'utf8', timeout: SYNC_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'] });
    out = typeof r === 'string' ? r : r.stdout;
  } catch (e) {
    code = typeof e?.code === 'number' ? e.code : -1;
    out = e?.stdout ?? '';
    if (code === -1) return { status: 'failed', reason: `fabric-secrets: ${String(e?.message ?? e).split('\n')[0].slice(0, 160)}` };
  }
  let report = {};
  try { report = JSON.parse(out); } catch { /* the reason below says so */ }
  if (!APPLIED.has(code)) return { status: 'failed', reason: String(report.error ?? `fabric-secrets sync exited ${code}`).slice(0, 200) };
  const tok = syncedVar('CLAUDE_CODE_OAUTH_TOKEN', home);
  let running = [];
  try { running = sessions ?? sessionPids({ exec: (c, a) => execFileSync(c, a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) }); }
  catch { running = null; }
  return {
    status: 'synced',
    claude_sign_in: tok ? { via: 'setup-token', token_sha256_12: crypto.createHash('sha256').update(tok).digest('hex').slice(0, 12) } : { via: 'none: its next session is refused' },
    ...(Array.isArray(report.missing) && report.missing.length ? { missing: report.missing } : {}),
    session: running === null ? 'unknown' : running.length ? 'running: relaunch to use it' : 'none',
  };
}
