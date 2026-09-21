// The lines the inbox prints, in the language of the login that reads
// them (scripts/i18n.mjs, i18n/README.md, docs/language-culture-bridge.md).
//
// The load-bearing case is the last one: a default-locale login's output
// is byte-identical to what it was before a dictionary existed.
// Everything else here is the seam — that a locale reaches the fabric's
// own lines and stops at the wire's.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { scratch } from '../../../tests/scratch.mjs';
import { DEFAULT_LOCALE, DEFAULT_PATH, defaultDictionary, dictionary, dictionaryPath,
         fill, localeReminder, localeTag, printer, suffix } from '../scripts/i18n.mjs';
import { checkKeywords, render } from '../scripts/inbox.mjs';

const SCRIPTS = fileURLToPath(new URL('../scripts/', import.meta.url));
const FABRIC = fileURLToPath(new URL('../../../', import.meta.url));
// The key shape is the schema's, read — not a third copy of the rule
// (blind review F6 on PR #28).
const SLUG = new RegExp(JSON.parse(
  fs.readFileSync(fileURLToPath(new URL('../i18n/i18n.schema.json', import.meta.url)), 'utf8')
).propertyNames.pattern);

test('the default dictionary is the house i18n shape: dotted slugs, non-empty strings', () => {
  const en = defaultDictionary();
  assert.equal(path.basename(DEFAULT_PATH), `${DEFAULT_LOCALE}.json`);
  for (const [k, v] of Object.entries(en)) {
    assert.match(k, SLUG, `key ${k}`);
    assert.equal(typeof v, 'string', `value of ${k}`);
    assert.notEqual(v, '', `value of ${k}`);
  }
});

test('the locale a login reads is the launcher\'s rule: what follows the last dash', () => {
  assert.equal(suffix('language-culture-ge'), 'ge');
  assert.equal(suffix('language-culture-ru'), 'ru');
  assert.equal(suffix('brand-comms-01'), '01');   // no locale/01: the default
  assert.equal(suffix('user'), 'user');
});

test('the suffix names its tag in locale.json — ge is Georgian, not German', () => {
  const root = FABRIC;
  const dir = s => path.join(root, 'identities', 'roles', 'language-culture', 'locale', s);
  assert.equal(localeTag(dir('ge')), 'ka-GE');
  assert.equal(localeTag(dir('ru')), 'ru-RU');
  assert.equal(localeTag(dir('nothing-here')), undefined);
});

