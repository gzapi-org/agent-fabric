#!/usr/bin/env node
import fs from 'node:fs';

const CORE_TYPES = new Set(['HELLO','GOODBYE','INFO','OBSERVATION','QUESTION','REQUEST','REVIEW','DECISION','HANDOFF','REPLY']);
const FORBIDDEN = new Set([
  'MODEL','PROVIDER','WORKING-DIRECTORY','WORKING_DIRECTORY',
  'TOKEN-BUDGET','TOKEN_BUDGET','REASONING-BUDGET','REASONING_BUDGET',
  'SUBAGENT-DEPTH','SUBAGENT-LIMIT','SUBAGENT_LIMIT',
  'TELEGRAM-BOT','TELEGRAM_BOT','TELEGRAM-BOT-USERNAME','TELEGRAM-CHAT-ID',
  'BOT-TOKEN','BOT_TOKEN','SLACK-CHANNEL-ID','DISCORD-GUILD-ID',
]);
const addressRe = /^[a-z0-9._-]+\/[a-z0-9._-]+$/;

// Terminal columns a line occupies. ECMAScript regexes cannot express
// East_Asian_Width, so wide is the wcwidth range table (Wide and
// Fullwidth, halfwidth forms excluded — Script=Katakana would have
// counted the halfwidth block U+FF66–FF9D as 2, a false warning) plus
// emoji-presentation characters; combining and format characters are 0;
// a tab advances to the next multiple of 8; everything else is 1.
// Emoji_Presentation, not Extended_Pictographic: the latter includes
// text-default symbols (©, ™, ↔, ❤) that render in one column. A regional
// indicator is 1 so that a flag pair (two of them) is 2. Reproduces
// `wc -L` on the probes in the test. East Asian Ambiguous characters
// (§, —) and VS16-forced emoji (❤️) count 1, which only the reader's
// terminal can decide — `wc -L` says 1 for both; the one exception is
// U+3248–324F, Ambiguous by property but 2 here and in `wc -L`, because
// they sit inside the CJK block the table takes whole. Where a block is
// wholly Wide or Fullwidth, its range runs to the block end, not to the
// last code point assigned at some vintage: a range pinned to an
// assignment silently drops every later one (U+16FF2–16FF6, the Tangut
// additions at U+18D00–18D1E and U+18D80–18DF2, U+2630–2637 all arrived
// after the classic table), and an unassigned code point inside a wide
// block will be wide when it is assigned, so over-counting it now is the
// right answer early. Three wholly-wide ranges stop short on purpose —
// FE10–FE19, FE50–FE6B, 1F200–1F26F — because the code point past the
// block end is zero-width (U+FE20) or wide by another rule (U+1F300),
// so extended to the block end they would have no narrow neighbour to
// pin the edge in the test. Where a block mixes widths — Halfwidth and
// Fullwidth Forms, Hangul Jamo, CJK Symbols and Punctuation,
// Miscellaneous Technical, Miscellaneous Symbols, Counting Rod Numerals
// — the range stops at the last wide code point, and must not be
// "finished" to the block end: 40 card suits would report 81 columns.
const WIDE_RANGES = [
  [0x1100, 0x115F], [0x2329, 0x232A], [0x2630, 0x2637], [0x268A, 0x268F],
  [0x2E80, 0x303E], [0x3041, 0x33FF], [0x3400, 0x4DBF], [0x4DC0, 0x4DFF],
  [0x4E00, 0x9FFF], [0xA000, 0xA4CF], [0xA960, 0xA97F], [0xAC00, 0xD7A3],
  [0xF900, 0xFAFF], [0xFE10, 0xFE19], [0xFE30, 0xFE4F], [0xFE50, 0xFE6B],
  [0xFF00, 0xFF60], [0xFFE0, 0xFFE6],
  [0x16FE0, 0x16FFF], [0x17000, 0x18AFF], [0x18B00, 0x18CFF], [0x18D00, 0x18DFF],
  [0x1AFF0, 0x1AFFF], [0x1B000, 0x1B2FF], [0x1D300, 0x1D376], [0x1F200, 0x1F26F],
  [0x20000, 0x2FFFD], [0x30000, 0x3FFFD],
];
const EMOJI = /\p{Emoji_Presentation}/u;
const REGIONAL_INDICATOR = /\p{RI}/u;
const ZERO = /\p{Mn}|\p{Me}|\p{Cf}/u;
function isWide(ch) {
  const cp = ch.codePointAt(0);
  return WIDE_RANGES.some(([lo, hi]) => cp >= lo && cp <= hi) || (EMOJI.test(ch) && !REGIONAL_INDICATOR.test(ch));
}
export function columns(line) {
  let w = 0;
  for (const ch of line) {
    if (ch === '\t') { w += 8 - (w % 8); continue; }
    if (ZERO.test(ch)) continue;
    w += isWide(ch) ? 2 : 1;
  }
  return w;
}

