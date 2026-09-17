// The user unit: what bootstrap installs per account must point at the
// daemon, restart it, and want the account's default target.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const UNIT = new URL('../agent-fabric-agentd.service', import.meta.url).pathname;

test('agent-fabric-agentd.service: the keys the daemon relies on', () => {
  const text = fs.readFileSync(UNIT, 'utf8');
  const kv = Object.fromEntries(text.split('\n').filter(l => /^[A-Za-z]+=/.test(l)).map(l => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1)]; }));
  assert.match(kv.ExecStart, /node %h\/projects\/agent-fabric\/runtime\/control\/agentd\.mjs$/);
  assert.equal(kv.Restart, 'always');
  assert.equal(kv.WantedBy, 'default.target');
  assert.equal(kv.StartLimitIntervalSec, '0', 'a relay outage never exhausts the restart budget');
  assert.equal(kv.Environment, 'AGENT_FABRIC_ROOT=%h/projects/agent-fabric');
  for (const section of ['[Unit]', '[Service]', '[Install]']) assert.ok(text.includes(section), section);
  assert.ok(!/--once|--self/.test(kv.ExecStart), 'the unit runs the daemon, not a one-shot');
});
