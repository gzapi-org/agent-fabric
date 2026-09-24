// runtime/control/upgrade.mjs — the control agent's first ACTION: bring a
// piece of the account's software to the version the fabric pins, and
// have a running session come back on it. Only `claude` (the harness) for
// now (the owner, 2026-09-24); a piece is an entry here, not a new op.
//
// The sequence, for one account (docs/fleet-upgrade.md):
//   1. already at the pin: nothing happens, and nothing restarts;
//   2. a session running: write the restart marker the launcher reads,
//      then SIGTERM its `claude` — the harness's own graceful shutdown
//      (SessionEnd hooks, the transcript saved; 2.1.281, read from the
//      binary) — and wait for it to be gone; never SIGKILL: a session
//      that does not stop is a failure to report, not to force;
//   3. install the pinned version with the harness's own installer and
//      verify `claude --version` says it;
//   4. mark the marker done or failed; the launcher, still in the
//      session's terminal, relaunches with --resume on whatever is now
//      installed, and says which.
// Installing under a running session is safe (each version is its own
// file; the launcher's link moves); stopping is only so the session comes
// back ON the new version. The requester's own session is never stopped:
// it is the one waiting for this reply — it is told to relaunch itself.
//
// Only ever reached through a request signed by the operator's key
// (sign.mjs, agentd accept). Arguments are a closed set: a piece from
// PIECES and a version of digits; nothing from a request reaches a shell.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { claudeBin } from './ops.mjs';

const execFileP = promisify(execFile);
export const PIECES = ['claude'];
export const VERSION_RE = /^\d{1,4}\.\d{1,4}\.\d{1,6}$/;
export const STOP_WAIT_MS = 90000;       // the harness's failsafe is the hook budget + 5 s
export const INSTALL_TIMEOUT_MS = 300000;

