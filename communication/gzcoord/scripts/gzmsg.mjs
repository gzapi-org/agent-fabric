#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// The agent-fabric checkout this runtime belongs to: communication/gzcoord/scripts -> root.
export const FABRIC_ROOT = process.env.AGENT_FABRIC_ROOT ?? new URL('../../../', import.meta.url).pathname.replace(/\/$/, '');

const CORE_TYPES = new Set(['HELLO','GOODBYE','INFO','OBSERVATION','QUESTION','REQUEST','REVIEW','DECISION','HANDOFF','REPLY']);
const FORBIDDEN = new Set([
  'MODEL','PROVIDER','WORKING-DIRECTORY','WORKING_DIRECTORY',
  'TOKEN-BUDGET','TOKEN_BUDGET','REASONING-BUDGET','REASONING_BUDGET',
  'SUBAGENT-DEPTH','SUBAGENT-LIMIT','SUBAGENT_LIMIT',
  'TELEGRAM-BOT','TELEGRAM_BOT','TELEGRAM-BOT-USERNAME','TELEGRAM-CHAT-ID',
  'BOT-TOKEN','BOT_TOKEN','SLACK-CHANNEL-ID','DISCORD-GUILD-ID',
]);
const addressRe = /^[a-z0-9._-]+\/[a-z0-9._-]+$/;

// Every common metadata field the spec names (§7). Used only to ask
// whether an unknown key looks like a misspelling of one — never to
// reject: §6 requires unknown metadata to be preserved, because that is
// how the protocol extends.
const KNOWN_KEYS = ['FROM','ROLE','PROJECT','TO','TO-ROLE','BROADCAST','MESSAGE-ID','IN-REPLY-TO',
  'REPOSITORY','BRANCH','COMMIT','REPLY-EXPECTED','SUBJECT','SPECIALTIES','CAPABILITIES'];
// An id-shaped value: a UUID (the deployment mints UUIDv7), or the retired
// `<instance>-NNNN` counter form still seen in older traffic.
const ID_SHAPED = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[a-z0-9._-]+-\d{4})$/;
function editDistance(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      d[i][j] = Math.min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (a[i-1] === b[j-1] ? 0 : 1));
  return d[a.length][b.length];
}
// A known field this unknown key was plausibly meant to be: either the
// key is a whole hyphen-separated run inside it (ID inside MESSAGE-ID,
// IN-REPLY inside IN-REPLY-TO) or it is within two edits of it.
export function nearestKnownKey(key) {
  if (KNOWN_KEYS.includes(key)) return undefined;
  const parts = k => k.split('-');
  for (const known of KNOWN_KEYS) {
    const kp = parts(key), np = parts(known);
    for (let i = 0; i + kp.length <= np.length; i++)
      if (kp.every((t, j) => t === np[i + j]) && kp.length < np.length) return known;
  }
  return KNOWN_KEYS.find(known => editDistance(key, known) <= 2);
}

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

// WHO AM I. The agent is the Linux login of the effective user, and the
// one place that derivation lives is runtime/identity.py — this asks it
// (`--json` also carries the role, project and working copy bound to the
// agent). If python is unavailable the fallback computes the same thing
// (effective uid -> login) and reads the same binding file by the same
// path rule; it never looks at the working directory's name.
function bindingFile(agent) {
  const base = process.env.AGENT_FABRIC_STATE_DIR
    ?? path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), '.local', 'state'), 'agent-fabric');
  return path.join(base, 'agents', agent, 'binding.json');
}
export function whoami() {
  const script = path.join(FABRIC_ROOT, 'runtime', 'identity.py');
  const r = spawnSync('python3', [script, '--json'], { encoding: 'utf8' });
  if (r.status === 0) { try { const me = JSON.parse(r.stdout); me.binding = bindingFile(me.agent); return me; } catch { /* fall through */ } }
  const agent = os.userInfo().username;
  let binding = {};
  try { binding = JSON.parse(fs.readFileSync(bindingFile(agent), 'utf8')); } catch { /* none written */ }
  return { agent, host: os.hostname().split('.')[0], role: binding.role, project: binding.project,
           working_copy: binding.working_copy, binding: bindingFile(agent), fallback: true };
}

