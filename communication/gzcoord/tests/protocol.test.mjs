import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { parse, validate, columns, normalize, loadTaxonomy, findTaxonomy, slugOf, recordedRole, parseArgs, nearestKnownKey, whoami } from '../scripts/gzmsg.mjs';

const taxonomy = loadTaxonomy(new URL('../../../identities/roles/catalog.json', import.meta.url).pathname);

const gzmsg = (...args) =>
  spawnSync(process.execPath, [new URL('../scripts/gzmsg.mjs', import.meta.url).pathname, ...args],
            { encoding: 'utf8' });

for (const name of ['hello','observation','observation-diagnosis','reply','review']) {
  test(`${name} example is valid`, () => {
    const text = fs.readFileSync(new URL(`../protocol/examples/${name}.txt`, import.meta.url), 'utf8');
    // Under the deployment's catalogue: the examples are what sessions copy.
    const result = validate(text, { taxonomy });
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.warnings, []);
  });
}

test('runtime model must not leak into protocol', () => {
  const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nMODEL: secret-model\n`;
  assert.equal(validate(text).ok, false);
});

test('normal messages require a routing target or broadcast', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n`;
  assert.equal(validate(text).ok, false);
});

test('address is logical host/instance', () => {
  const text = `[GZCOORD/1] HELLO\nFROM: /srv/gzapp/mobile\nROLE: Mobile Engineer\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n`;
  assert.equal(validate(text).ok, false);
});

// One entry per runtime/transport term SPEC.md §14-§15 keeps off the wire,
// in the spelling the spec itself uses — a near-miss spelling in FORBIDDEN
// silently admits the exact field the spec names.
test('transport-native identifiers are forbidden core metadata', () => {
  for (const field of ['TELEGRAM-CHAT-ID','SLACK-CHANNEL-ID','DISCORD-GUILD-ID',
                       'TOKEN-BUDGET','REASONING-BUDGET',
                       'MODEL','PROVIDER','WORKING-DIRECTORY','SUBAGENT-DEPTH']) {
    const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n${field}: leaked\n`;
    assert.equal(validate(text).ok, false, `${field} must be rejected`);
  }
});

test('a malformed metadata line is reported, not silently dropped', () => {
  // `_` is not a metadata key character, so this never became metadata and the
  // forbidden-field check could not see it — the message validated clean while
  // carrying runtime config the sender believed it had sent.
  const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTOKEN_BUDGET: leaked\n`;
  const result = validate(text);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some(e => e.includes('TOKEN_BUDGET')));
  assert.equal(result.message.metadata.TOKEN_BUDGET, undefined);
});

test('body lines after a section marker are never malformed metadata', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\nplain prose, no colon at all\nTOKEN_BUDGET: quoted from another message\n`;
  assert.deepEqual(validate(text).errors, []);
});

test('TO must be a logical address when present', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO: @telegram_username\n`;
  assert.equal(validate(text).ok, false);
});

test('hello refuses to emit a message its own validate would reject', () => {
  const bad = gzmsg('hello', '--no-taxonomy', '--from', '/srv/project', '--role', 'Tester', '--project', 'gzapp');
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /FROM must be/);
  assert.equal(bad.stdout, '');
});

test('hello emits a valid message for a well-formed address', () => {
  const ok = gzmsg('hello', '--no-taxonomy', '--from', 'develop-gzapp/gzapp', '--role', 'Tester', '--project', 'gzapp');
  assert.equal(ok.status, 0, ok.stderr);
  assert.deepEqual(validate(ok.stdout).errors, []);
});

test('a repeated section marker resumes the section instead of replacing it', () => {
  // MESSAGE-FORMAT.md does not require section names to be unique, so a second
  // marker used to blank the first block and still validate clean — the sender
  // was told the message was good while half its content was gone.
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\nfirst block\n\nNOTES:\nsecond block\n`;
  const msg = parse(text);
  assert.ok(msg.sections.NOTES.includes('first block'));
  assert.ok(msg.sections.NOTES.includes('second block'));
  assert.deepEqual(validate(text).errors, []);
});

test('metadata block ends at the first section marker', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nREFERENCES:\nPR: #184\n- path: contracts/passenger/eta.yaml\n\nNOTES:\nKEY: value shaped lines stay in the body.\n`;
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
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\nREPLY-EXPECTED: no\n`;
  const result = validate(text);
  assert.deepEqual(result.errors, []);
  assert.equal(result.message.metadata['REPLY-EXPECTED'], 'no');
});

// The relay transport numbers every message, HELLO included, and points at
// this command to emit it — so the command must be able to carry the id.
test('hello carries --message-id when given', () => {
  const ok = gzmsg('hello','--no-taxonomy','--from','develop-gzapp/gzapp','--role','Application Architect',
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
    const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\nREPLY-EXPECTED: ${value}\n`;
    const result = validate(text);
    assert.equal(result.ok, false, `${value} must be rejected`);
    assert.ok(result.errors.some(e => e.includes('REPLY-EXPECTED')));
  }
});

test('REPLY-EXPECTED accepts yes and no', () => {
  for (const value of ['yes', 'no']) {
    const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\nREPLY-EXPECTED: ${value}\n`;
    assert.deepEqual(validate(text).errors, []);
  }
});

// SPEC §6: a repeated metadata key has no defined meaning, and last-write-wins
// let an invalid earlier value hide behind a valid later one — observed for
// REPLY-EXPECTED and for a malformed FROM, which §18 already MUST reject.
test('a duplicated metadata key is rejected even when the last value is valid', () => {
  for (const [dup, first, last] of [['REPLY-EXPECTED','maybe','no'], ['FROM','bad','develop-gzapp/gzapp']]) {
    const base = dup === 'FROM' ? '' : 'FROM: develop-gzapp/gzapp\n';
    const text = `[GZCOORD/1] INFO\n${base}${dup}: ${first}\n${dup}: ${last}\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n`;
    const result = validate(text);
    assert.equal(result.ok, false, `${dup} duplicate must be rejected`);
    assert.ok(result.errors.some(e => e.includes(dup) && e.includes('more than once')));
  }
});

test('a message with no duplicated key reports none', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\nREPLY-EXPECTED: no\n`;
  const result = validate(text);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.message.duplicateKeys, []);
});

