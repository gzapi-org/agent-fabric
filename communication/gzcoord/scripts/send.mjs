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
  const dry = argv.includes('--dry-run');
  const file = argv.find(a => !a.startsWith('--'));
  if (!file) { console.error('usage: send.mjs <file>|- [--dry-run]'); return 1; }
  let raw;
  try { raw = file === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(file, 'utf8'); }
  catch (e) { console.error(`send: cannot read ${file}: ${e.message}`); return 1; }
  const text = normalize(raw);

  const who = whoami();
  const root = inboxRoot(who);
  const cfg = integrationConfig(who.project);
  if (!cfg.configured) { console.error(`send: ${cfg.reason} — not sent`); return 3; }
  try { assertNotControlChannel(cfg.channel); } catch (e) { console.error(`send: ${e.message} — not sent`); return 2; }
  const relayUrl = cfg.relay_url;
  const channel = cfg.channel;
  const taxPath = findTaxonomy(root);
  const taxonomy = taxPath ? loadTaxonomy(taxPath) : undefined;
  const me = identity(who, taxonomy);

  // Validate as the last step before sending; the validator's own words go
  // to stderr. The line-width check is off: the bridge carries a line as
  // written, and a warning nobody can act on (a path, an id) is noise.
  const result = validate(text, { taxonomy, maxColumns: 0 });
  for (const w of result.warnings ?? []) console.error(`send: warning: ${w}`);
  if (!result.ok) { for (const e of result.errors ?? []) console.error(`send: ${e}`); console.error('send: not sent — the message does not validate'); return 2; }
  const msg = parse(text);
  const from = msg.metadata?.FROM;
  if (from !== me.address) {
    console.error(`send: FROM is ${from ?? '(missing)'} but this session is ${me.address}; not sent — the sender is the login, never a claim`);
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
    const c = msg.metadata?.[key] ? idComplaint(key, msg.metadata[key]) : null;
    if (c) { console.error(`send: ${c}; not sent`); return 2; }
  }
  // This session's model fell back after a safeguard flagged a request
  // (runtime/claude-code/hooks/model-fallback-note.sh leaves the marker):
  // the flagged text is contagious, so the reminder is repeated here, at
  // the moment of sending. A reminder, never a content check — nothing
  // can tell flagged text from any other.
  const fb = fallbackMarker();
  if (fb) console.error(`send: reminder — this session fell back from ${fb.from_model || 'its model'} to ${fb.to_model || 'a fallback model'} at ${fb.at || '?'} after a safeguard flagged a request as ${fb.topic || 'the flagged category'}; filter anything that could be read as ${fb.topic || 'that'} out of this message — name where a finding is and what class of problem it is, never its content.`);
  if (dry) { console.error(`send: would post ${msg.type} ${id} from ${me.address} to ${channel} at ${relayUrl}`); return 0; }

  let tok = token(root, cfg);
  if (!tok) { console.error('send: no CLAUDE_BRIDGE_AUTH_TOKEN in the environment or the working copy — not sent'); return 3; }
  let res;
  const post = t => api(t, '/api/send', { method: 'POST', body: JSON.stringify({ channel, sender: me.address, content: text }), relayUrl });
  try {
    try { res = await post(tok); }
    catch (e) {
      // A shell snapshot keeps a rotated token; the synced file has the current one.
      const fresh = (e.status === 401 || e.status === 403) ? syncedToken() : undefined;
      if (!(fresh && fresh !== tok)) throw e;
      tok = fresh; res = await post(tok);
    }
  } catch (e) {
    if (e.status === 401 || e.status === 403) { console.error(`send: the relay refused this token (HTTP ${e.status}) — it was rotated; run bin/fabric-secrets sync — not sent`); return 3; }
    console.error(`send: relay unreachable at ${relayUrl} (${e.message}) — not sent`); return 3;
  }
  console.log(`sent seq ${res.seq} ${msg.type} ${id}${res.deduplicated ? ' (deduplicated: the relay already had it)' : ''}`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  main().then(code => process.exit(code), e => { console.error(`send: ${e.message}`); process.exit(1); });