// A deployment's role catalogue (SPEC §4: the core protocol keeps no
// enum; a deployment MAY publish one — agent-fabric's is
// identities/roles/catalog.json).
// Given one, the validator holds ROLE and TO-ROLE to its slugs — the `id`,
// `backend-dev`, one token with no spaces or slashes, matched by equality
// and safe in a metadata line and a filter. Live traffic announced one
// role three ways in a day. The catalogue is the only source a RECEIVING
// validator can consult: it is committed and identical in every clone,
// where a sender's active-role record is gitignored on the sender's disk.
// Nothing ties ROLE to the address: SPEC §4 says an instance MAY change
// its role without changing its address, a legacy clone directory (legacy-clone-2,
// holding backend-dev) carries no slug in its name at all, and a recipient
// tests TO against its own address by equality, so a slug in an instance
// name buys the protocol nothing. Where the name does carry one that
// disagrees with ROLE, a warning says so — a rename would be tidy.
// The parameter is `file`, not `path`: `path` is the node:path module
// here, and shadowing it turns a later path.join() in this function into
// a runtime error rather than a compile one.
export function loadTaxonomy(file) {
  const t = JSON.parse(fs.readFileSync(file, 'utf8'));
  const roles = new Map();   // slug (the catalogue id, what goes on the wire) → title (for reading)
  for (const r of t.roles ?? []) if (r.id && r.title) roles.set(r.id, r.title);
  if (roles.size === 0) throw new Error(`${file} holds no roles with id and title`);
  return { path: file, roles };
}
// The AGENT's active-role record: the runtime binding written by
// tools/fabric/role.py in the agent's state directory (never inside a
// working copy). Four outcomes, kept distinct because a record that fails
// to name a usable role must never pass as "no record" and fall through to
// a guess from the address: no binding at all, or one with no role; a
// binding naming a catalogue role; a binding present but unreadable, which
// warns and leaves the caller to decide; and a binding naming a role the
// catalogue does not have, which is an error, since the agent asserts a
// role the deployment does not know. The warning states the cause only:
// what happens next is the caller's, and it may not be the address.
export function recordedRole(taxonomy, me = whoami()) {
  if (!taxonomy?.path) return { role: undefined };
  const file = me.binding ?? bindingFile(me.agent);
  if (me.role === undefined || me.role === null) {
    if (!fs.existsSync(file)) return { role: undefined };
    try { JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (e) { return { role: undefined, warning: `${file} could not be read (${e.message})` }; }
    return { role: undefined, warning: `${file} records no role` };
  }
  if (!taxonomy.roles.has(me.role)) return { role: undefined, error: `${file} records role "${me.role}", which is not in ${taxonomy.path}; pass --role explicitly` };
  return { role: me.role, file };
}
// The catalogue: agent-fabric's identities/roles/catalog.json.
export function findTaxonomy(_from = process.cwd()) {
  const fabric = path.join(FABRIC_ROOT, 'identities', 'roles', 'catalog.json');
  return fs.existsSync(fabric) ? fabric : undefined;
}
// The slug an instance name carries, as a whole run of hyphen-separated
// tokens. Under the login model the instance IS the login, and provisioned
// accounts are named for the role they were stood up as (`architect-cto-01`,
// `backend-dev-02`) while a generic account (`user`) names none. A
// convenience for a default ROLE in `hello` and a disagreement warning —
// never a source of identity, never a reason to reject.
export function slugOf(instance, taxonomy) {
  const tokens = instance.split('-');
  let best;
  for (const slug of taxonomy.roles.keys()) {
    const st = slug.split('-');
    for (let i = 0; i + st.length <= tokens.length; i++)
      if (st.every((s, j) => tokens[i + j] === s) && (!best || slug.length > best.length)) best = slug;
  }
  return best;
}

export function validate(text, { taxonomy } = {}) {
  const errors = [];
  const warnings = [];
  let msg;
  // parse() throws on a bad header because nothing after it can be read;
  // validate() reports that like any other error, so the CLI prints one
  // line instead of a stack trace and callers see a uniform result shape.
  try { msg = parse(text); }
  catch (e) { return { ok: false, errors: [e.message], warnings, message: null }; }
  if (!CORE_TYPES.has(msg.type) && !msg.type.startsWith('X-')) errors.push(`unknown type: ${msg.type}`);
  // MESSAGE-ID joined the required set (§7.1) once a real transport made
  // its absence expensive: without one a message cannot be deduplicated by
  // an at-least-once carrier, answered by IN-REPLY-TO, or named in a
  // reconciliation by either side. Unnumbered messages were sent here and
  // had to be superseded. Uniqueness stays a SENDER obligation — a
  // validator sees one message and cannot know a sender's history.
  for (const key of ['FROM','ROLE','PROJECT','MESSAGE-ID']) if (!msg.metadata[key]) errors.push(`missing ${key}`);
  if (msg.metadata.FROM && !addressRe.test(msg.metadata.FROM)) errors.push('FROM must be <host>/<instance>');
  if (msg.metadata.TO && !addressRe.test(msg.metadata.TO)) errors.push('TO must be <host>/<instance>');
  if (msg.metadata['REPLY-EXPECTED'] !== undefined && !['yes','no'].includes(msg.metadata['REPLY-EXPECTED'])) errors.push('REPLY-EXPECTED must be yes or no');
  // SPEC §7.1: the field's only value is `true`. `BROADCAST: yes` used to fail
  // as "missing TO, TO-ROLE or BROADCAST: true", which names the wrong fault,
  // and `BROADCAST: false` beside a TO validated clean with undefined meaning.
  if (msg.metadata.BROADCAST !== undefined && msg.metadata.BROADCAST !== 'true') errors.push('BROADCAST must be true, or absent');
  // SPEC §7.1: the addressing field is the delivery scope, and there is
  // exactly one — a second answers "who receives" twice, and a transport
  // filtering by addressee cannot obey both. Live traffic carried TO beside
  // an unmatched TO-ROLE and nothing noticed. HELLO and GOODBYE are
  // broadcasts by definition and carry none.
  const addressing = ['TO', 'TO-ROLE', 'BROADCAST'].filter(k => msg.metadata[k] !== undefined);
  if (['HELLO','GOODBYE'].includes(msg.type)) {
    if (addressing.length) errors.push(`${msg.type} is a broadcast by definition and carries no ${addressing.join(', ')}`);
  } else if (addressing.length === 0) errors.push('missing TO, TO-ROLE or BROADCAST: true');
  else if (addressing.length > 1) errors.push(`${addressing.join(' and ')} are exclusive: one addressing field, the delivery scope`);
  for (const key of Object.keys(msg.metadata)) if (FORBIDDEN.has(key)) errors.push(`${key} is local/runtime data and forbidden on the wire`);
  if (taxonomy) {
    const catalogue = taxonomy.path ?? 'the role catalogue';
    if (msg.metadata.ROLE && !taxonomy.roles.has(msg.metadata.ROLE))
      errors.push(`ROLE "${msg.metadata.ROLE}" is not a role slug in ${catalogue}`);
    if (msg.metadata['TO-ROLE'] && !taxonomy.roles.has(msg.metadata['TO-ROLE']))
      errors.push(`TO-ROLE "${msg.metadata['TO-ROLE']}" is not a role slug in ${catalogue}`);
    const fromSlug = msg.metadata.FROM && addressRe.test(msg.metadata.FROM) && slugOf(msg.metadata.FROM.split('/')[1], taxonomy);
    if (fromSlug && msg.metadata.ROLE && taxonomy.roles.has(msg.metadata.ROLE) && msg.metadata.ROLE !== fromSlug)
      warnings.push(`FROM names ${fromSlug} but ROLE is ${msg.metadata.ROLE}; the role may have changed since the clone was named`);
  }
  for (const line of msg.malformed) errors.push(`unparsable line in the metadata block: ${line}`);
  for (const key of msg.duplicateKeys) errors.push(`${key} appears more than once in the metadata block`);
  // A key the sender believed was a known field. Two signals, neither of
  // which rejects: it reads as a misspelling of a common field, or it
  // carries an id-shaped value while not being an id field at all.
  for (const [key, value] of Object.entries(msg.metadata)) {
    const near = nearestKnownKey(key);
    if (near) warnings.push(`${key} is not a known field — did you mean ${near}?`);
    else if (ID_SHAPED.test(value) && !['MESSAGE-ID','IN-REPLY-TO'].includes(key))
      warnings.push(`${key} carries an id-shaped value (${value}) but is not MESSAGE-ID or IN-REPLY-TO`);
  }
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
// MESSAGE-ID minting: UUIDv7 (RFC 9562) — 48-bit millisecond timestamp,
// version 7, RFC variant. Time-ordered, unique without any coordination,
// no shared counter state. The sequential <instance>-NNNN counter this
// replaces existed for loss visibility on the lossy human relay; the
// durable carrier has no gap to detect, and the counter was the
// subsystem's largest defect source (restart-reuse, seeding, a number
// burned by peeking, a hand-written collision — five incidents). SPEC
// §7.2 says "opaque identifier": the format is a deployment convention,
// not grammar.
export function mintId() {
  // Native when the runtime has it (Node >= 22.13); hand-rolled otherwise.
  try {
    const u = crypto.randomUUID({ version: 'v7' });
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab]/.test(u)) return u;
  } catch { /* fall through to the hand-rolled form */ }
  const ms = Date.now();
  const b = crypto.randomBytes(16);
  b[0] = (ms / 2 ** 40) & 0xff; b[1] = (ms / 2 ** 32) & 0xff;
  b[2] = (ms >> 24) & 0xff; b[3] = (ms >> 16) & 0xff; b[4] = (ms >> 8) & 0xff; b[5] = ms & 0xff;
  b[6] = (b[6] & 0x0f) | 0x70;                       // version 7
  b[8] = (b[8] & 0x3f) | 0x80;                       // RFC variant
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// Every flag a command accepts, declared, so an unrecognised one is an
// error BEFORE any side effect rather than a silent no-op. A checkout that
// predated --peek once accepted `next-id --peek` (the retired counter
// command) in silence and took a number — a gap in a sequence that
// nothing could fill — and a typo like --seeed does the same today. On a
// state-mutating command, silence is the defect.
const FLAGS = {
  validate:  { valued: ['taxonomy'], boolean: ['no-taxonomy'], positional: 1 },
  normalize: { valued: [], boolean: [], positional: 1 },
  hello:     { valued: ['from', 'role', 'project', 'message-id', 'specialties', 'capabilities', 'state-dir', 'taxonomy'], boolean: ['no-taxonomy'], positional: 0 },
  'new-id':  { valued: [], boolean: [], positional: 0 },
};
export function parseArgs(argv, spec) {
  const flags = {}; const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { positional.push(a); continue; }
    const name = a.slice(2);
    if (spec.boolean.includes(name)) { flags[name] = true; continue; }
    if (spec.valued.includes(name)) {
      const v = argv[i + 1];
      if (v === undefined || v.startsWith('--')) throw new Error(`--${name} needs a value`);
      if (name in flags) throw new Error(`--${name} given twice`);
      flags[name] = v; i++; continue;
    }
    const known = [...spec.valued, ...spec.boolean].map(f => `--${f}`).join(', ');
    throw new Error(`unknown flag ${a}; this command takes ${known || 'no flags'}`);
  }
  if (positional.length > spec.positional) throw new Error(`unexpected argument: ${positional[spec.positional]}`);
  return { flags, positional };
}
let ARGS = { flags: {}, positional: [] };
function arg(name) { return ARGS.flags[name]; }

