#!/usr/bin/env node
import fs from 'node:fs';

const CORE_TYPES = new Set(['HELLO','GOODBYE','INFO','OBSERVATION','QUESTION','REQUEST','REVIEW','DECISION','HANDOFF','REPLY']);
const FORBIDDEN = new Set(['MODEL','PROVIDER','WORKING-DIRECTORY','WORKING_DIRECTORY','TELEGRAM-BOT','TELEGRAM_BOT','BOT-TOKEN','BOT_TOKEN','SUBAGENT-LIMIT','SUBAGENT_LIMIT']);
const addressRe = /^[a-z0-9._-]+\/[a-z0-9._-]+$/;

export function parse(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const first = lines.shift() ?? '';
  const m = first.match(/^\[GZCOORD\/1\] ([A-Z][A-Z0-9-]*)$/);
  if (!m) throw new Error('invalid GZCOORD/1 first line');
  const type = m[1];
  const metadata = {};
  const sections = {};
  let currentSection = null;
  let inSections = false;
  for (const line of lines) {
    if (/^[A-Z][A-Z0-9-]*:$/.test(line)) {
      inSections = true;
      currentSection = line.slice(0, -1);
      sections[currentSection] = '';
      continue;
    }
    if (!inSections && /^[A-Z][A-Z0-9-]*: /.test(line)) {
      const idx = line.indexOf(':');
      metadata[line.slice(0, idx)] = line.slice(idx + 1).trim();
      continue;
    }
    if (currentSection) sections[currentSection] += `${sections[currentSection] ? '\n' : ''}${line}`;
  }
  return { type, metadata, sections };
}

export function validate(text) {
  const msg = parse(text);
  const errors = [];
  if (!CORE_TYPES.has(msg.type) && !msg.type.startsWith('X-')) errors.push(`unknown type: ${msg.type}`);
  for (const key of ['FROM','ROLE','PROJECT']) if (!msg.metadata[key]) errors.push(`missing ${key}`);
  if (msg.metadata.FROM && !addressRe.test(msg.metadata.FROM)) errors.push('FROM must be <host>/<instance>');
  if (!['HELLO','GOODBYE'].includes(msg.type)) {
    if (!msg.metadata.TO && !msg.metadata['TO-ROLE'] && msg.metadata.BROADCAST !== 'true') errors.push('missing TO, TO-ROLE or BROADCAST: true');
  }
  for (const key of Object.keys(msg.metadata)) if (FORBIDDEN.has(key)) errors.push(`${key} is local/runtime data and forbidden on the wire`);
  return { ok: errors.length === 0, errors, message: msg };
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
    if (!result.ok) { console.error(result.errors.join('\n')); process.exit(1); }
    console.log('valid GZCOORD/1 message');
  } else if (cmd === 'hello') {
    const from = arg('from'), role = arg('role'), project = arg('project');
    if (!from || !role || !project) throw new Error('hello requires --from --role --project');
    const lines = [`[GZCOORD/1] HELLO`,`FROM: ${from}`,`ROLE: ${role}`,`PROJECT: ${project}`];
    if (arg('specialties')) lines.push(`SPECIALTIES: ${arg('specialties')}`);
    if (arg('capabilities')) lines.push(`CAPABILITIES: ${arg('capabilities')}`);
    console.log(lines.join('\n'));
  } else {
    console.error('usage: gzmsg.mjs validate <file> | hello --from ... --role ... --project ...');
    process.exit(2);
  }
}
