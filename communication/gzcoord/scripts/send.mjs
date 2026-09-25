#!/usr/bin/env node
// communication/gzcoord/scripts/send.mjs — send ONE message over the relay.
//
//   node communication/gzcoord/scripts/send.mjs <file>        the message, as written
//   node communication/gzcoord/scripts/send.mjs -            …from stdin
//   node communication/gzcoord/scripts/send.mjs <file> --dry-run   validate, resolve, send nothing
//
// The other half of inbox.mjs, resolved the same way: who this session is
// (runtime/identity.py — the login, never a directory), which project's
// integration (relay, channel), and where the token lives (the
// environment, populated by fabric-secrets sync; else the working copy's
// files; else, for the relay host, the runtime dir). A message is
// normalized (a pasted body carries terminal indentation), validated as
// the last step before it leaves (SPEC §1) — a message that fails is not
// sent — and refused when its FROM is not this session's own address:
// the sender is the login, and a message claiming another one would be
// misattributed on every recipient's cursor. Prints the relay's sequence
// number and the MESSAGE-ID; nothing else goes to stdout.
//
// Exit codes: 0 sent; 1 usage or unreadable input; 2 invalid message or
// FROM is not this session; 3 no token or relay unreachable.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse, validate, normalize, loadTaxonomy, findTaxonomy, whoami, idComplaint } from './gzmsg.mjs';
import { identity, inboxRoot, integrationConfig, token, api, syncedToken, assertNotControlChannel } from './inbox.mjs';
import { dictionary, printer } from './i18n.mjs';
import { checkAddressees, PRESENCE_WAIT_MS } from '../../../runtime/control/presence.mjs';
import { accountAddresses } from '../../../runtime/control/agentd.mjs';

// The fallback marker for this harness session (CLAUDE_PID), if any, from
// the login's own directory; a marker naming a dead pid is not one.
export function fallbackMarker(dir = process.env.AGENT_FABRIC_FALLBACK_DIR ?? path.join(os.homedir(), '.cache', 'agent-fabric', 'fallback'), pid = Number(process.env.CLAUDE_PID) || 0) {
  const candidates = [];
  try {
    if (pid > 0 && fs.existsSync(path.join(dir, `${pid}.json`))) candidates.push(path.join(dir, `${pid}.json`));
    else for (const n of fs.readdirSync(dir)) if (/^\d+\.json$/.test(n)) candidates.push(path.join(dir, n));
  } catch { return null; }
  for (const f of candidates) {
    try {
      if (fs.lstatSync(f).uid !== process.getuid()) continue;
      const m = JSON.parse(fs.readFileSync(f, 'utf8'));
      if (!Number.isInteger(m.pid) || m.pid <= 0) continue;
      try { process.kill(m.pid, 0); } catch { continue; }
      return m;
    } catch { /* unreadable: not a marker */ }
  }
  return null;
}

