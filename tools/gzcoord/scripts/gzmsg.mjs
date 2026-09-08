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

// Terminal columns a line occupies, approximated without a wcwidth table:
// CJK scripts and pictographs are 2, combining and format characters 0, a
// tab advances to the next multiple of 8, everything else 1. Reproduces
// `wc -L` on the probes in the test; known to count narrow the wide
// punctuation and fullwidth forms that are Script=Common (U+3001, U+FF21,
// U+3000), and to count East Asian Ambiguous characters (§, —) as 1, which
// only the reader's locale can decide.
const WIDE = /\p{Script=Han}|\p{Script=Hiragana}|\p{Script=Katakana}|\p{Script=Hangul}|\p{Extended_Pictographic}/u;
const ZERO = /\p{Mn}|\p{Me}|\p{Cf}/u;
export function columns(line) {
  let w = 0;
  for (const ch of line) {
    if (ch === '\t') { w += 8 - (w % 8); continue; }
    if (ZERO.test(ch)) continue;
    w += WIDE.test(ch) ? 2 : 1;
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
  } else {
    console.error('usage: gzmsg.mjs validate <file> | hello --from ... --role ... --project ... [--message-id ...]');
    process.exit(2);
  }
}
