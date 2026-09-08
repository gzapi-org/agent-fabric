import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { parse, validate } from '../scripts/gzmsg.mjs';

const gzmsg = (...args) =>
  spawnSync(process.execPath, [new URL('../scripts/gzmsg.mjs', import.meta.url).pathname, ...args],
            { encoding: 'utf8' });

for (const name of ['hello','observation','observation-diagnosis','reply','review']) {
  test(`${name} example is valid`, () => {
    const text = fs.readFileSync(new URL(`../protocol/examples/${name}.txt`, import.meta.url), 'utf8');
    const result = validate(text);
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.warnings, []);
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

// SPEC §7.4: REPLY-EXPECTED is an optional common field, so it must pass as
// ordinary metadata and survive the forbidden-field check untouched.
test('REPLY-EXPECTED is ordinary optional metadata', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\nREPLY-EXPECTED: no\n`;
  const result = validate(text);
  assert.deepEqual(result.errors, []);
  assert.equal(result.message.metadata['REPLY-EXPECTED'], 'no');
});

// The relay transport numbers every message, HELLO included, and points at
// this command to emit it — so the command must be able to carry the id.
test('hello carries --message-id when given', () => {
  const ok = gzmsg('hello','--from','develop-gzapp/gzapp','--role','Application Architect',
                   '--project','gzapp','--message-id','gzapp-0001');
  assert.equal(ok.status, 0);
  assert.match(ok.stdout, /^MESSAGE-ID: gzapp-0001$/m);
  assert.deepEqual(validate(ok.stdout).errors, []);
});

// SPEC §7.4 gives REPLY-EXPECTED a closed grammar, and the relay procedure
// makes senders rely on this validator — so a value outside it must fail
// here, not reach the carrier with undefined reply semantics. Lowercase
// only, matching the exact-match convention for BROADCAST: true.
test('REPLY-EXPECTED rejects a value outside yes | no', () => {
  for (const value of ['maybe', 'Yes', 'NO', 'true']) {
    const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\nREPLY-EXPECTED: ${value}\n`;
    const result = validate(text);
    assert.equal(result.ok, false, `${value} must be rejected`);
    assert.ok(result.errors.some(e => e.includes('REPLY-EXPECTED')));
  }
});

test('REPLY-EXPECTED accepts yes and no', () => {
  for (const value of ['yes', 'no']) {
    const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\nREPLY-EXPECTED: ${value}\n`;
    assert.deepEqual(validate(text).errors, []);
  }
});

// SPEC §6: a repeated metadata key has no defined meaning, and last-write-wins
// let an invalid earlier value hide behind a valid later one — observed for
// REPLY-EXPECTED and for a malformed FROM, which §18 already MUST reject.
test('a duplicated metadata key is rejected even when the last value is valid', () => {
  for (const [dup, first, last] of [['REPLY-EXPECTED','maybe','no'], ['FROM','bad','develop-gzapp/gzapp']]) {
    const base = dup === 'FROM' ? '' : 'FROM: develop-gzapp/gzapp\n';
    const text = `[GZCOORD/1] INFO\n${base}${dup}: ${first}\n${dup}: ${last}\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n`;
    const result = validate(text);
    assert.equal(result.ok, false, `${dup} duplicate must be rejected`);
    assert.ok(result.errors.some(e => e.includes(dup) && e.includes('more than once')));
  }
});

test('a message with no duplicated key reports none', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\nREPLY-EXPECTED: no\n`;
  const result = validate(text);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.message.duplicateKeys, []);
});