// A relay-indented marker is body text by §6 and the message validates, so
// the "ask for a re-send on failure" rule never fires. The validator warns
// instead of failing — content may legitimately look like this — and never
// promotes the line to a marker.
test('an indented marker-shaped body line warns instead of silently merging', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\n  first body line\n REFERENCES:\n  - path: contracts/passenger/eta.yaml\n`;
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
  const text = `\uFEFF[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n`;
  assert.deepEqual(validate(text).errors, []);
});

test('validate CLI reports a bad first line on one line and exits 1', () => {
  const file = new URL('./bad-first-line.tmp.txt', import.meta.url);
  fs.writeFileSync(file, 'GZCOORD/1 HELLO\nFROM: develop-gzapp/gzapp\nROLE: Tester\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n');
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
    const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n${routing}BROADCAST: ${value}\n`;
    const result = validate(text);
    assert.equal(result.ok, false, `${value} must be rejected`);
    assert.ok(result.errors.some(e => e.startsWith('BROADCAST must be true')), `${value}: ${result.errors}`);
  }
});

test('BROADCAST: true routes on its own, and absent BROADCAST is not an error', () => {
  assert.deepEqual(validate(`[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n`).errors, []);
  assert.deepEqual(validate(`[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO: develop-gzapp/web\n`).errors, []);
});

