// runtime/control/upgrade.mjs — the control agent's first ACTION: bring a
// piece of the account's software to the version the fabric pins, and
// have a running session come back on it. Only `claude` (the harness) for
// now (the owner, 2026-09-24); a piece is an entry here, not a new op.
//
// The sequence, for one account (docs/fleet-upgrade.md):
//   1. already at the pin: nothing happens, and nothing restarts;
//   2. wait for the host's install lease (one account at a time, below);
//      no turn, or no queue, is a failure with nothing stopped;
//   3. a session running: write the restart marker the launcher reads,
//      then SIGTERM its `claude` — the harness's own graceful shutdown
//      (SessionEnd hooks, the transcript saved; 2.1.281, read from the
//      binary) — and wait for it to be gone; never SIGKILL: a session
//      that does not stop is a failure to report, not to force;
//   4. install the pinned version with the harness's own installer and
//      verify `claude --version` says it; release the lease;
//   5. mark the marker done or failed; the launcher, still in the
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
import { execFile, execFileSync, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { claudeBin } from './ops.mjs';

const execFileP = promisify(execFile);
export const PIECES = ['claude'];
export const VERSION_RE = /^\d{1,4}\.\d{1,4}\.\d{1,6}$/;
export const STOP_WAIT_MS = 90000;       // the harness's failsafe is the hook budget + 5 s
export const VERSION_TIMEOUT_MS = 30000;
// One install per HOST at a time, across its accounts: `fabric-ctl all
// upgrade claude` makes every daemon install at once, and on 2026-09-25
// nine of thirteen concurrent installs on develop-qzapp failed where each
// alone succeeded. The host lease (bin/fabric-lease, docs/resources.md)
// queues them, and it is taken BEFORE the session is stopped and held until
// the new version is read back: a session is stopped only when its install
// can start, so the queue costs the operator's wait and never an account's
// downtime. The wait is sixteen accounts (develop-qzapp's count) at up to
// ~56 s a turn — the stop wait, the install and the read-back together; a
// larger host needs a longer one.
export const INSTALL_LEASE = 'claude-install';
export const LEASE_WAIT_S = 900;
export const LEASE_HELD = 75;   // fabric-lease's EX_TEMPFAIL: still held after the wait
export const INSTALL_TIMEOUT_MS = 300000;
// What the launcher waits out after the session stopped: the install and
// its read-back. runtime/openrouter/launch's AGENT_FABRIC_RESTART_WAIT_S
// default must exceed it (the suite checks), or the session resumes on
// the old version while the install still runs.
export const POST_STOP_BUDGET_S = (INSTALL_TIMEOUT_MS + VERSION_TIMEOUT_MS) / 1000;
// The longest an upgrade can take to reply: read the version, queue,
// stop the session, install, read it back. fabric-ctl waits this long.
export const UPGRADE_BUDGET_S = VERSION_TIMEOUT_MS / 1000 + LEASE_WAIT_S + STOP_WAIT_MS / 1000 + POST_STOP_BUDGET_S;

// The line that says what went wrong is the LAST one a failed command
// wrote; execFile's message starts with "Command failed: <argv>", which
// is all the first run's rows showed.
export function lastLine(e) {
  for (const s of [e?.stderr, e?.stdout, e?.message]) {
    const lines = String(s ?? '').split('\n').map(x => x.trim()).filter(Boolean);
    if (lines.length) return lines.at(-1);
  }
  return 'no output';
}

// The host lease, held by a child that waits its turn, says "held" and
// keeps the lease until its stdin closes: release() closes it, and a
// daemon that dies closes it too, so the lease never outlives its holder.
// No bin/fabric-lease, or no lease directory (exit 2), is a queue that is
// unavailable — refused, not bypassed, since installing unqueued is what
// failed nine accounts.
export function holdLease(root, { spawnFn = spawn, waitS = LEASE_WAIT_S } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnFn(path.join(root, 'bin', 'fabric-lease'),
      [INSTALL_LEASE, '--wait', String(waitS), '--', 'sh', '-c', 'echo held; exec cat >/dev/null'],
      { stdio: ['pipe', 'pipe', 'pipe'] });
    let err = '', settled = false, exited = false;
    const gone = new Promise(r => child.once('close', () => { exited = true; r(); }));
    child.stderr.on('data', d => { err += d; });
    child.stdout.on('data', d => {
      if (settled || !String(d).includes('held')) return;
      settled = true;
      resolve({ release: () => { if (!exited) child.stdin.end(); return gone; } });
    });
    child.on('error', e => { if (!settled) { settled = true; reject({ code: -1, line: String(e.message) }); } });
    child.on('close', code => { if (!settled) { settled = true; reject({ code, line: lastLine({ stderr: err, message: `fabric-lease exited ${code}` }) }); } });
  });
}

