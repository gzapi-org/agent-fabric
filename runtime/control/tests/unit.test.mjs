// The user unit: what bootstrap installs per account must point at the
// daemon, restart it, and want the account's default target.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const UNIT = new URL('../agent-fabric-agentd.service', import.meta.url).pathname;

test('agent-fabric-agentd.service: the keys the daemon relies on', () => {
  const text = fs.readFileSync(UNIT, 'utf8');
  const kv = {};
  for (const l of text.split('\n')) { if (!/^[A-Za-z]+=/.test(l)) continue; const i = l.indexOf('='); const k = l.slice(0, i); kv[k] = k in kv ? `${kv[k]}\n${l.slice(i + 1)}` : l.slice(i + 1); }
  assert.match(kv.ExecStart, /node %h\/projects\/agent-fabric\/runtime\/control\/agentd\.mjs$/);
  assert.equal(kv.Restart, 'always');
  assert.equal(kv.WantedBy, 'default.target');
  assert.equal(kv.StartLimitIntervalSec, '0', 'a relay outage never exhausts the restart budget');
  assert.match(kv.Environment, /^AGENT_FABRIC_ROOT=%h\/projects\/agent-fabric$/m);
  assert.match(kv.Environment, /^PATH=%h\/.local\/bin:/m, 'the account\'s own node is on the PATH the user manager lacks');
  for (const section of ['[Unit]', '[Service]', '[Install]']) assert.ok(text.includes(section), section);
  assert.ok(!/--once|--self/.test(kv.ExecStart), 'the unit runs the daemon, not a one-shot');
});