export async function main(argv = process.argv.slice(2)) {
  // The login first, before anything is printed: every line this function
  // writes is then the reader's, the usage line included — which is the
  // call inbox.mjs made for its own usage line, and the two tools should
  // not disagree about whose language a usage line is in (re-review N1).
  const who = whoami();
  const t = printer(dictionary(who));
  const dry = argv.includes('--dry-run');
  const force = argv.includes('--force');
  const file = argv.find(a => !a.startsWith('--'));
  if (!file) { console.error(t('send.usage')); return 1; }
  let raw;
  try { raw = file === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(file, 'utf8'); }
  catch (e) { console.error(t('send.cannot-read', { file, detail: e.message })); return 1; }
  const text = normalize(raw);

  const root = inboxRoot(who);
  const cfg = integrationConfig(who.project, process.env, t);
  if (!cfg.configured) { console.error(t('send.not-configured', { reason: cfg.reason })); return 3; }
  try { assertNotControlChannel(cfg.channel, t); } catch (e) { console.error(t('send.error-not-sent', { detail: e.message })); return 2; }
  const relayUrl = cfg.relay_url;
  const channel = cfg.channel;
  const taxPath = findTaxonomy(root);
  const taxonomy = taxPath ? loadTaxonomy(taxPath) : undefined;
  const me = identity(who, taxonomy);

  // Validate as the last step before sending; the validator's own words go
  // to stderr. The line-width check is off: the bridge carries a line as
  // written, and a warning nobody can act on (a path, an id) is noise.
  // A refusal the sender reads is that sender's line, in that sender's
  // language: validate() is one function and its diagnostics are the
  // fabric's own text wherever they are printed.
  const result = validate(text, { taxonomy, maxColumns: 0, t });
  // An id complaint is repeated below as the refusal; once is enough. The
  // duplicate is found by IDENTITY, not by matching the English the
  // complaint used to start with: once the complaint is a dictionary line
  // it begins with whatever the locale begins with, and a text match
  // silently stopped suppressing anything (blind review F2 on PR #28).
  const alsoRefused = new Set(['MESSAGE-ID', 'IN-REPLY-TO']
    .map(k => result.message?.metadata?.[k] ? idComplaint(k, result.message.metadata[k], t) : null)
    .filter(Boolean));
  for (const w of result.warnings ?? []) if (!alsoRefused.has(w)) console.error(t('send.warning', { detail: w }));
  if (!result.ok) { for (const e of result.errors ?? []) console.error(t('send.error', { detail: e })); console.error(t('send.does-not-validate')); return 2; }
  const msg = parse(text);
  const from = msg.metadata?.FROM;
  if (from !== me.address) {
    console.error(t('send.from-is-not-this-login', { from: from ?? t('send.from-missing'), address: me.address }));
    return 2;
  }
  const id = msg.metadata?.['MESSAGE-ID'] ?? '(none)';
  // The deployment mints UUIDv7 ids (gzmsg.mjs new-id) and every join —
  // IN-REPLY-TO, a REPLY claiming an assignment, a finding traced by id —
  // resolves on them. The validator can only warn (the grammar keeps the
  // id opaque); the sender is where the deployment's convention is a
  // rule, because a malformed id degrades quietly: the message reads
  // fine and the thread cannot be reconstructed later.
  for (const key of ['MESSAGE-ID', 'IN-REPLY-TO']) {
    const c = msg.metadata?.[key] ? idComplaint(key, msg.metadata[key], t) : null;
    if (c) { console.error(t('send.id-refused', { detail: c })); return 2; }
  }
  // This session's model fell back after a safeguard flagged a request
  // (runtime/claude-code/hooks/model-fallback-note.sh leaves the marker):
  // the flagged text is contagious, so the reminder is repeated here, at
  // the moment of sending. A reminder, never a content check — nothing
  // can tell flagged text from any other.
  const fb = fallbackMarker();
  if (fb) console.error(t('send.fallback-reminder', {
    from_model: fb.from_model || t('send.fallback-unknown-model'),
    to_model: fb.to_model || t('send.fallback-unknown-target'),
    at: fb.at || t('send.fallback-unknown-time'),
    topic: fb.topic || t('send.fallback-unknown-topic'),
    topic_again: fb.topic || t('send.fallback-unknown-topic-again') }));
  let tok = token(root, cfg);
  // Is anyone there? A message to a login with no session waits in the
  // relay until one starts, and a TO-ROLE with no running holder reaches
  // nobody now. The control plane answers from the process table
  // (runtime/control/presence.mjs); the sender decides — --force sends
  // anyway (the owner, 2026-09-25). A broadcast is not checked.
  if (tok) {
    let pres;
    try { pres = await checkAddressees(msg.metadata ?? {}, { from: me.address, token: tok, placed: [...accountAddresses()] }); }
    catch (e) { pres = { checked: true, problems: [{ kind: 'unavailable', detail: String(e?.message ?? e).split('\n')[0].slice(0, 160) }] }; }
    for (const p of pres.problems ?? []) {
      if (p.kind === 'offline') console.error(t('send.presence-offline', { address: p.address }));
      else if (p.kind === 'silent') console.error(t('send.presence-silent', { address: p.address, seconds: PRESENCE_WAIT_MS / 1000 }));
      else if (p.kind === 'not-placed') console.error(t('send.presence-not-placed', { address: p.address }));
      else if (p.kind === 'no-holder') {
        console.error(p.holders.length ? t('send.presence-no-holder', { role: p.role, holders: p.holders.join(', ') }) : t('send.presence-no-account', { role: p.role }));
        if (p.silent.length) console.error(t('send.presence-some-silent', { addresses: p.silent.join(', ') }));
      } else console.error(t('send.presence-unavailable', { detail: p.detail }));
    }
    if (pres.problems?.length) {
      if (!force) { console.error(t('send.presence-not-sent')); return 4; }
      console.error(t('send.presence-forced'));
    }
  }
  if (dry) { console.error(t('send.would-post', { type: msg.type, id, address: me.address, channel, relay_url: relayUrl })); return 0; }
  if (!tok) { console.error(t('send.no-token')); return 3; }
  let res;
  const post = authToken => api(authToken, '/api/send', { method: 'POST', body: JSON.stringify({ channel, sender: me.address, content: text }), relayUrl });
  try {
    try { res = await post(tok); }
    catch (e) {
      // A shell snapshot keeps a rotated token; the synced file has the current one.
      const fresh = (e.status === 401 || e.status === 403) ? syncedToken() : undefined;
      if (!(fresh && fresh !== tok)) throw e;
      tok = fresh; res = await post(tok);
    }
  } catch (e) {
    if (e.status === 401 || e.status === 403) { console.error(t('send.token-refused', { status: e.status })); return 3; }
    console.error(t('send.relay-unreachable', { relay_url: relayUrl, detail: e.message })); return 3;
  }
  console.log(t('send.sent', { seq: res.seq, type: msg.type, id, deduplicated: res.deduplicated ? t('send.deduplicated') : '' }));
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  // NOT through the dictionary: what failed may BE the dictionary, and a
  // throw inside this handler is an unhandled rejection (blind review F1).
  main().then(code => process.exit(code), e => { console.error(`send: ${e?.message ?? e}`); process.exit(1); });