export function pinFile(root) { return path.join(root, 'runtime', 'claude-code', 'harness.json'); }
export function pinnedVersion(root) {
  try { const v = JSON.parse(fs.readFileSync(pinFile(root), 'utf8')).claude; return VERSION_RE.test(v) ? v : null; } catch { return null; }
}
export function stateDir(home = os.homedir(), env = process.env, login = os.userInfo().username) {
  const root = env.AGENT_FABRIC_STATE_DIR ? path.resolve(env.AGENT_FABRIC_STATE_DIR) : path.join(env.XDG_STATE_HOME || path.join(home, '.local', 'state'), 'agent-fabric');
  return path.join(root, 'agents', login);
}
export function markerPath(dir) { return path.join(dir, 'restart.json'); }
export function writeMarker(dir, m) {
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
  const r = await exec(bin, ['--version'], { encoding: 'utf8', timeout: VERSION_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'] });
  return String(typeof r === 'string' ? r : r.stdout).trim().split(/\s+/)[0] || null;
}

let running = null;   // one upgrade at a time per daemon
// secrets-sync writes the same restart marker: each refuses while the
// other holds it, in both directions (re-review of #37).
let syncRestarting = false;
export function upgradeRunning() { return running !== null; }
export function restartInFlight(on) { syncRestarting = on; }
export function upgrade(request, opts = {}) {
  if (running) return Promise.resolve({ status: 'busy', note: 'an upgrade is already running on this account' });
  if (syncRestarting) return Promise.resolve({ status: 'busy', note: 'a secrets-sync is restarting the session on this account' });
  running = upgradeOnce(request, opts).finally(() => { running = null; });
  return running;
}

export async function upgradeOnce(request, {
  home = os.homedir(), root = process.env.AGENT_FABRIC_ROOT ?? path.join(home, 'projects', 'agent-fabric'),
  dir = stateDir(home), me = null, exec = execFileP, pgrep = null, kill = process.kill.bind(process),
  alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } },
  sleep = ms => new Promise(r => setTimeout(r, ms)), now = () => new Date(), stopWaitMs = STOP_WAIT_MS, sessions = null,
  lease = () => holdLease(root),
} = {}) {
  const args = request.args ?? {};
  const bad = checkArgs(args);
  if (bad) return { status: 'refused', reason: bad };
  const target = args.version ?? pinnedVersion(root);
  if (!target) return { status: 'refused', reason: `no pinned version in ${path.relative(root, pinFile(root))}` };
  const bin = claudeBin(home);
  let from;
  try { from = await version(bin, exec); } catch (e) { return { status: 'failed', piece: 'claude', to: target, reason: `claude --version: ${String(e.message).split('\n')[0].slice(0, 160)}` }; }
  const readPids = () => sessions ?? sessionPids({ exec: pgrep ?? ((c, a) => execFileSync(c, a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })) });
  let pids;
  try { pids = readPids(); } catch (e) { return { status: 'failed', piece: 'claude', from, to: target, reason: `could not tell whether a session is running (pgrep: ${String(e.message).split('\n')[0].slice(0, 120)}); nothing installed` }; }
  const own = me && request.from === me;
  if (from === target) return { status: 'current', piece: 'claude', version: from, session: pids.length ? 'running' : 'none' };

  let held;
  try { held = await lease(); } catch (e) {
    return { status: 'failed', piece: 'claude', from, to: target, session: pids.length ? 'running' : 'none',
      reason: e?.code === LEASE_HELD
        ? `the host's install lease (${INSTALL_LEASE}) stayed held for ${LEASE_WAIT_S} s; not installed, no session stopped — run it again`
        : `the host's install queue is unavailable (${String(e?.line ?? e).slice(0, 160)}); not installed, no session stopped` };
  }
  try {
    // Sessions are read again under the lease: the wait can outlast one.
    try { pids = readPids(); } catch (e) { return { status: 'failed', piece: 'claude', from, to: target, reason: `could not tell whether a session is running (pgrep: ${String(e.message).split('\n')[0].slice(0, 120)}); nothing installed` }; }
    return await installHeld({ request, dir, bin, exec, kill, alive, sleep, now, stopWaitMs, from, target, pids, own });
  } finally { await held.release(); }
}

async function installHeld({ request, dir, bin, exec, kill, alive, sleep, now, stopWaitMs, from, target, pids, own }) {
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
  } catch (e) {
    reason = e?.killed
      ? `claude install ${target}: timed out after ${INSTALL_TIMEOUT_MS / 1000} s`
      : `claude install ${target}: ${lastLine(e).slice(0, 200)}`;
  }
  const ok = !reason;
  if (stop) writeMarker(dir, { ...marker, status: ok ? 'done' : 'failed', installed, ...(reason && { reason }), finished_at: now().toISOString() });
  return {
    status: ok ? 'upgraded' : 'failed', piece: 'claude', from, to: target, ...(reason && { reason }),
    session: stop ? 'restarting' : own && pids.length ? 'yours: relaunch to use it' : pids.length ? 'running' : 'none',
  };
}