// A relay-indented marker is body text by §6 and the message validates, so
// the "ask for a re-send on failure" rule never fires. The validator warns
// instead of failing — content may legitimately look like this — and never
// promotes the line to a marker.
test('an indented marker-shaped body line warns instead of silently merging', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n\nNOTES:\n  first body line\n REFERENCES:\n  - path: contracts/passenger/eta.yaml\n`;
  const result = validate(text);
  assert.equal(result.ok, true);
  assert.deepEqual(result.errors, []);
  assert.ok(result.warnings.some(w => w.includes('REFERENCES')));
  assert.equal(result.message.sections.REFERENCES, undefined);
});

// A header the parser cannot read used to escape validate() as an uncaught
// exception — a stack trace on the CLI, and a caller that could not tell a
// bad header from a crashed validator.
test('a bad first line is a validation error, not an exception', () => {
  for (const first of ['GZCOORD/1 HELLO', '[GZCOORD/2] HELLO', '[GZCOORD/1] HELLO ', '[GZCOORD/1] hello']) {
    const result = validate(`${first}\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\n`);
    assert.equal(result.ok, false, `${JSON.stringify(first)} must be rejected`);
    assert.ok(result.errors.some(e => e.includes('first line')));
    assert.equal(result.message, null);
  }
});

test('a leading byte-order mark does not invalidate the header', () => {
  const text = `\uFEFF[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\n`;
  assert.deepEqual(validate(text).errors, []);
});

test('validate CLI reports a bad first line on one line and exits 1', () => {
  const file = new URL('./bad-first-line.tmp.txt', import.meta.url);
  fs.writeFileSync(file, 'GZCOORD/1 HELLO\nFROM: develop-gzapp/gzapp\nROLE: Tester\nPROJECT: gzapp\n');
  try {
    const bad = gzmsg('validate', file.pathname);
    assert.equal(bad.status, 1);
    assert.equal(bad.stderr.trim(), 'invalid GZCOORD/1 first line');
    assert.equal(bad.stdout, '');
  } finally { fs.unlinkSync(file); }
});

// SPEC §7.1: BROADCAST has one value. Any other spelling either fell through
// to the routing error — which named the wrong fault — or, next to a TO,
// validated clean with a meaning the spec does not define.
test('BROADCAST rejects a value other than true', () => {
  for (const [value, routing] of [['yes', ''], ['True', ''], ['false', 'TO: develop-gzapp/web\n'], ['1', 'TO-ROLE: Web Engineer\n']]) {
    const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\n${routing}BROADCAST: ${value}\n`;
    const result = validate(text);
    assert.equal(result.ok, false, `${value} must be rejected`);
    assert.ok(result.errors.some(e => e.startsWith('BROADCAST must be true')), `${value}: ${result.errors}`);
  }
});

test('BROADCAST: true routes on its own, and absent BROADCAST is not an error', () => {
  assert.deepEqual(validate(`[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n`).errors, []);
  assert.deepEqual(validate(`[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nTO: develop-gzapp/web\n`).errors, []);
});

// Trailing whitespace is the other way a marker stops being one, and the
// only way that is invisible in a terminal. Same warning, same rule: named,
// never promoted.
test('a marker-shaped body line with trailing whitespace warns instead of silently merging', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n\nNOTES:\nbody\nREFERENCES: \n- adr: ADR-001\n`;
  const result = validate(text);
  assert.equal(result.ok, true);
  assert.ok(result.warnings.some(w => w.includes('REFERENCES')));
  assert.equal(result.message.sections.REFERENCES, undefined);
  assert.ok(result.message.sections.NOTES.includes('- adr: ADR-001'));
});

test('an empty-valued metadata key warns, and the CLI prints the warning beside the errors', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\nNOTES: \nbody here\n`;
  const result = validate(text);
  assert.equal(result.ok, false);
  assert.ok(result.warnings.some(w => w.startsWith('NOTES has an empty value')));
  const file = new URL('./empty-value.tmp.txt', import.meta.url);
  fs.writeFileSync(file, text);
  try {
    const run = gzmsg('validate', file.pathname);
    assert.equal(run.status, 1);
    assert.match(run.stderr, /^warning: NOTES has an empty value/m);
    assert.match(run.stderr, /unparsable line in the metadata block: body here/);
  } finally { fs.unlinkSync(file); }
});