export function parse(text) {
  // A byte-order mark is an encoding artefact, not the first character of
  // the header; some editors prepend one on save.
  const lines = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').split('\n');
  const first = lines.shift() ?? '';
  const m = first.match(/^\[GZCOORD\/1\] ([A-Z][A-Z0-9-]*)$/);
  if (!m) throw new Error('invalid GZCOORD/1 first line');
  const type = m[1];
  const metadata = {};
  const duplicateKeys = new Set();
  const sections = {};
  const malformed = [];
  let currentSection = null;
  let inSections = false;
  for (const line of lines) {
    if (/^[A-Z][A-Z0-9-]*:$/.test(line)) {
      inSections = true;
      currentSection = line.slice(0, -1);
      // A repeated marker resumes its section. The grammar does not require
      // section names to be unique, so resetting here would drop the earlier
      // block from a message the validator still calls valid.
      if (!(currentSection in sections)) sections[currentSection] = '';
      continue;
    }
    if (!inSections && /^[A-Z][A-Z0-9-]*: /.test(line)) {
      const idx = line.indexOf(':');
      const key = line.slice(0, idx);
      // A repeated key has no defined meaning (a repeated section marker
      // resumes its section; SPEC.md §6 gives a key no such rule). Collapsing
      // silently let an invalid earlier value — REPLY-EXPECTED: maybe, a
      // malformed FROM — hide behind a valid later one and validate clean.
      if (key in metadata) duplicateKeys.add(key);
      metadata[key] = line.slice(idx + 1).trim();
      continue;
    }
    if (currentSection) sections[currentSection] += `${sections[currentSection] ? '\n' : ''}${line}`;
    else if (line.trim() !== '') malformed.push(line);
  }
  return { type, metadata, sections, malformed, duplicateKeys: [...duplicateKeys] };
}

