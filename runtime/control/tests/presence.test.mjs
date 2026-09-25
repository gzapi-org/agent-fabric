// Presence as a sender sees it: askPresence posts one `presence` request on
// the control channel and collects the replies to it; checkAddressees
// turns a message's addressing into what, if anything, has no session.
import test from 'node:test';
import assert from 'node:assert/strict';
import { askPresence, checkAddressees } from '../presence.mjs';

const on = (role = 'web-dev') => ({ status: 'ok', online: true, sessions: 1, since: '2026-09-25T09:00:00.000Z', role, project: 'gzapp' });
const off = (role = 'web-dev') => ({ status: 'ok', online: false, sessions: 0, since: null, role, project: 'gzapp' });
const placed = ['h/web-dev-01', 'h/web-dev-02', 'h/db-admin'];
const asker = answers => async ({ expect }) => Object.fromEntries(expect.map(a => [a, a in answers ? answers[a] : null]));

test('TO: a running session passes; no session, a silent agent and an unplaced address are each said', async () => {
  const ask = asker({ 'h/web-dev-01': on(), 'h/web-dev-02': off() });
  const chk = to => checkAddressees({ TO: to }, { from: 'h/user', token: 't', placed, ask });
  assert.deepEqual(await chk('h/web-dev-01'), { checked: true, problems: [] });
  assert.deepEqual((await chk('h/web-dev-02')).problems.map(p => [p.kind, p.address]), [['offline', 'h/web-dev-02']]);
  assert.deepEqual((await chk('h/db-admin')).problems.map(p => [p.kind, p.address]), [['silent', 'h/db-admin']], 'no answer is unknown, never offline');
  assert.deepEqual((await chk('h/nobody')).problems.map(p => p.kind), ['not-placed']);
});

test('TO-ROLE: reached when any holder runs; otherwise its holders, and the silent agents a holder may hide behind', async () => {
  const chk = (answers, role = 'web-dev') => checkAddressees({ 'TO-ROLE': role }, { from: 'h/user', token: 't', placed, ask: asker(answers) });
  assert.deepEqual(await chk({ 'h/web-dev-01': off(), 'h/web-dev-02': on(), 'h/db-admin': on('db-admin') }), { checked: true, problems: [] });
  const none = (await chk({ 'h/web-dev-01': off(), 'h/web-dev-02': off() })).problems[0];
  assert.deepEqual([none.kind, none.role, none.holders, none.silent], ['no-holder', 'web-dev', ['h/web-dev-01', 'h/web-dev-02'], ['h/db-admin']]);
  const nobody = (await chk({ 'h/web-dev-01': on(), 'h/web-dev-02': on(), 'h/db-admin': on('db-admin') }, 'p2p-network-dev')).problems[0];
  assert.deepEqual([nobody.kind, nobody.holders], ['no-holder', []], 'a role no account holds');
});

test('a broadcast, or a message with no addressing field (HELLO, GOODBYE), is not checked', async () => {
  const ask = () => assert.fail('nothing to ask');
  assert.deepEqual(await checkAddressees({ BROADCAST: 'true' }, { from: 'h/user', token: 't', placed, ask }), { checked: false });
  assert.deepEqual(await checkAddressees({}, { from: 'h/user', token: 't', placed, ask }), { checked: false });
});

test('askPresence: one presence request on the control channel; only replies to it, from the expected, count; the rest stay null', async () => {
  const posts = []; let reads = 0;
  const call = async (p, init) => {
    if (init?.method === 'POST') { posts.push(JSON.parse(init.body)); return { id: 'sent-1' }; }
    reads += 1;
    const req = JSON.parse(posts[0].content);
    return { messages: [
      { id: 'r1', content: JSON.stringify({ kind: 'reply', in_reply_to: req.id, from: 'h/web-dev-01', data: { presence: on() } }) },
      { id: 'r2', content: JSON.stringify({ kind: 'reply', in_reply_to: 'another-request', from: 'h/web-dev-02', data: { presence: on() } }) },
      { id: 'r3', content: JSON.stringify({ kind: 'reply', in_reply_to: req.id, from: 'h/stranger', data: { presence: on() } }) },
      { id: 'r4', content: 'not json' },
    ] };
  };
  const out = await askPresence({ from: 'h/user', to: ['h/web-dev-01', 'h/web-dev-02'], expect: ['h/web-dev-01', 'h/web-dev-02'], token: 't', waitMs: 300, cfg: { relay_url: 'x', channel: 'fabric:control', ttl_s: 30 }, call });
  assert.equal(posts.length, 1); assert.equal(posts[0].channel, 'fabric:control'); assert.equal(posts[0].sender, 'h/user');
  const req = JSON.parse(posts[0].content);
  assert.deepEqual([req.kind, req.op, req.from, req.to], ['request', 'presence', 'h/user', ['h/web-dev-01', 'h/web-dev-02']]);
  assert.deepEqual(out, { 'h/web-dev-01': on(), 'h/web-dev-02': null }, 'a reply to another request, or from someone not asked, is not an answer');
  assert.ok(reads >= 1);
});
