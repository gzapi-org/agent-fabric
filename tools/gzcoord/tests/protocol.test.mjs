import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { parse, validate } from '../scripts/gzmsg.mjs';

const gzmsg = (...args) =>
  spawnSync(process.execPath, [new URL('../scripts/gzmsg.mjs', import.meta.url).pathname, ...args],
            { encoding: 'utf8' });

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

// One entry per runtime/transport term SPEC.md §14-§15 keeps off the wire,
// in the spelling the spec itself uses — a near-miss spelling in FORBIDDEN
// silently admits the exact field the spec names.
test('transport-native identifiers are forbidden core metadata', () => {
  for (const field of ['TELEGRAM-CHAT-ID','SLACK-CHANNEL-ID','DISCORD-GUILD-ID',
                       'TOKEN-BUDGET','REASONING-BUDGET',
                       'MODEL','PROVIDER','WORKING-DIRECTORY','SUBAGENT-DEPTH']) {
    const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\n${field}: leaked\n`;
    assert.equal(validate(text).ok, false, `${field} must be rejected`);
  }
});

test('a malformed metadata line is reported, not silently dropped', () => {
  // `_` is not a metadata key character, so this never became metadata and the
  // forbidden-field check could not see it — the message validated clean while
  // carrying runtime config the sender believed it had sent.
  const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nTOKEN_BUDGET: leaked\n`;
  const result = validate(text);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some(e => e.includes('TOKEN_BUDGET')));
  assert.equal(result.message.metadata.TOKEN_BUDGET, undefined);
});

test('body lines after a section marker are never malformed metadata', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n\nNOTES:\nplain prose, no colon at all\nTOKEN_BUDGET: quoted from another message\n`;
  assert.deepEqual(validate(text).errors, []);
});

test('TO must be a logical address when present', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nTO: @telegram_username\n`;
  assert.equal(validate(text).ok, false);
});

test('hello refuses to emit a message its own validate would reject', () => {
  const bad = gzmsg('hello', '--from', '/srv/project', '--role', 'Tester', '--project', 'gzapp');
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /FROM must be/);
  assert.equal(bad.stdout, '');
});

test('hello emits a valid message for a well-formed address', () => {
  const ok = gzmsg('hello', '--from', 'develop-gzapp/gzapp', '--role', 'Tester', '--project', 'gzapp');
  assert.equal(ok.status, 0);
  assert.deepEqual(validate(ok.stdout).errors, []);
});

test('a repeated section marker resumes the section instead of replacing it', () => {
  // MESSAGE-FORMAT.md does not require section names to be unique, so a second
  // marker used to blank the first block and still validate clean — the sender
  // was told the message was good while half its content was gone.
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n\nNOTES:\nfirst block\n\nNOTES:\nsecond block\n`;
  const msg = parse(text);
  assert.ok(msg.sections.NOTES.includes('first block'));
  assert.ok(msg.sections.NOTES.includes('second block'));
  assert.deepEqual(validate(text).errors, []);
});

test('metadata block ends at the first section marker', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n\nREFERENCES:\nPR: #184\n- path: contracts/passenger/eta.yaml\n\nNOTES:\nKEY: value shaped lines stay in the body.\n`;
  const msg = parse(text);
  assert.equal(msg.metadata.PR, undefined);
  assert.equal(msg.metadata.KEY, undefined);
  assert.ok(msg.sections.REFERENCES.includes('PR: #184'));
  assert.ok(msg.sections.NOTES.includes('KEY: value shaped lines'));
  assert.equal(validate(text).ok, true);
});