export function validate(text) {
  const errors = [];
  const warnings = [];
  let msg;
  // parse() throws on a bad header because nothing after it can be read;
  // validate() reports that like any other error, so the CLI prints one
  // line instead of a stack trace and callers see a uniform result shape.
  try { msg = parse(text); }
  catch (e) { return { ok: false, errors: [e.message], warnings, message: null }; }
  if (!CORE_TYPES.has(msg.type) && !msg.type.startsWith('X-')) errors.push(`unknown type: ${msg.type}`);
  for (const key of ['FROM','ROLE','PROJECT']) if (!msg.metadata[key]) errors.push(`missing ${key}`);
  if (msg.metadata.FROM && !addressRe.test(msg.metadata.FROM)) errors.push('FROM must be <host>/<instance>');
  if (msg.metadata.TO && !addressRe.test(msg.metadata.TO)) errors.push('TO must be <host>/<instance>');
  if (msg.metadata['REPLY-EXPECTED'] !== undefined && !['yes','no'].includes(msg.metadata['REPLY-EXPECTED'])) errors.push('REPLY-EXPECTED must be yes or no');
  // SPEC §7.1: the field's only value is `true`. `BROADCAST: yes` used to fail
  // as "missing TO, TO-ROLE or BROADCAST: true", which names the wrong fault,
  // and `BROADCAST: false` beside a TO validated clean with undefined meaning.
  if (msg.metadata.BROADCAST !== undefined && msg.metadata.BROADCAST !== 'true') errors.push('BROADCAST must be true, or absent');
  if (!['HELLO','GOODBYE'].includes(msg.type)) {
    if (!msg.metadata.TO && !msg.metadata['TO-ROLE'] && msg.metadata.BROADCAST !== 'true') errors.push('missing TO, TO-ROLE or BROADCAST: true');
  }
  for (const key of Object.keys(msg.metadata)) if (FORBIDDEN.has(key)) errors.push(`${key} is local/runtime data and forbidden on the wire`);
  for (const line of msg.malformed) errors.push(`unparsable line in the metadata block: ${line}`);
  for (const key of msg.duplicateKeys) errors.push(`${key} appears more than once in the metadata block`);
  // A body line that is marker-shaped up to whitespace — indented, or with
  // trailing whitespace — is body text by SPEC §6, the grammar admits no
  // other reading; but it is also the exact shape a paste-indented or
  // editor-padded section marker takes, and the message validates while the
  // section silently folds into the one before it. Warn, naming the line, so
  // the recipient asks the sender: detection by tool, decision by the agent.
  // Never reclassify it as a marker. (An exact marker never reaches a body,
  // so every match here carries the whitespace that kept it from being one.)
  for (const [name, body] of Object.entries(msg.sections))
    for (const line of body.split('\n'))
      if (/^\s*[A-Z][A-Z0-9-]*:\s*$/.test(line))
        warnings.push(`possible swallowed section marker inside ${name}: ${JSON.stringify(line)}`);
  // The same padding in the metadata block turns a marker into an
  // empty-valued key: `NOTES: ` is metadata NOTES="", and the body that
  // follows is then reported as unparsable — true, but not the fault.
  for (const [key, value] of Object.entries(msg.metadata))
    if (value === '')
      warnings.push(`${key} has an empty value — a section marker with trailing whitespace reads as metadata`);
  // Not a grammar rule — SPEC §14 keeps carrier limits off the wire — but
  // the current carrier is a terminal copy, and a line it re-breaks stops
  // being metadata (docs/HUMAN-RELAY-TRANSPORT.md, "Sending"). Advisory,
  // and the width is the relay's, so a future transport drops or moves it.
  // Measured in columns, not code units: String.length undercounts CJK
  // and overcounts combining marks and astral characters.
  const RELAY_MAX_COLUMNS = 72;
  text.replace(/^\uFEFF/, '').split(/\r?\n/).forEach((line, i) => {
    const w = columns(line);
    if (w > RELAY_MAX_COLUMNS)
      warnings.push(`line ${i + 1} is ${w} columns wide; over ${RELAY_MAX_COLUMNS} the relay may re-break it`);
  });
  return { ok: errors.length === 0, errors, warnings, message: msg };
}

// Undo what a terminal copy does to a message, and nothing more
// (docs/HUMAN-RELAY-TRANSPORT.md, "Receiving"). The metadata block — every
// line up to and including the first section marker — is stripped of
// leading whitespace unconditionally: the grammar admits no indented
// content there, so the strip is never ambiguous. That same fact makes
// the metadata block the one place the carrier's indentation can be read
// off: the most common leading whitespace across its KEY: value lines
// (ties to the shorter) is what the paste added, and exactly that prefix
// is removed from each later line that begins with it. Every other body
// line is left alone: indentation inside a body is content, and the
// body's own common prefix cannot tell the sender's indentation from the
// carrier's — an unindented paste with a uniformly indented body used to
// lose it. A paste that indented nothing therefore returns the body
// byte for byte, and a uniform paste leaves nothing ambiguous: a sender's
// indented `  YAML:` comes back indented and stays body, and a
// marker-shaped line at exactly the carrier's prefix was written at
// column 0, so it is the marker it looks like. A marker the paste
// indented differently from its neighbours is the case that remains,
// and validate() warns about it. The first marker is not the source: the
// observed relay indented one marker differently from every line around
// it, and the mandatory FROM / ROLE / PROJECT lines outvote it.
export function normalize(text) {
  const lines = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').split('\n');
  const out = [];
  const votes = new Map();
  let i = 0;
  for (; i < lines.length; i++) {
    const stripped = lines[i].replace(/^\s+/, '');
    out.push(stripped);
    if (/^[A-Z][A-Z0-9-]*:$/.test(stripped)) { i++; break; }
    if (i > 0 && /^[A-Z][A-Z0-9-]*: /.test(stripped)) {
      const ws = lines[i].slice(0, lines[i].length - stripped.length);
      votes.set(ws, (votes.get(ws) ?? 0) + 1);
    }
  }
  let prefix = '';
  let best = 0;
  for (const [ws, n] of votes) if (n > best || (n === best && ws.length < prefix.length)) { prefix = ws; best = n; }
  for (const l of lines.slice(i)) out.push(prefix && l.startsWith(prefix) ? l.slice(prefix.length) : l);
  return out.join('\n');
}