test('every key the code prints is in en-US.json, and en-US.json has no key nothing prints', () => {
  const en = defaultDictionary();
  const used = new Set();
  for (const file of ['inbox.mjs']) {
    const src = fs.readFileSync(path.join(SCRIPTS, file), 'utf8');
    for (const m of src.matchAll(/\bt\('([a-z][a-z.-]+)'/g)) used.add(m[1]);
    for (const m of src.matchAll(/\ben\(\)\('([a-z][a-z.-]+)'/g)) used.add(m[1]);
  }
  assert.deepEqual([...used].filter(k => !(k in en)).sort(), [], 'printed but not in en-US.json');
  assert.deepEqual(Object.keys(en).filter(k => !used.has(k)).sort(), [], 'in en-US.json but nothing prints it');
});

const active = (body, { tag = 'ka-GE', locale = { tag } } = {}) => {
  const root = scratch('locale-');
  const dir = path.join(root, 'identities', 'roles', 'language-culture', 'locale', 'ge');
  fs.mkdirSync(dir, { recursive: true });
  if (locale) fs.writeFileSync(path.join(dir, 'locale.json'), JSON.stringify(locale));
  if (body !== null) fs.writeFileSync(path.join(dir, `${tag}.json`), body);
  return { root, dir, me: { agent: 'language-culture-ge', role: 'language-culture' } };
};

test('a login with no active dictionary reads the default locale', () => {
  const root = scratch('locale-');
  assert.equal(dictionaryPath({ agent: 'user', role: 'fabric-coordinator' }, root), null);
  assert.equal(dictionaryPath({ agent: 'language-culture-ge' }, root), null, 'no role bound');
  const { root: r1, me } = active(null);
  assert.equal(dictionaryPath(me, r1), null, 'a tag with no dictionary file');
  const { root: r2 } = active('{}', { locale: null });
  assert.equal(dictionaryPath({ agent: 'language-culture-ge', role: 'language-culture' }, r2), null, 'no tag');
});

test('an active locale is found by its tag', () => {
  const { root, dir, me } = active('{}');
  assert.equal(dictionaryPath(me, root), path.join(dir, 'ka-GE.json'));
});

test('an active locale covers the keys it carries; the default stands for the rest', () => {
  const { root, me } = active(JSON.stringify({
    'inbox.others-header': 'ᲗᲐᲠᲒᲛᲐᲜᲘ (SPEC §17):',
    'inbox.head': '',                     // not a localization value
    'nothing.like-this': 'invented',      // not a key of the default
  }));
  const dict = dictionary(me, { root }), en = defaultDictionary();
  assert.equal(dict['inbox.others-header'], 'ᲗᲐᲠᲒᲛᲐᲜᲘ (SPEC §17):');
  assert.equal(dict['inbox.head'], en['inbox.head'], 'an empty value is not a translation');
  assert.equal(dict['delivery.title'], en['delivery.title'], 'a key it lacks falls back, never invented');
  assert.ok(!('nothing.like-this' in dict), 'a key the default does not have is not added');
});

test('an unreadable dictionary leaves the default standing — a session start never fails on it', () => {
  const { root, me } = active('{ this is not json');
  assert.deepEqual(dictionary(me, { root }), defaultDictionary());
});

test('a placeholder the caller did not supply is left standing, not blanked', () => {
  assert.equal(fill('seq {first}–{last}', { first: 1, last: 9 }), 'seq 1–9');
  assert.equal(fill('a {who} and {missing}', { who: 'x' }), 'a x and {missing}');
});

test('an unknown key prints as itself: a bug report, not a crash', () => {
  assert.equal(printer(defaultDictionary())('no.such-key'), 'no.such-key');
});

const fixture = () => {
  const body = (id, to) => `[GZCOORD/1] OBSERVATION\nFROM: h/sender\nROLE: backend-dev\nPROJECT: gzapp\nMESSAGE-ID: ${id}\n${to}\nSUBJECT: a subject\n\nNOTES:\nthe body, as its sender wrote it\n`;
  const rec = (seq, content) => ({ seq, id: `r${seq}`, sender: 'h/sender', timestamp: '2026-09-21T08:00:00Z', content });
  return { delivered: true, classified: [
    { rec: rec(1, body('01a0-1', 'TO: h/me')), msg: { type: 'OBSERVATION', metadata: { 'MESSAGE-ID': '01a0-1', TO: 'h/me', SUBJECT: 'a subject' } }, isMine: true },
    { rec: rec(2, body('01a0-2', 'TO: h/other')), msg: { type: 'OBSERVATION', metadata: { 'MESSAGE-ID': '01a0-2', TO: 'h/other', SUBJECT: 'other' } }, isMine: false },
  ] };
};
const ME = { address: 'h/me', instance: 'me', slug: 'language-culture' };

test('the locale reaches the fabric\'s own lines and stops at the wire', () => {
  const { root, me } = active(JSON.stringify({
    'inbox.head': 'ᲨᲔᲛᲝᲡᲣᲚᲘ {who}: {mine} / {others}, {channel}',
    'inbox.others-header': 'ᲐᲠ ᲐᲠᲘᲡ ᲨᲔᲜᲗᲕᲘᲡ (SPEC §17):',
  }));
  const out = render(fixture(), ME, 'gzapp:gzcoord', undefined, { t: printer(dictionary(me, { root })) });
  assert.match(out, /^ᲨᲔᲛᲝᲡᲣᲚᲘ h\/me \(language-culture\): 1 \/ 1, gzapp:gzcoord$/m);
  assert.match(out, /^ᲐᲠ ᲐᲠᲘᲡ ᲨᲔᲜᲗᲕᲘᲡ \(SPEC §17\):$/m);
  // The wire, untouched: the sender's body, the metadata keys, the type,
  // and the addressing vocabulary a reader matches by name.
  assert.match(out, /^\[GZCOORD\/1\] OBSERVATION$/m);
  assert.match(out, /^MESSAGE-ID: 01a0-1$/m);
  assert.match(out, /^the body, as its sender wrote it$/m);
  assert.match(out, /01a0-2 {2}OBSERVATION {2}TO h\/other {2}other/);
});

test('the locale\'s standing reminder rides the head line, and only it', () => {
  const { root, me } = active(JSON.stringify({ 'inbox.head': 'ᲨᲔᲛᲝᲡᲣᲚᲘ {who}, {channel}' }),
                              { locale: { tag: 'ka-GE', reminder: ' - ᲘᲤᲘᲥᲠᲔ' } });
  const reminder = localeReminder(me, root);
  assert.equal(reminder, ' - ᲘᲤᲘᲥᲠᲔ');
  const out = render(fixture(), ME, 'gzapp:gzcoord', undefined,
                     { t: printer(dictionary(me, { root })), reminder });
  assert.match(out, /^ᲨᲔᲛᲝᲡᲣᲚᲘ h\/me \(language-culture\), gzapp:gzcoord - ᲘᲤᲘᲥᲠᲔ$/m);
  assert.equal(out.split('\n').filter(l => l.includes('ᲘᲤᲘᲥᲠᲔ')).length, 1, 'the head line and no other');
});

test('no locale, no reminder: nothing is appended for a default-locale login', () => {
  const root = scratch('locale-');
  assert.equal(localeReminder({ agent: 'user', role: 'fabric-coordinator' }, root), '');
  assert.equal(localeReminder({ agent: 'language-culture-ge' }, root), '', 'no role bound');
  const { root: r } = active('{}', { locale: { tag: 'ka-GE' } });
  assert.equal(localeReminder({ agent: 'language-culture-ge', role: 'language-culture' }, r), '',
               'a locale that declares none');
});

test('the reminder each real locale carries is the owner\'s, in that locale', () => {
  const root = FABRIC;
  const of = s => localeReminder({ agent: `language-culture-${s}`, role: 'language-culture' }, root);
  for (const s of ['ge', 'ru']) {
    assert.notEqual(of(s), '', `${s} carries one`);
    assert.match(of(s), /^ - /, `${s} appends to the head line`);
    assert.ok(/[^\u0000-\u024F]/.test(of(s)), `${s} is in its own script`);
  }
});

// The dictionary is the one thing whose failure the last-resort handler
// cannot report through the dictionary. Copying scripts/ and i18n/ into a
// scratch tree is what makes a damaged en-US.json reachable at all: the
// default is resolved from the MODULE, deliberately, so nothing in the
// environment can point it elsewhere (blind review F1 on PR #28).
const brokenTree = (contents) => {
  const dir = scratch('i18n-broken-');
  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'i18n'), { recursive: true });
  for (const f of fs.readdirSync(SCRIPTS)) fs.copyFileSync(path.join(SCRIPTS, f), path.join(dir, 'scripts', f));
  fs.writeFileSync(path.join(dir, 'i18n', 'en-US.json'), contents);
  return path.join(dir, 'scripts', 'inbox.mjs');
};

