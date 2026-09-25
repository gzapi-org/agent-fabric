// runtime/control/secrets.mjs — the control agent's second ACTION: re-sync
// this account's secrets from Doppler (bin/fabric-secrets sync), so a change
// the coordinator made to the login's config — which Claude account it runs
// on (`fabric-accounts assign`, docs/claude-accounts.md) — reaches the
// account without anyone logging in to it.
//
// An action, signed, for the same reason `upgrade` is: it changes what the
// account's next session runs on. What it applies is whatever the login's
// own Doppler config says, read with the login's own read-only token; the
// request only says what to expect and whether to act on it now:
//
//   expect   the fingerprint the coordinator's template holds. The synced
//            token must match it, or the sync is a failure: a move the
//            account did not take is said by the account, not assumed.
//   restart  a running session is stopped (SIGTERM, never harder) and its
//            launcher resumes it on the new sign-in — the upgrade's restart
//            marker, written already done: nothing is left to wait for. The
//            requester's own session is never stopped (it is waiting for
//            the reply). Without it a running session keeps the sign-in it
//            started with, and the reply says it needs a relaunch.
//
// So a move is messages end to end: `fabric-accounts assign` writes the
// reference, and every account applies, verifies and restarts by itself.
// What comes back names the sign-in by fingerprint, never by value.

import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { syncedVar } from '../../communication/gzcoord/scripts/inbox.mjs';
import fs from 'node:fs';
import { sessionPids, stateDir, writeMarker, markerPath, STOP_WAIT_MS } from './upgrade.mjs';

const execFileP = promisify(execFile);
export const SYNC_TIMEOUT_MS = 120000;
const SHA12 = /^[0-9a-f]{12}$/;
const sha12 = v => crypto.createHash('sha256').update(v).digest('hex').slice(0, 12);

export function checkArgs(args) {
  if (args === undefined) return null;
  if (typeof args !== 'object' || args === null || Array.isArray(args)) return 'secrets-sync takes { expect, restart }';
  const extra = Object.keys(args).filter(k => !['expect', 'restart'].includes(k));
  if (extra.length) return `secrets-sync takes only expect and restart, not ${extra.join(', ')}`;
  if (args.expect !== undefined && !SHA12.test(String(args.expect))) return 'expect is a 12-hex fingerprint';
  if (args.restart !== undefined && typeof args.restart !== 'boolean') return 'restart is true or false';
  return null;
}

// fabric-secrets sync's exit codes: 0 applied, 2 applied with names
// missing in Doppler (the env file is still written), 1 Doppler unreadable,
// 3 the config names another login. Only the first two changed anything.
const APPLIED = new Set([0, 2]);

export async function secretsSync(request, {
  home = os.homedir(), root = process.env.AGENT_FABRIC_ROOT ?? path.join(home, 'projects', 'agent-fabric'),
  exec = execFileP, sessions = null, me = null, dir = stateDir(home), now = () => new Date(),
  kill = process.kill.bind(process), alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } },
  sleep = ms => new Promise(r => setTimeout(r, ms)), stopWaitMs = STOP_WAIT_MS,
} = {}) {
  const bad = checkArgs(request.args);
  if (bad) return { status: 'refused', reason: bad };
  const { expect = null, restart = false } = request.args ?? {};
  const before = syncedVar('CLAUDE_CODE_OAUTH_TOKEN', home);
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
  const sign = tok ? { via: 'setup-token', token_sha256_12: sha12(tok) } : { via: 'none: its next session is refused' };
  const missing = Array.isArray(report.missing) && report.missing.length ? { missing: report.missing } : {};
  if (expect && sign.token_sha256_12 !== expect)
    return { status: 'failed', claude_sign_in: sign, ...missing, reason: `the synced record holds ${sign.token_sha256_12 ? `setup-token ${sign.token_sha256_12}` : 'no token'}, not the expected ${expect}; nothing restarted` };
  let running = [];
  try { running = sessions ?? sessionPids({ exec: (c, a) => execFileSync(c, a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) }); }
  catch { running = null; }
  const done = session => ({ status: 'synced', claude_sign_in: sign, ...missing, session });
  if (running === null) return done('unknown');
  if (!running.length) return done('none');
  const own = me && request.from === me;
  const changed = !before || sha12(before) !== sign.token_sha256_12;
  if (!restart || own || !changed) return done(own && changed ? 'yours: relaunch to use it' : changed ? 'running: relaunch to use it' : 'running, already on it');
  // The launcher reads the marker after the session's GOODBYE: written
  // first, and done already, so it resumes at once on what was synced.
  writeMarker(dir, { request_id: request.id, requested_at: now().toISOString(), piece: 'the Claude account', from: before ? `setup-token ${sha12(before)}` : 'no token', to: `setup-token ${sign.token_sha256_12}`, installed: `setup-token ${sign.token_sha256_12}`, pids: running, status: 'done' });
  for (const pid of running) { try { kill(pid, 'SIGTERM'); } catch { /* gone */ } }
  const until = Date.now() + stopWaitMs;
  while (running.some(alive) && Date.now() < until) await sleep(500);
  // Not stopped: the marker goes, or the session would be resumed the
  // moment it is ended on purpose, long after this action.
  if (running.some(alive)) { fs.rmSync(markerPath(dir), { force: true }); return done(`did not stop within ${Math.round(stopWaitMs / 1000)} s (pid ${running.filter(alive).join(', ')}); nothing forced — relaunch to use it`); }
  return done('restarting');
}