if (import.meta.url === `file://${process.argv[1]}`) {
  const cmd = process.argv[2];
  if (cmd in FLAGS) {
    try { ARGS = parseArgs(process.argv.slice(3), FLAGS[cmd]); }
    catch (e) { console.error(`gzmsg ${cmd}: ${e.message}`); process.exit(2); }
  }
  // The deployment's catalogue is found by walking up from the working
  // directory; --taxonomy names one explicitly, --no-taxonomy validates
  // the wire grammar alone.
  const taxonomyPath = ARGS.flags['no-taxonomy'] ? undefined : (arg('taxonomy') ?? findTaxonomy());
  const taxonomy = taxonomyPath ? loadTaxonomy(taxonomyPath) : undefined;
  if (cmd === 'validate') {
    const file = ARGS.positional[0];
    if (!file) throw new Error('usage: gzmsg.mjs validate <file>');
    const result = validate(fs.readFileSync(file, 'utf8'), { taxonomy });
    // Warnings print on both paths: on a failure they are often the cause
    // the errors only describe from downstream.
    for (const w of result.warnings) console.error(`warning: ${w}`);
    if (!result.ok) { console.error(result.errors.join('\n')); process.exit(1); }
    console.log('valid GZCOORD/1 message');
  } else if (cmd === 'hello') {
    // FROM defaults to this agent's address: <host>/<login>, from the one
    // canonical resolver. PROJECT defaults to the project bound to the
    // agent (from the working copy it activated in), when known.
    const me = whoami();
    const from = arg('from') ?? `${me.host}/${me.agent}`;
    const project = arg('project') ?? me.project ?? undefined;
    // With a catalogue the role can be derived: first from the agent's
    // runtime binding (written by tools/fabric/role.py), then from the slug
    // the address carries. The binding is authoritative where it exists;
    // the address is a last resort, since an account is named once and a
    // role can change. A binding the catalogue does not know is an error,
    // never a silent fallback.
    const recorded = recordedRole(taxonomy, me);
    if (recorded.error && !arg('role')) { console.error(recorded.error); process.exit(1); }
    const derived = taxonomy && (recorded.role || (from && addressRe.test(from) && slugOf(from.split('/')[1], taxonomy)));
    const role = arg('role') ?? derived;
    // The consequence is named by whoever took it, not by recordedRole:
    // an explicit --role may have won, or nothing may have been derived
    // at all, and the warning used to claim the address either way.
    if (recorded.warning)
      console.error(`warning: ${recorded.warning}; ` + (arg('role') ? `using --role ${arg('role')}` : derived ? `deriving ${derived} from the address instead` : 'and the address names no role either'));
    if (arg('role') && recorded.role && arg('role') !== recorded.role)
      console.error(`warning: --role ${arg('role')} disagrees with ${recorded.file}, which records ${recorded.role}`);
    if (!from || !role || !project) throw new Error('hello requires --project unless the agent is bound to one, and --role unless the agent binding records a role or the address names one');
    // MESSAGE-ID is required (§7.1), so hello mints one rather than
    // emitting a message its own validate would reject. A minted id is
    // unique by construction — no counter, no seed, nothing to collide.
    const id = arg('message-id') ?? mintId();
    const lines = [`[GZCOORD/1] HELLO`,`FROM: ${from}`,`ROLE: ${role}`,`PROJECT: ${project}`];
    if (id) lines.push(`MESSAGE-ID: ${id}`);
    if (arg('specialties')) lines.push(`SPECIALTIES: ${arg('specialties')}`);
    if (arg('capabilities')) lines.push(`CAPABILITIES: ${arg('capabilities')}`);
    // A HELLO is how peers learn an address, so emitting one this same tool
    // would reject publishes an identity nobody can route back to.
    const text = lines.join('\n');
    const result = validate(text, { taxonomy });
    for (const w of result.warnings) console.error(`warning: ${w}`);
    if (!result.ok) { console.error(result.errors.join('\n')); process.exit(1); }
    console.log(text);
  } else if (cmd === 'normalize') {
    const file = ARGS.positional[0];
    if (!file) throw new Error('usage: gzmsg.mjs normalize <file>');
    // Prints the normalised message; validate the output, not the paste.
    process.stdout.write(normalize(fs.readFileSync(file, 'utf8')));
  } else if (cmd === 'new-id') {
    // A fresh UUIDv7: unique by construction, no counter, nothing to
    // peek or seed. (`next-id`, the counter-era name, was kept as an
    // alias until 2026-09-16 and is now an unknown command.)
    console.log(mintId());
  } else {
    console.error('usage: gzmsg.mjs validate <file> | normalize <file> | hello --from ... --project ... [--role ...] [--message-id ...] | new-id   (--taxonomy <path> | --no-taxonomy)');
    process.exit(2);
  }
}