for (const [what, contents] of [['unparsable', '{ not json'], ['absent', null]]) {
  test(`a ${what} default dictionary is one line and exit 0, never a stack trace`, () => {
    const entry = brokenTree(contents ?? '{}');
    if (contents === null) fs.rmSync(path.join(path.dirname(entry), '..', 'i18n', 'en-US.json'));
    const r = spawnSync(process.execPath, [entry, '--held'],
                        { env: { ...process.env, AGENT_FABRIC_ROOT: FABRIC.replace(/\/$/, '') }, encoding: 'utf8' });
    const { status, stderr } = r;
    assert.equal(status, 0, `exited ${status}: ${stderr}`);
    assert.ok(!/^\s+at /m.test(stderr), `a stack trace reached the session:\n${stderr}`);
    assert.match(stderr, /gzcoord inbox: /, stderr);
  });
}

test('a keyword refusal reads in the login\'s own language', () => {
  const ka = printer({ ...defaultDictionary(), 'keyword.too-short': 'ᲛᲝᲙᲚᲔᲐ {keyword} — {min}' });
  assert.throws(() => checkKeywords(['ab'], ka), /ᲛᲝᲙᲚᲔᲐ "ab" — 3/);
  const many = Array.from({ length: 9 }, (_, i) => `kw${i}`);
  const ka2 = printer({ ...defaultDictionary(), 'keyword.too-many': 'ᲖᲔᲓᲐ ᲖᲦᲕᲐᲠᲘ {max}' });
  assert.throws(() => checkKeywords(many, ka2), /ᲖᲔᲓᲐ ᲖᲦᲕᲐᲠᲘ 8/);
});

test('a default-locale login renders exactly what it rendered before a dictionary existed', () => {
  const out = render(fixture(), ME, 'gzapp:gzcoord', undefined, {});
  assert.match(out, /^gzcoord inbox for h\/me \(language-culture\): 1 for you, 1 not addressed to you, on gzapp:gzcoord$/m);
  assert.match(out, /^Not addressed to you — listed, bodies not read \(SPEC §17\):$/m);
  assert.match(out, /^--- relay seq 1, from h\/sender, 2026-09-21T08:00:00Z$/m);
});
