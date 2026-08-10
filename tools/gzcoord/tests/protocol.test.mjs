import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { validate } from '../scripts/gzmsg.mjs';

for (const name of ['hello','observation','review']) {
  test(`${name} example is valid`, () => {
    const text = fs.readFileSync(new URL(`../protocol/examples/${name}.txt`, import.meta.url), 'utf8');
    assert.deepEqual(validate(text).errors, []);
  });
}

test('runtime model must not leak into protocol', () => {
  const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMODEL: secret-model\n`;
  assert.equal(validate(text).ok, false);
});

test('normal messages require a routing target or broadcast', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\n`;
  assert.equal(validate(text).ok, false);
});

test('address is logical host/instance', () => {
  const text = `[GZCOORD/1] HELLO\nFROM: /srv/gzapp/mobile\nROLE: Mobile Engineer\nPROJECT: gzapp\n`;
  assert.equal(validate(text).ok, false);
});