export function pinFile(root) { return path.join(root, 'runtime', 'claude-code', 'harness.json'); }
export function pinnedVersion(root) {
  try { const v = JSON.parse(fs.readFileSync(pinFile(root), 'utf8')).claude; return VERSION_RE.test(v) ? v : null; } catch { return null; }
}
export function stateDir(home = os.homedir(), env = process.env, login = os.userInfo().username) {
  const root = env.AGENT_FABRIC_STATE_DIR ? path.resolve(env.AGENT_FABRIC_STATE_DIR) : path.join(env.XDG_STATE_HOME || path.join(home, '.local', 'state'), 'agent-fabric');
  return path.join(root, 'agents', login);
}
export function markerPath(dir) { return path.join(dir, 'restart.json'); }
function writeMarker(dir, m) {
  fs.mkdirSync(dir, { recursive: true });
  const f = markerPath(dir), tmp = `${f}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(m, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, f);
}

// The account's session processes: every `claude` of this uid except the
// daemon's own children (the account observer's headless /usage runs).
export function sessionPids({ uid = process.getuid(), self = process.pid, exec = null, proc = '/proc' } = {}) {
  const out = [];
  let pids = [];
  try {
    const r = exec ? exec('pgrep', ['-u', String(uid), '-x', 'claude']) : null;
    pids = String(r ?? '').split('\n').map(s => s.trim()).filter(Boolean).map(Number);
  } catch (e) {
    if (e?.status === 1) return out;   // pgrep's "nothing matched"
    throw e;                           // anything else must not read as "no session" (review of #34)
  }
  for (const pid of pids) {
    let ppid = null;
    try { ppid = Number(fs.readFileSync(path.join(proc, String(pid), 'stat'), 'utf8').replace(/^.*\) /s, '').split(' ')[1]); } catch { continue; }   // gone already
    if (ppid !== self) out.push(pid);
  }
  return out;
}

export function checkArgs(args) {
  if (!args || typeof args !== 'object') return 'no arguments';
  if (!PIECES.includes(args.piece)) return `piece ${JSON.stringify(String(args.piece).slice(0, 20))} is not one of ${PIECES.join(', ')}`;
  if (args.version !== undefined && !VERSION_RE.test(String(args.version))) return 'version is not digits.digits.digits';
  return null;
}

async function version(bin, exec) {
  const r = await exec(bin, ['--version'], { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'ignore'] });
  return String(typeof r === 'string' ? r : r.stdout).trim().split(/\s+/)[0] || null;
}

let running = null;   // one upgrade at a time per daemon
export function upgrade(request, opts = {}) {
  if (running) return Promise.resolve({ status: 'busy', note: 'an upgrade is already running on this account' });
  running = upgradeOnce(request, opts).finally(() => { running = null; });
  return running;
}

export async function upgradeOnce(request, {
  home = os.homedir(), root = process.env.AGENT_FABRIC_ROOT ?? path.join(home, 'projects', 'agent-fabric'),
  dir = stateDir(home), me = null, exec = execFileP, pgrep = null, kill = process.kill.bind(process),
  alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } },
  sleep = ms => new Promise(r => setTimeout(r, ms)), now = () => new Date(), stopWaitMs = STOP_WAIT_MS, sessions = null,
} = {}) {
  const args = request.args ?? {};
  const bad = checkArgs(args);
  if (bad) return { status: 'refused', reason: bad };
  const target = args.version ?? pinnedVersion(root);
  if (!target) return { status: 'refused', reason: `no pinned version in ${path.relative(root, pinFile(root))}` };
  const bin = claudeBin(home);
  let from;
  try { from = await version(bin, exec); } catch (e) { return { status: 'failed', piece: 'claude', to: target, reason: `claude --version: ${String(e.message).split('\n')[0].slice(0, 160)}` }; }
  let pids;
  try { pids = sessions ?? sessionPids({ exec: pgrep ?? ((c, a) => execFileSync(c, a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })) }); }
  catch (e) { return { status: 'failed', piece: 'claude', from, to: target, reason: `could not tell whether a session is running (pgrep: ${String(e.message).split('\n')[0].slice(0, 120)}); nothing installed` }; }
  const own = me && request.from === me;
  if (from === target) return { status: 'current', piece: 'claude', version: from, session: pids.length ? 'running' : 'none' };

  const stop = pids.length > 0 && !own;
  const marker = { request_id: request.id, requested_at: now().toISOString(), piece: 'claude', from, to: target, pids, status: 'pending' };
  if (stop) {
    writeMarker(dir, marker);
    for (const pid of pids) { try { kill(pid, 'SIGTERM'); } catch { /* gone */ } }
    const until = Date.now() + stopWaitMs;
    while (pids.some(alive) && Date.now() < until) await sleep(500);
    if (pids.some(alive)) {
      writeMarker(dir, { ...marker, status: 'failed', reason: 'the session did not stop' });
      return { status: 'failed', piece: 'claude', from, to: target, reason: `the session (pid ${pids.filter(alive).join(', ')}) did not stop within ${Math.round(stopWaitMs / 1000)} s; not installed, nothing forced` };
    }
  }
  let installed = null, reason = null;
  try {
    await exec(bin, ['install', target], { encoding: 'utf8', timeout: INSTALL_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'] });
    installed = await version(bin, exec);
    if (installed !== target) reason = `after install, claude --version says ${installed}`;
  } catch (e) { reason = `claude install ${target}: ${String(e.message).split('\n')[0].slice(0, 160)}`; }
  const ok = !reason;
  if (stop) writeMarker(dir, { ...marker, status: ok ? 'done' : 'failed', installed, ...(reason && { reason }), finished_at: now().toISOString() });
  return {
    status: ok ? 'upgraded' : 'failed', piece: 'claude', from, to: target, ...(reason && { reason }),
    session: stop ? 'restarting' : own && pids.length ? 'yours: relaunch to use it' : pids.length ? 'running' : 'none',
  };
}