// Trailing whitespace is the other way a marker stops being one, and the
// only way that is invisible in a terminal. Same warning, same rule: named,
// never promoted.
test('a marker-shaped body line with trailing whitespace warns instead of silently merging', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\nbody\nREFERENCES: \n- adr: ADR-001\n`;
  const result = validate(text);
  assert.equal(result.ok, true);
  assert.ok(result.warnings.some(w => w.includes('REFERENCES')));
  assert.equal(result.message.sections.REFERENCES, undefined);
  assert.ok(result.message.sections.NOTES.includes('- adr: ADR-001'));
});

test('an empty-valued metadata key warns, and the CLI prints the warning beside the errors', () => {
  const text = `[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\nNOTES: \nbody here\n`;
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

// HUMAN-RELAY-TRANSPORT.md "Sending" caps lines at 72 because a terminal
// copy re-breaks longer ones and a re-broken metadata line is no longer
// metadata. Nothing enforced it; three of the five examples broke it.
test('a line over 72 characters warns, naming the line, and stays valid', () => {
  const long = 'x'.repeat(73);
  const text = `[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nSPECIALTIES: ${long}\n\nABOUT:\n${long}\n`;
  const result = validate(text);
  assert.equal(result.ok, true);
  const lines = result.warnings.filter(w => w.includes('may re-break'));
  assert.equal(lines.length, 2);
  assert.match(lines[0], /^line 6 is 86 columns wide/);
  assert.match(lines[1], /^line 9 is 73 columns wide/);
  // Exactly 72 is inside the limit.
  assert.deepEqual(validate(`[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\n${'y'.repeat(72)}\n`).warnings, []);
});

test('hello prints the line-length warning on stderr and still emits the message', () => {
  const ok = gzmsg('hello','--no-taxonomy','--from','develop-gzapp/gzapp','--role','Tester','--project','gzapp',
                   '--specialties', 'z'.repeat(80));
  assert.equal(ok.status, 0);
  assert.match(ok.stderr, /^warning: line 6 is 93 columns wide/m);
  assert.match(ok.stdout, /^\[GZCOORD\/1\] HELLO\n/);
});

// SPEC §6: the well-formed separator is one space; a tab or nothing is not
// a separator (normative), and a reader MAY accept a run of spaces and trim
// (an allowance — this pins what the reference does, not what a conforming
// parser must). Nothing pinned any of it: a regex that dropped the space
// requirement altogether left every test green.
test('reference parser: separator is one space, tolerates a run, rejects tab and nothing', () => {
  const base = 'ROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n';
  for (const [line, ok] of [['FROM: develop-gzapp/gzapp', true], ['FROM:   develop-gzapp/gzapp   ', true],
                            ['FROM:develop-gzapp/gzapp', false], ['FROM:\tdevelop-gzapp/gzapp', false]]) {
    const result = validate(`[GZCOORD/1] HELLO\n${line}\n${base}`);
    assert.equal(result.ok, ok, JSON.stringify(line));
    if (ok) assert.equal(result.message.metadata.FROM, 'develop-gzapp/gzapp');
    else assert.ok(result.errors.some(e => e.startsWith('unparsable line in the metadata block: FROM')), JSON.stringify(line));
  }
});

// The relay re-breaks on columns, and String.length is UTF-16 code units:
// 40 CJK characters counted 49 and rendered at 89, no warning; 40 combining
// sequences counted 89 and rendered at 49, a false warning. Each row is
// what `wc -L` reports for the same line.
test('columns() approximates terminal width where String.length does not', () => {
  for (const [line, width] of [
    ['SUBJECT: ' + '\u7DDA'.repeat(40), 89],          // CJK: 2 each
    ['SUBJECT: ' + '\u{1F68C}'.repeat(40), 89],       // wide emoji: 2 each
    ['SUBJECT: ' + '\u00A9'.repeat(32), 41],          // text-default pictograph ©: 1 each
    ['SUBJECT: instance\u2194instance', 26],           // ↔ as the repo writes it: 1
    ['SUBJECT: \u{1F1EC}\u{1F1EA}', 11],              // flag pair: 2 total, not 4
    ['SUBJECT: ' + '\uFF21'.repeat(32), 73],          // fullwidth Latin: 2 each (was 1)
    ['SUBJECT: \u3000\u3001\u3002', 15],              // ideographic space and punctuation: 2 each
    ['SUBJECT: ' + '\uFF76'.repeat(40), 49],          // halfwidth katakana: 1 each (was 2, a false warning)
    ['SUBJECT: ' + '\u{1B001}'.repeat(40), 89],       // kana supplement: 2, outside the classic table
    ['SUBJECT: ' + '\u{1D400}'.repeat(40), 49],       // narrow astral: 1 each
    ['SUBJECT: ' + 'e\u0301'.repeat(40), 49],         // combining: 0
    ['SUBJECT: \u10DB\u10D0\u10E0\u10E8 \u043C\u0430\u0440\u0448', 18], // Georgian, Cyrillic: 1 each
    ['SUBJECT: a\tb', 17],                           // tab to next multiple of 8
    ['x'.repeat(72), 72],
    ['SUBJECT: ' + '\u2630'.repeat(36), 81],          // trigrams: Wide since Unicode 16, missed by the classic table
  ]) assert.equal(columns(line), width, JSON.stringify(line.slice(0, 20)));
  // Every boundary of the range table, from both sides, so an off-by-one
  // or a deleted range cannot pass: [code point, width]. A hand-written
  // table ships exactly this class of error. Rows expecting 0 are
  // combining or format characters decided by the ZERO branch before
  // the table is consulted; they pin that branch, not a boundary, so
  // every range edge also has a real neighbour with width 1 or 2.
  for (const [cp, width] of [
    [0x10FF, 1], [0x1100, 2], [0x115F, 2], [0x1160, 1],   // Jamo; U+1160 (filler) is EAW N, outside the range — `wc -L` says 0, a known deviation
    [0x2328, 1], [0x2329, 2], [0x232A, 2], [0x232B, 1],
    [0x262F, 1], [0x2630, 2], [0x2637, 2], [0x2638, 1], [0x2689, 1], [0x268A, 2], [0x268F, 2], [0x2690, 1],
    [0x2E7F, 1], [0x2E80, 2], [0x303E, 2], [0x303F, 1], [0x3040, 1], [0x3041, 2], [0x3248, 2], [0x33FF, 2],
    [0x3400, 2], [0x4DBF, 2], [0x4DC0, 2], [0x4DFF, 2], [0x4E00, 2], [0x9FFF, 2], [0xA000, 2], [0xA4CF, 2], [0xA4D0, 1],
    [0xA95F, 1], [0xA960, 2], [0xA97C, 2], [0xA97F, 2], [0xA980, 0], [0xABFF, 1], [0xAC00, 2], [0xD7A3, 2], [0xD7A4, 1],
    [0xF8FF, 1], [0xF900, 2], [0xFAFF, 2], [0xFB00, 1], [0xFE0F, 0], [0xFE10, 2], [0xFE19, 2], [0xFE1A, 1],
    [0xFE2F, 0], [0xFE30, 2], [0xFE4F, 2], [0xFE50, 2], [0xFE6B, 2], [0xFE6C, 1],
    [0xFEFF, 0], [0xFF00, 2], [0xFF60, 2], [0xFF61, 1], [0xFF9F, 1], [0xFFDF, 1], [0xFFE0, 2], [0xFFE6, 2], [0xFFE7, 1],
    [0x16FDF, 1], [0x16FE0, 2], [0x16FF1, 2], [0x16FF2, 2], [0x16FFF, 2], [0x17000, 2], [0x18AFF, 2],
    [0x18B00, 2], [0x18CD5, 2], [0x18CFF, 2], [0x18D00, 2], [0x18D08, 2], [0x18D09, 2],   // Khitan Small Script, its own range
    [0x18D8F, 2], [0x18D90, 2], [0x18DF2, 2], [0x18DFF, 2], [0x18E00, 1],   // Tangut Supplement to its Unicode 17 block end
    [0x1AFEF, 1], [0x1AFF0, 2], [0x1B000, 2], [0x1B001, 2], [0x1B2FB, 2], [0x1B2FF, 2], [0x1B300, 1],
    [0x1D2FF, 1], [0x1D300, 2], [0x1D376, 2], [0x1D377, 1], [0x1F1FF, 1], [0x1F200, 2], [0x1F26F, 2], [0x1F270, 1],
    [0x1FFFD, 1], [0x20000, 2], [0x2FFFD, 2], [0x2FFFE, 1], [0x30000, 2], [0x3FFFD, 2], [0x3FFFE, 1],
  ]) assert.equal(columns(String.fromCodePoint(cp)), width, `U+${cp.toString(16).toUpperCase()}`);
  const head = 'FROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nBROADCAST: true\n';
  const cjk = validate(`[GZCOORD/1] INFO\n${head}SUBJECT: ${'\u7DDA'.repeat(40)}\n`);
  assert.ok(cjk.warnings.some(w => w.startsWith('line 6 is 89 columns wide')), cjk.warnings);
  const combining = validate(`[GZCOORD/1] INFO\n${head}SUBJECT: ${'e\u0301'.repeat(40)}\n`);
  assert.deepEqual(combining.warnings, []);
});

// The address outlives a session; the counter has to. A session that
// restarted at 0001 repeated four numbers a peer had already seen.
// Superseded by the mint tests: the sequential counter this test pinned is
// gone (ids are UUIDv7, minted unique by construction — no counter file,
// nothing to continue across processes).

// The relay indents on paste — every line by two, the first by one, a
// single marker by a third — observed twice on the first day. normalize()
// is the documented two-step rule: metadata block stripped
// unconditionally, body stripped only of a uniform prefix, never a body
// line reclassified by shape.
test('normalize undoes paste indentation without reclassifying body text', () => {
  const pasted = ' [GZCOORD/1] INFO\n  FROM: develop-gzapp/gzapp\n  ROLE: Application Architect\n  PROJECT: gzapp\nMESSAGE-ID: test-0001\n  BROADCAST: true\n  \n  NOTES:\n  first\n   NOTES:\n  second\n  \n  REFERENCES:\n  - adr: ADR-001\n';
  const text = normalize(pasted);
  assert.match(text, /^\[GZCOORD\/1\] INFO\nFROM: /);
  const result = validate(text);
  assert.deepEqual(result.errors, []);
  assert.ok(result.message.sections.REFERENCES.includes('- adr: ADR-001'));
  // The odd-one-out marker keeps its one extra space and is warned about, not promoted.
  assert.ok(result.message.sections.NOTES.includes(' NOTES:'));
  assert.ok(result.warnings.some(w => w.includes('swallowed section marker')));
  // The carrier prefix comes from the metadata block, never from the body:
  // a clean message whose only section is uniformly indented keeps it,
  // and a content line shaped like a marker stays content.
  const cleanIndented = '[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: R\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\n  the config we discussed:\n  YAML:\n  key: value\n';
  assert.equal(normalize(cleanIndented), cleanIndented);
  assert.deepEqual(Object.keys(validate(cleanIndented).message.sections), ['NOTES']);
  // Under a uniform paste the sender's indented marker-shaped line comes
  // back indented and stays body; a marker-shaped line at exactly the
  // carrier prefix was written at column 0 and is a marker.
  const uniform = normalize('  [GZCOORD/1] INFO\n  FROM: develop-gzapp/gzapp\n  ROLE: R\n  PROJECT: gzapp\nMESSAGE-ID: test-0001\n  BROADCAST: true\n\n  NOTES:\n  flush\n    YAML:\n  key: value\n  REFERENCES:\n  - adr: ADR-001\n');
  assert.equal(uniform, '[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: R\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n\nNOTES:\nflush\n  YAML:\nkey: value\nREFERENCES:\n- adr: ADR-001\n');
  assert.deepEqual(Object.keys(validate(uniform).message.sections), ['NOTES', 'REFERENCES']);
  // The first marker is not the source: a paste that indented it oddly
  // still strips the body by the metadata block's prefix.
  const oddFirstMarker = normalize(' [GZCOORD/1] INFO\n  FROM: develop-gzapp/gzapp\n  ROLE: R\n  PROJECT: gzapp\nMESSAGE-ID: test-0001\n  BROADCAST: true\n  \n   NOTES:\n  first\n  \n  REFERENCES:\n  - adr: ADR-001\n');
  assert.ok(validate(oddFirstMarker).message.sections.REFERENCES.includes('- adr: ADR-001'));
  // Already-clean input is unchanged, and a message with no body is handled.
  for (const name of ['hello','observation','observation-diagnosis','reply','review']) {
    const clean = fs.readFileSync(new URL(`../protocol/examples/${name}.txt`, import.meta.url), 'utf8');
    assert.equal(normalize(clean), clean, name);
  }
  assert.equal(normalize('  [GZCOORD/1] HELLO\n  FROM: a/b\n  ROLE: R\n  PROJECT: p\n'), '[GZCOORD/1] HELLO\nFROM: a/b\nROLE: R\nPROJECT: p\n');
});

test('normalize CLI prints the normalised message for validate to read', () => {
  const file = new URL('./pasted.tmp.txt', import.meta.url);
  fs.writeFileSync(file, '  [GZCOORD/1] HELLO\n  FROM: develop-gzapp/gzapp\n  ROLE: Tester\n  PROJECT: gzapp\nMESSAGE-ID: test-0001\n');
  try {
    const run = gzmsg('normalize', file.pathname);
    assert.equal(run.status, 0);
    assert.equal(run.stdout, '[GZCOORD/1] HELLO\nFROM: develop-gzapp/gzapp\nROLE: Tester\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n');
    assert.deepEqual(validate(run.stdout).errors, []);
  } finally { fs.unlinkSync(file); }
});

// SPEC §7.1: one addressing field, the delivery scope. Live traffic
// carried TO beside a TO-ROLE that matched no recorded role, and nothing
// noticed, because the address had already routed the message; a
// transport filtering by addressee could not obey two. HELLO and GOODBYE
// are broadcasts by definition.
test('exactly one of TO, TO-ROLE, BROADCAST; none on HELLO or GOODBYE', () => {
  const head = '[GZCOORD/1] INFO\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n';
  for (const pair of ['TO: develop-gzapp/web\nTO-ROLE: Web Engineer\n', 'TO: develop-gzapp/web\nBROADCAST: true\n', 'BROADCAST: true\nTO-ROLE: Web Engineer\n']) {
    const r = validate(`${head}${pair}`);
    assert.equal(r.ok, false, pair);
    assert.ok(r.errors.some(e => e.includes('are exclusive')), r.errors);
  }
  for (const one of ['TO: develop-gzapp/web\n', 'TO-ROLE: Web Engineer\n', 'BROADCAST: true\n'])
    assert.deepEqual(validate(`${head}${one}`).errors, [], one);
  for (const type of ['HELLO', 'GOODBYE']) {
    const r = validate(`[GZCOORD/1] ${type}\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO: develop-gzapp/web\n`);
    assert.ok(r.errors.some(e => e.startsWith(`${type} is a broadcast by definition`)), r.errors);
    assert.deepEqual(validate(`[GZCOORD/1] ${type}\nFROM: develop-gzapp/gzapp\nROLE: Application Architect\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n`).errors, []);
  }
});

// SPEC §4 deployment catalogue: ROLE and TO-ROLE are taxonomy slugs,
// matched by equality. One role was live in three spellings on the
// relay's first day. The address is NOT bound to the role: a role can
// change without the address changing (§4), and gzapp-claude2 is a live
// clone holding backend-dev with no slug in its name — an earlier cut of
// this rule silenced it.
test('with a taxonomy, ROLE and TO-ROLE are slugs; the address is not bound to the role', () => {
  const ok = validate('[GZCOORD/1] INFO\nFROM: develop-qzapp/architect-cto-01\nROLE: architect-cto\nPROJECT: gzapp\nMESSAGE-ID: architect-cto-01-0033\nTO: develop-qzapp/gzapp-gzcoord-coordinator\n', { taxonomy });
  assert.deepEqual(ok.errors, []);
  assert.deepEqual(ok.warnings, [], 'a well-formed message under the profile warns about nothing');
  for (const role of ['Application Architect', 'Architect / CTO']) {
    const r = validate(`[GZCOORD/1] INFO\nFROM: develop-qzapp/architect-cto-01\nROLE: ${role}\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nBROADCAST: true\n`, { taxonomy });
    assert.ok(r.errors.some(e => e.startsWith(`ROLE "${role}" is not a role slug`)), `${role}: ${r.errors}`);
  }
  // A role change without a rename: valid, with a warning naming the disagreement.
  const switched = validate('[GZCOORD/1] HELLO\nFROM: develop-qzapp/architect-cto-01\nROLE: backend-dev\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n', { taxonomy });
  assert.deepEqual(switched.errors, []);
  assert.ok(switched.warnings.some(w => w.startsWith('FROM names architect-cto but ROLE is backend-dev')), switched.warnings);
  // A clone named for no role is a session like any other, as sender and as addressee.
  assert.deepEqual(validate('[GZCOORD/1] HELLO\nFROM: develop-qzapp/gzapp-claude2\nROLE: backend-dev\nPROJECT: gzapp\nMESSAGE-ID: test-0001\n', { taxonomy }).errors, []);
  assert.deepEqual(validate('[GZCOORD/1] INFO\nFROM: develop-qzapp/db-admin\nROLE: db-admin\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO: develop-qzapp/gzapp-claude2\n', { taxonomy }).errors, []);
  for (const bad of ['Architect / CTO', 'Application Architect']) {
    const r = validate(`[GZCOORD/1] INFO\nFROM: develop-qzapp/db-admin\nROLE: db-admin\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO-ROLE: ${bad}\n`, { taxonomy });
    assert.ok(r.errors.some(e => e.startsWith(`TO-ROLE "${bad}" is not a role slug`)), r.errors);
  }
  assert.deepEqual(validate('[GZCOORD/1] INFO\nFROM: develop-qzapp/db-admin\nROLE: db-admin\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO-ROLE: architect-cto\n', { taxonomy }).errors, []);
  // Without a taxonomy none of this applies: the wire grammar is generic.
  assert.deepEqual(validate('[GZCOORD/1] INFO\nFROM: develop-qzapp/gzapp-claude2\nROLE: Anything\nPROJECT: gzapp\nMESSAGE-ID: test-0001\nTO-ROLE: Whoever\n').errors, []);
});

test('slugOf finds the longest whole-token slug an instance carries', () => {
  assert.equal(slugOf('agent-fabric-coordinator', taxonomy), 'fabric-coordinator');
  assert.equal(slugOf('gzapp-gzcoord-coordinator', taxonomy), undefined);   // renamed role: the old slug is not in the catalogue
  assert.equal(slugOf('architect-cto-01', taxonomy), 'architect-cto');
  assert.equal(slugOf('db-admin', taxonomy), 'db-admin');
  assert.equal(slugOf('gzapp-claude2', taxonomy), undefined);
  assert.equal(slugOf('web-developer', taxonomy), undefined);   // token match, not substring
  assert.ok(findTaxonomy(new URL('.', import.meta.url).pathname).endsWith('/identities/roles/catalog.json'));
});

// A fixture for the derivation tests: a throwaway agent-fabric STATE
// directory holding this agent's binding (or none, or a broken one), with
// AGENT_FABRIC_STATE_DIR pointing at it for the duration so the CLI is
// kept off the developer's real binding. The catalogue is a temp copy.
// System temp, not the tests directory: a run interrupted between the
// mkdtemp and the finally would otherwise leave an untracked file in a
// tree whose workflow blesses `git add -A`.
const login = os.userInfo().username;
function fixtureRoot(state) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gzcoord-fixture-'));
  fs.mkdirSync(`${root}/state/agents/${login}`, { recursive: true });
  fs.copyFileSync(taxonomy.path, `${root}/catalog.json`);
  if (state !== undefined) fs.writeFileSync(`${root}/state/agents/${login}/binding.json`, state);
  return root;
}
// Synchronous callbacks only: the finally fires when fn RETURNS, so an
// async fn would have its fixture removed while still running.
const withFixture = (state, fn) => {
  const root = fixtureRoot(state);
  const saved = process.env.AGENT_FABRIC_STATE_DIR;
  process.env.AGENT_FABRIC_STATE_DIR = `${root}/state`;
  try {
    const r = fn(root, `${root}/catalog.json`);
    if (r instanceof Promise) throw new TypeError('withFixture takes a synchronous callback');
    return r;
  } finally {
    if (saved === undefined) delete process.env.AGENT_FABRIC_STATE_DIR; else process.env.AGENT_FABRIC_STATE_DIR = saved;
    fs.rmSync(root, { recursive: true, force: true });
  }
};
const bound = (role) => JSON.stringify({ agent: login, host: 'h', role, updated_at: 'x' });

test('whoami: the agent is the effective login, never the directory', () => {
  const me = whoami();
  assert.equal(me.agent, login);
  assert.notEqual(me.agent, path.basename(process.cwd()) === login ? 'x' : path.basename(process.cwd()));
});

test('hello derives the slug from the address when no role is recorded, and refuses a title as ROLE', () => withFixture(undefined, (root, tax) => {
  const derived = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/architect-cto-01', '--project', 'gzapp');
  assert.equal(derived.status, 0, derived.stderr);
  assert.match(derived.stdout, /^ROLE: architect-cto$/m);
  const title = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/architect-cto-01', '--role', 'Architect / CTO', '--project', 'gzapp');
  assert.equal(title.status, 1);
  assert.match(title.stderr, /ROLE "Architect \/ CTO" is not a role slug/);
  // Outside a deployment the old contract holds.
  const generic = gzmsg('hello', '--no-taxonomy', '--from', 'develop-gzapp/anything', '--role', 'Tester', '--project', 'gzapp');
  assert.equal(generic.status, 0, generic.stderr);
}));

// The record wins over the address; a record the catalogue does not know
// is an error naming the file and the value, never a silent guess from
// the directory name; a malformed record warns and falls back; an
// explicit --role wins and is warned about when it disagrees.
test('hello prefers the recorded role, and refuses a recorded role outside the catalogue', () => {
  withFixture(bound('backend-dev'), (root, tax) => {
    const r = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/architect-cto-01', '--project', 'gzapp');
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /^ROLE: backend-dev$/m);
    assert.match(r.stderr, /^warning: FROM names architect-cto but ROLE is backend-dev/m);
    const explicit = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/backend-dev-02', '--role', 'db-admin', '--project', 'gzapp');
    assert.equal(explicit.status, 0, explicit.stderr);
    assert.match(explicit.stdout, /^ROLE: db-admin$/m);
    assert.match(explicit.stderr, /^warning: --role db-admin disagrees with .*binding\.json, which records backend-dev/m);
    assert.equal(recordedRole(loadTaxonomy(tax)).role, 'backend-dev');
  });
  withFixture(bound('security-engineer'), (root, tax) => {
    const r = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/architect-cto-01', '--project', 'gzapp');
    assert.equal(r.status, 1);
    assert.match(r.stderr, /binding\.json records role "security-engineer", which is not in .*catalog\.json; pass --role explicitly/);
    assert.equal(r.stdout, '');
    const rec = recordedRole(loadTaxonomy(tax));
    assert.equal(rec.role, undefined); assert.match(rec.error, /security-engineer/);
  });
  // A record present but saying nothing usable warns, and the warning
  // names the consequence the caller actually took — never the address
  // when the address was not what was used.
  for (const state of ['not json', JSON.stringify({ agent: login, host: 'h', updated_at: 'x' })]) {
    withFixture(state, (root, tax) => {
      const cause = state === 'not json' ? /could not be read/ : /records no role/;
      const r = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/architect-cto-01', '--project', 'gzapp');
      assert.equal(r.status, 0, r.stderr);
      assert.match(r.stdout, /^ROLE: architect-cto$/m);
      assert.match(r.stderr, cause);
      assert.match(r.stderr, /deriving architect-cto from the address instead$/m);
      assert.equal(recordedRole(loadTaxonomy(tax)).role, undefined);
      assert.match(recordedRole(loadTaxonomy(tax)).warning, cause);
      const flag = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/architect-cto-01', '--role', 'db-admin', '--project', 'gzapp');
      assert.equal(flag.status, 0, flag.stderr);
      assert.match(flag.stderr, /using --role db-admin$/m);
      const neither = gzmsg('hello', '--taxonomy', tax, '--from', 'develop-qzapp/gzapp-claude2', '--project', 'gzapp');
      assert.notEqual(neither.status, 0);
      assert.match(neither.stderr, /and the address names no role either$/m);
    });
  }
  assert.throws(() => withFixture(undefined, async () => {}), /synchronous callback/);
  // With a binding, hello needs neither --from nor --project: both come
  // from the agent (login + host) and what it is bound to.
  withFixture(JSON.stringify({ agent: login, host: 'h', role: 'web-dev', project: 'gzapp', updated_at: 'x' }), (root, tax) => {
    const r = gzmsg('hello', '--taxonomy', tax);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`^FROM: ${os.hostname().split('.')[0]}/${login}$`, 'm'));
    assert.match(r.stdout, /^ROLE: web-dev$/m);
    // The project is the WORKING COPY's when the suite runs inside a
    // registered one (agent-fabric is a managed project itself); the
    // binding's project applies only outside any.
    assert.match(r.stdout, new RegExp(`^PROJECT: ${whoami().project ?? 'gzapp'}$`, 'm'));
  });
});

// Reported from live use: a message with no MESSAGE-ID, and one whose id
// sat under a bogus `ID:` key, both validated clean -- so nothing caught
// the error. MESSAGE-ID is now REQUIRED (§7.1): absence is an error, and
// a misspelled key still warns, never rejects (§6 preserves unknown
// metadata -- that is how the protocol extends).
test('a missing MESSAGE-ID is an error; a key that misspells one is named', () => {
  const head = '[GZCOORD/1] INFO\nFROM: develop-qzapp/db-admin\nROLE: db-admin\nPROJECT: gzapp\nBROADCAST: true\n';
  const none = validate(head);
  assert.equal(none.ok, false, 'required since #641');
  assert.ok(none.errors.some(e => e === 'missing MESSAGE-ID'), none.errors);

  const bogus = validate(`${head}ID: db-admin-0007\n`);
  assert.equal(bogus.ok, false, 'the bogus key does not satisfy the required field');
  assert.ok(bogus.errors.some(e => e === 'missing MESSAGE-ID'), bogus.errors);
  assert.ok(bogus.warnings.some(w => w === 'ID is not a known field — did you mean MESSAGE-ID?'), bogus.warnings);

  // Caught by the value's shape rather than the key's spelling.
  const msgid = validate(`${head}MSG-ID: db-admin-0007\n`);
  assert.ok(msgid.warnings.some(w => w.startsWith('MSG-ID carries an id-shaped value')), msgid.warnings);

  // A real id silences everything.
  const good = validate(`${head}MESSAGE-ID: db-admin-0007\n`);
  assert.deepEqual(good.warnings, []);
});

test('unknown fields that are real extensions stay silent — §6 preserves them', () => {
  const head = '[GZCOORD/1] INFO\nFROM: develop-qzapp/db-admin\nROLE: db-admin\nPROJECT: gzapp\nBROADCAST: true\nMESSAGE-ID: db-admin-0007\n';
  for (const key of ['X-PRIORITY', 'X-TRACE', 'SEVERITY', 'DEADLINE', 'ATTN', 'THREAD', 'LOCALE']) {
    const r = validate(`${head}${key}: something\n`);
    assert.deepEqual(r.warnings, [], `${key} must not warn`);
    assert.equal(r.message.metadata[key], 'something', `${key} must be preserved`);
  }
  for (const [key, want] of [['ID','MESSAGE-ID'], ['MESSAGEID','MESSAGE-ID'], ['IN-REPLY','IN-REPLY-TO'], ['SUBJET','SUBJECT']])
    assert.equal(nearestKnownKey(key), want, key);
  for (const key of ['FROM', 'TO-ROLE', 'X-PRIORITY', 'MSG-ID'])
    assert.equal(nearestKnownKey(key), undefined, key);
});

// MESSAGE-ID is minted UUIDv7 (RFC 9562): time-ordered, unique without
// coordination, no shared counter state. The sequential counter this
// replaces existed for loss visibility on the lossy human relay; the
// durable carrier has no gap to detect, and the counter was the
// subsystem's largest defect source — five incidents. SPEC §7.2 says
// "opaque identifier": the format is a deployment convention.
test('mintId: RFC 9562 v7 shape, unique across calls, time-ordered', async () => {
  const { mintId } = await import('../scripts/gzmsg.mjs');
  const ids = Array.from({ length: 5 }, () => mintId());
  for (const id of ids) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, id);
  assert.equal(new Set(ids).size, ids.length, 'distinct');
  // The 48-bit ms timestamp is the ordering guarantee: non-decreasing
  // across mints. Within one millisecond the random part is random, so
  // full lexicographic order is NOT a v7 property and is not asserted.
  const ts = ids.map(id => parseInt(id.slice(0, 12).replace('-', ''), 16));
  for (let i = 1; i < ts.length; i++) assert.ok(ts[i] >= ts[i-1], `timestamp regressed: ${ids[i-1]} then ${ids[i]}`);
});

test('new-id CLI mints; next-id is the retired alias; --peek/--seed are refused with guidance', () => {
  const a = gzmsg('new-id');
  assert.equal(a.status, 0, a.stderr);
  assert.match(a.stdout.trim(), /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  const b = gzmsg('next-id');
  assert.equal(b.status, 0, b.stderr);
  assert.match(b.stdout.trim(), /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab]/, 'the retired name still works');
  for (const bad of [['next-id', '--instance', 'x', '--seed', '5'], ['next-id', '--instance', 'x', '--peek']]) {
    const r = gzmsg(...bad);
    assert.equal(r.status, 2, bad.join(' '));
    assert.match(r.stderr, /the sequence counter is gone/, bad.join(' '));
  }
  // new-id declares no flags at all, so the generic unknown-flag refusal
  // fires before the retired-flag message is reachable.
  {
    const r = gzmsg('new-id', '--seed', '9');
    assert.equal(r.status, 2);
    assert.match(r.stderr, /unknown flag --seed/);
  }
});

// A checkout that predated --peek accepted `next-id --peek` in silence and
// took a number: a gap nothing can fill. Every flag a command takes is now
// declared, and an unrecognised one is refused BEFORE any side effect.
test('parseArgs: unknown, valueless, repeated and surplus arguments are refused', () => {
  const spec = { valued: ['instance', 'seed'], boolean: ['peek'], positional: 0 };
  assert.deepEqual(parseArgs(['--instance', 'x', '--peek'], spec), { flags: { instance: 'x', peek: true }, positional: [] });
  assert.throws(() => parseArgs(['--instance', 'x', '--seeed', '9'], spec), /unknown flag --seeed; this command takes --instance, --seed, --peek/);
  assert.throws(() => parseArgs(['--instance', 'x', '--seed'], spec), /--seed needs a value/);
  assert.throws(() => parseArgs(['--seed', '--peek'], spec), /--seed needs a value/, 'a following flag is not a value');
  assert.throws(() => parseArgs(['--instance', 'a', '--instance', 'b'], spec), /--instance given twice/);
  assert.throws(() => parseArgs(['stray'], spec), /unexpected argument: stray/);
  const one = { valued: [], boolean: [], positional: 1 };
  assert.deepEqual(parseArgs(['file.txt'], one), { flags: {}, positional: ['file.txt'] });
  assert.throws(() => parseArgs(['a', 'b'], one), /unexpected argument: b/);
  assert.throws(() => parseArgs(['--nope'], one), /this command takes no flags/);
});

test('CLI: an unknown flag is refused before any side effect', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gzcoord-flags-'));
  try {
    const typo = gzmsg('new-id', '--seeed', '9');
    assert.equal(typo.status, 2);
    assert.match(typo.stderr, /unknown flag --seeed/);
    assert.equal(typo.stdout, '');
    assert.equal(typo.stdout, '');
    const peekTypo = gzmsg('next-id', '--instance', 'web', '--peek', '--typo');
    assert.equal(peekTypo.status, 2);
    assert.equal(peekTypo.status, 2);
    assert.equal(peekTypo.stdout, '');
    const hello = gzmsg('hello', '--no-taxonomy', '--from', 'develop-gzapp/web', '--role', 'R', '--project', 'p', '--bogus');
    assert.equal(hello.status, 2);
    assert.match(hello.stderr, /unknown flag --bogus/);
    assert.equal(hello.stdout, '');
    const file = path.join(dir, 'm.txt'); fs.writeFileSync(file, '[GZCOORD/1] HELLO\nFROM: a/b\nROLE: R\nPROJECT: p\nMESSAGE-ID: b-0001\n');
    const v = gzmsg('validate', file, '--nope');
    assert.equal(v.status, 2);
    assert.match(v.stderr, /unknown flag --nope/);
    // and the declared paths are untouched
    assert.equal(gzmsg('validate', file, '--no-taxonomy').status, 0);
    assert.match(gzmsg('new-id').stdout.trim(), /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab]/, 'the declared path mints');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// inbox.mjs applies SPEC §7.1 addressing and the §17 reading rule at
// delivery: the body of a message not addressed to this session is never
// printed. forMe() is that decision, kept pure so it can be pinned.
import { forMe, identity, waitLoop, checkKeywords, keywordHit } from '../scripts/inbox.mjs';
test('inbox forMe: exactly the messages SPEC §7.1 addresses to this session', () => {
  const me = { address: 'develop-qzapp/db-admin', instance: 'db-admin', slug: 'db-admin' };
  const mk = (type, extra) => parse(`[GZCOORD/1] ${type}\nFROM: develop-qzapp/x\nROLE: architect-cto\nPROJECT: gzapp\nMESSAGE-ID: x-0001\n${extra}`);
  assert.equal(forMe(mk('INFO', 'TO: develop-qzapp/db-admin\n'), me), true, 'TO is my address');
  assert.equal(forMe(mk('INFO', 'TO: develop-qzapp/web-dev-01\n'), me), false, 'TO is someone else');
  assert.equal(forMe(mk('INFO', 'TO-ROLE: db-admin\n'), me), true, 'TO-ROLE is my slug');
  assert.equal(forMe(mk('INFO', 'TO-ROLE: backend-dev\n'), me), false, 'TO-ROLE is another slug');
  assert.equal(forMe(mk('INFO', 'BROADCAST: true\n'), me), true, 'broadcast reaches everyone');
  assert.equal(forMe(mk('HELLO', ''), me), true, 'HELLO is a broadcast by definition');
  assert.equal(forMe(mk('GOODBYE', ''), me), true, 'GOODBYE too');
  assert.equal(forMe(mk('INFO', ''), me), false, 'no addressing field at all: not for anyone');
  // A session with no resolvable role never matches a TO-ROLE.
  assert.equal(forMe(mk('INFO', 'TO-ROLE: db-admin\n'), { ...me, slug: undefined }), false);
});

test('inbox identity: address is <host>/<login>; the slug comes from the binding, then from the login', () => {
  // The resolver's answer is what identity() consumes; the working copy
  // the process runs in is not an input at all.
  const host = 'box';
  const noRole = { agent: 'architect-cto-01', host, role: undefined, binding: '/nonexistent/binding.json' };
  assert.deepEqual(identity(noRole, taxonomy), { address: 'box/architect-cto-01', instance: 'architect-cto-01', slug: 'architect-cto', project: undefined });
  // a binding wins over the login's slug
  assert.equal(identity({ ...noRole, role: 'backend-dev', project: 'gzapp' }, taxonomy).slug, 'backend-dev');
  assert.equal(identity({ ...noRole, role: 'backend-dev', project: 'gzapp' }, taxonomy).project, 'gzapp');
  // a generic login carries no slug; the address still derives
  assert.deepEqual(identity({ agent: 'user', host, binding: '/nonexistent' }, taxonomy), { address: 'box/user', instance: 'user', slug: undefined, project: undefined });
  // no catalogue at all: address still derives, slug does not
  assert.deepEqual(identity(noRole, undefined), { address: 'box/architect-cto-01', instance: 'architect-cto-01', slug: undefined, project: undefined });
  // and the real resolver names this process's login
  assert.equal(identity(whoami(), undefined).instance, login);
});

// The wait exits ONLY on a message addressed to this session: a slice
// holding only others' traffic is acknowledged and the arm CONTINUES —
// waking a session for its neighbours' messages is the noise the tool
// exists to remove. Injected fetch/ack pages make the loop deterministic.
test('waitLoop exits only on an addressed message; others pass acknowledged', async () => {
  const me = { address: 'develop-qzapp/db-admin', instance: 'db-admin', slug: 'db-admin' };
  const rec = (id, type, extra) => ({ id, sender: 'develop-qzapp/x', timestamp: 't', content: `[GZCOORD/1] ${type}\nFROM: develop-qzapp/x\nROLE: architect-cto\nPROJECT: gzapp\nMESSAGE-ID: x-${id}\n${extra}` });
  const forYou = rec('m3', 'INFO', 'BROADCAST: true\n');
  const othersPage = { messages: [rec('m1', 'INFO', 'TO: develop-qzapp/web-dev-01\n'), rec('m2', 'OBSERVATION', 'TO-ROLE: backend-dev\n')] };
  const acked = [];
  const ack = id => { acked.push(id); return Promise.resolve(); };
  const pages = [othersPage, { messages: [forYou] }];
  const fetchPage = async () => pages.shift();
  let fetches = 0;
  const countingFetch = async () => { fetches += 1; return pages.shift(); };
  const r = await waitLoop({ fetchPage: countingFetch, ack, waitTotal: 1800, forMeFn: msg => forMe(msg, me) });
  assert.equal(r.delivered, true, 'exits on the addressed message, not the neighbours\' one');
  assert.equal(fetches, 2, 'two slices: the passed one and the delivering one');
  assert.equal(r.waited, 110, 'budget accounting: two 55 s slices');
  assert.equal(r.classified.find(c => c.rec.id === 'm3').isMine, true);
  assert.deepEqual(acked.sort(), ['m1', 'm2', 'm3'], 'every shown message is acknowledged');
  // A page of nothing-but-others at budget end: quiet exit, counted.
  const r2 = await waitLoop({
    fetchPage: async () => ({ messages: [rec('m9', 'INFO', 'TO: develop-qzapp/web-dev-01\n')] }),
    ack: async () => {}, waitTotal: 4, forMeFn: msg => forMe(msg, me) });
  assert.equal(r2.delivered, false);
  assert.equal(r2.othersPassed, 1);
  assert.equal(r2.waited, 4, 'spent the whole budget');
  // Drain mode returns the first page whatever it holds.
  const r3 = await waitLoop({
    fetchPage: async () => ({ messages: [rec('m1', 'INFO', 'TO: develop-qzapp/web-dev-01\n')] }),
    ack: async () => {}, waitTotal: 0, forMeFn: msg => forMe(msg, me) });
  assert.equal(r3.delivered, false, 'drain does not exit early — it lists');
  assert.equal(r3.classified.length, 1);
  // A HELLO is a broadcast by definition: it wakes the waiter.
  const r4 = await waitLoop({
    fetchPage: async () => ({ messages: [rec('h', 'HELLO', '')] }),
    ack: async () => {}, waitTotal: 1800, forMeFn: msg => forMe(msg, me) });
  assert.equal(r4.delivered, true, 'HELLO is a broadcast by definition');
});

// --keyword: reasons to stop waiting on a message NOT addressed to this
// session. Guardrails exist because the abusable shape — a keyword that
// fires on every message — is the address-blind wake with extra steps.
test('checkKeywords: minimum length, hard cap, dedup', () => {
  assert.deepEqual(checkKeywords(['663', 'geocode']), ['663', 'geocode']);
  assert.deepEqual(checkKeywords(['663', '663']), ['663'], 'deduplicated');
  for (const bad of ['ab', '6', '', 'a']) assert.throws(() => checkKeywords([bad]), /shorter than 3 characters/, JSON.stringify(bad));
  assert.throws(() => checkKeywords(['aaa','bbb','ccc','ddd','eee','fff','ggg','hhh','iii']), /at most 8 keywords/);
  assert.doesNotThrow(() => checkKeywords(['aaa','bbb','ccc','ddd','eee','fff','ggg','hhh']), 'exactly 8 is allowed');
});

test('keywordHit: whole-token, case-insensitive, full text; own echo never hits', () => {
  const text = '[GZCOORD/1] INFO\nFROM: develop-qzapp/x\nPROJECT: gzapp\nMESSAGE-ID: x-0001\nBROADCAST: true\nSUBJECT: PR 663 discussion\n\nNOTES:\nsee REFERENCES - github-pr: #663 and #2663\n';
  const own = 'develop-qzapp/x';
  for (const [kw, want] of [['663', true], ['pr', true], ['2663', true], ['references', true], ['6', false], ['66', false], ['GEQ', false], ['266', false], ['663-x', false]])
    assert.equal(keywordHit(text, [kw], own), want, kw);
  // multiple keywords: any hit wakes
  assert.equal(keywordHit(text, ['zzz', 'geocode'], own), false);
  assert.equal(keywordHit(text, ['zzz', 'pr-'], own), false, 'whole-token, not substring');
  // the armed session's own messages never wake it — the echo exemption
  assert.equal(keywordHit(text, ['663'], undefined), true, 'no ownAddress known: token match stands');
  assert.equal(keywordHit(text, ['develop-qzapp'], own), false, 'own FROM token removed');
  assert.equal(keywordHit(text, ['pr'], undefined), true, 'PR token matches without own address too');
  assert.equal(keywordHit('', ['anything'], undefined), false, 'empty text never hits');
});

test('waitLoop --keyword: a passing non-addressed message ends the arm with code-3 data', async () => {
  const me = { address: 'develop-qzapp/db-admin', instance: 'db-admin', slug: 'db-admin' };
  const rec = (id, type, extra) => ({ id, sender: 'develop-qzapp/x', timestamp: 't', content: `[GZCOORD/1] ${type}\nFROM: develop-qzapp/x\nROLE: architect-cto\nPROJECT: gzapp\nMESSAGE-ID: x-${id}\n${extra}` });
  // a message addressed to SOMEONE ELSE whose body mentions the keyword
  const pages = [
    { messages: [rec('m1', 'INFO', 'TO: develop-qzapp/web-dev-01\n'), rec('m2', 'OBSERVATION', 'TO-ROLE: backend-dev\nSUBJECT: unrelated schema review\n')] },
    { messages: [rec('m3', 'REPLY', 'TO: develop-qzapp/web-dev-01\n\nREFERENCES:\n- github-pr: #663\n')] },
  ];
  let fetches = 0; const acked = [];
  const r = await waitLoop({
    fetchPage: async () => { fetches += 1; return pages.shift(); },
    ack: async id => { acked.push(id); },
    waitTotal: 1800, forMeFn: msg => forMe(msg, me), keywords: checkKeywords(['663']), ownAddress: me.address });
  assert.equal(r.delivered, false, 'never addressed to me');
  assert.equal(r.keywordHit.id, 'm3', 'the keyword message is the exit reason');
  assert.equal(fetches, 2, 'the first slice (no hit) continued the arm');
  assert.deepEqual(acked.sort(), ['m1', 'm2', 'm3'], 'passed messages are acknowledged too');
  assert.equal(r.othersPassed, 1, 'one other in the delivering slice is passed');
  // the echo exemption inside waitLoop: a message FROM my address never ends the arm
  const selfPage = () => ({ messages: [rec('me-1', 'INFO', 'BROADCAST: true\n')] });
  const echoFromSelf = rec('echo', 'INFO', 'BROADCAST: true\n');
  echoFromSelf.sender = me.address; echoFromSelf.content = echoFromSelf.content.replace('develop-qzapp/x', me.address);
  const r2 = await waitLoop({
    fetchPage: async () => ({ messages: [echoFromSelf] }),
    ack: async () => {}, waitTotal: 1800, forMeFn: msg => forMe(msg, me), keywords: checkKeywords(['663']), ownAddress: me.address });
  assert.equal(r2.keywordHit, null, 'own echo: no hit');
  assert.equal(r2.delivered, true, 'a broadcast from self is still addressed to me (unchanged)');
  // budget expiry with a keyword set and no hit: quiet, counted
  const r3 = await waitLoop({
    fetchPage: async () => ({ messages: [rec('m9', 'INFO', 'TO: develop-qzapp/web-dev-01\n')] }),
    ack: async () => {}, waitTotal: 4, forMeFn: msg => forMe(msg, me), keywords: checkKeywords(['663']), ownAddress: me.address });
  assert.equal(r3.keywordHit, null); assert.equal(r3.delivered, false); assert.equal(r3.waited, 4);
});