// The address is derived from the working copy and outlives any one
// session of it, so the MESSAGE-ID sequence has to as well: a session that
// restarted at 0001 repeated four numbers a peer had already seen, and a
// repeat defeats gap detection the same way a gap does. The counter lives
// beside the working copy in a gitignored file, one per instance.
export function nextId(instance, stateDir = '.gzcoord') {
  if (!/^[a-z0-9._-]+$/.test(instance)) throw new Error('instance must be the <instance> half of an address');
  fs.mkdirSync(stateDir, { recursive: true });
  const file = `${stateDir}/${instance}.seq`;
  const last = fs.existsSync(file) ? Number.parseInt(fs.readFileSync(file, 'utf8'), 10) : 0;
  if (!Number.isInteger(last) || last < 0) throw new Error(`${file} does not hold a sequence number`);
  const next = last + 1;
  fs.writeFileSync(file, `${next}\n`);
  return `${instance}-${String(next).padStart(4, '0')}`;
}

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const cmd = process.argv[2];
  if (cmd === 'validate') {
    const file = process.argv[3];
    if (!file) throw new Error('usage: gzmsg.mjs validate <file>');
    const result = validate(fs.readFileSync(file, 'utf8'));
    // Warnings print on both paths: on a failure they are often the cause
    // the errors only describe from downstream.
    for (const w of result.warnings) console.error(`warning: ${w}`);
    if (!result.ok) { console.error(result.errors.join('\n')); process.exit(1); }
    console.log('valid GZCOORD/1 message');
  } else if (cmd === 'hello') {
    const from = arg('from'), role = arg('role'), project = arg('project');
    if (!from || !role || !project) throw new Error('hello requires --from --role --project');
    const lines = [`[GZCOORD/1] HELLO`,`FROM: ${from}`,`ROLE: ${role}`,`PROJECT: ${project}`];
    if (arg('message-id')) lines.push(`MESSAGE-ID: ${arg('message-id')}`);
    if (arg('specialties')) lines.push(`SPECIALTIES: ${arg('specialties')}`);
    if (arg('capabilities')) lines.push(`CAPABILITIES: ${arg('capabilities')}`);
    // A HELLO is how peers learn an address, so emitting one this same tool
    // would reject publishes an identity nobody can route back to.
    const text = lines.join('\n');
    const result = validate(text);
    for (const w of result.warnings) console.error(`warning: ${w}`);
    if (!result.ok) { console.error(result.errors.join('\n')); process.exit(1); }
    console.log(text);
  } else if (cmd === 'normalize') {
    const file = process.argv[3];
    if (!file) throw new Error('usage: gzmsg.mjs normalize <file>');
    // Prints the normalised message; validate the output, not the paste.
    process.stdout.write(normalize(fs.readFileSync(file, 'utf8')));
  } else if (cmd === 'next-id') {
    const instance = arg('instance');
    if (!instance) throw new Error('next-id requires --instance');
    console.log(nextId(instance, arg('state-dir') ?? '.gzcoord'));
  } else {
    console.error('usage: gzmsg.mjs validate <file> | normalize <file> | hello --from ... --role ... --project ... [--message-id ...] | next-id --instance <instance> [--state-dir <dir>]');
    process.exit(2);
  }
}
