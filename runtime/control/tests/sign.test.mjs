// The operator's signature on a control request: an action op is answered
// only when signed by the key its host commits; a read op is unaffected.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { scratch } from '../../../tests/scratch.mjs';
import { canonical, signRequest, verifyRequest, publicKeyFrom, privateKeyFrom, generateOperatorKey, ACTION_TTL_MAX_S } from '../sign.mjs';
import { accept, operatorKeys } from '../agentd.mjs';

const OP = 'h/user';
const me = { address: 'h/db-admin' };
function registry(dir, keySpec) {
  const f = path.join(dir, 'registry.json');
  fs.writeFileSync(f, JSON.stringify({ hosts: { h: { operator: 'user', ...(keySpec !== undefined && { operator_key: keySpec }) } }, placement: {} }));
  return f;
}
const rec = r => ({ content: JSON.stringify(r) });
const base = (over = {}) => ({ v: 1, kind: 'request', id: 'id-' + Math.random(), from: OP, to: me.address, op: 'upgrade', args: { piece: 'claude' }, ts: new Date().toISOString(), ttl_s: 300, ...over });

test('canonical: key order at every depth does not matter; undefined keys drop; the signature is over every field but sig', () => {
  assert.equal(canonical({ b: 1, a: { d: [2, { y: 1, x: 0 }], c: 'z' }, u: undefined }), '{"a":{"c":"z","d":[2,{"x":0,"y":1}]},"b":1}');
  const k = generateOperatorKey();
  const signed = signRequest(base({ id: 'x' }), k.privateKeySpec);
  const reordered = Object.fromEntries(Object.entries(signed).reverse());
  assert.ok(verifyRequest(reordered, publicKeyFrom(k.publicKeySpec)), 'a re-serialisation that reorders keys still verifies');
  for (const [field, value] of [['to', '*'], ['ts', '2030-01-01T00:00:00Z'], ['op', 'status'], ['args', { piece: 'claude', version: '0.0.1' }], ['from', 'h/other']])
    assert.ok(!verifyRequest({ ...signed, [field]: value }, publicKeyFrom(k.publicKeySpec)), `changing ${field} breaks the signature`);
  assert.ok(!verifyRequest(signed, publicKeyFrom(generateOperatorKey().publicKeySpec)), 'another key does not verify it');
  assert.ok(!verifyRequest({ ...signed, sig: 'bm90IGEgc2ln' }, publicKeyFrom(k.publicKeySpec)));
  assert.equal(privateKeyFrom('-----BEGIN PRIVATE KEY-----'), null, 'only the one-line form is a key');
  assert.equal(publicKeyFrom('ed25519:not-base64-der'), null);
  assert.ok(!k.privateKeySpec.includes('\n') && !k.publicKeySpec.includes('\n'), 'both halves fit one line of secrets.env and of JSON');
});

test('accept: an action needs the operator\'s signature; a forged from, a missing or wrong key is refused; a read op is unaffected', () => {
  const dir = scratch('sign-reg-');
  const k = generateOperatorKey();
  const keys = operatorKeys(registry(dir, k.publicKeySpec));
  const ctx = { me, operators: new Set([OP]), keys, ttl_s: 30, seen: new Set() };
  assert.equal(accept(rec(signRequest(base(), k.privateKeySpec)), ctx).ok, true);
  const unsigned = accept(rec(base()), ctx);
  assert.deepEqual([unsigned.ok, unsigned.why], [false, `upgrade: not signed by ${OP}'s key`]);
  assert.equal(accept(rec(signRequest(base(), generateOperatorKey().privateKeySpec)), ctx).ok, false, 'a relay-token holder\'s own key is not the operator\'s');
  assert.equal(accept(rec(base({ op: 'status', args: undefined })), ctx).ok, true, 'reads stay unsigned-compatible');
  const noKey = { ...ctx, keys: operatorKeys(registry(scratch('sign-nokey-'))) };
  assert.equal(accept(rec(signRequest(base(), k.privateKeySpec)), noKey).ok, false, 'a host with no committed key can order nothing');
  const badKey = { ...ctx, keys: operatorKeys(registry(scratch('sign-badkey-'), 'ed25519:####')) };
  assert.equal(badKey.keys.size, 0);
});

test('accept: an action lives at most ACTION_TTL_MAX_S whatever it asks, and is answered once', () => {
  const dir = scratch('sign-ttl-');
  const k = generateOperatorKey();
  const ctx = { me, operators: new Set([OP]), keys: operatorKeys(registry(dir, k.publicKeySpec)), ttl_s: 30, seen: new Set() };
  const old = new Date(Date.now() - (ACTION_TTL_MAX_S + 60) * 1000).toISOString();
  const stale = accept(rec(signRequest(base({ ts: old, ttl_s: 3600 }), k.privateKeySpec)), ctx);
  assert.deepEqual([stale.ok, stale.why], [false, 'expired']);
  const once = signRequest(base(), k.privateKeySpec);
  assert.equal(accept(rec(once), ctx).ok, true);
  ctx.seen.add(once.id);
  assert.equal(accept(rec(once), ctx).why, 'seen', 'a replay inside the window is refused by the seen-id LRU');
});
