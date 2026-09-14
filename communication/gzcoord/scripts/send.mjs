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
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse, validate, normalize, loadTaxonomy, findTaxonomy, whoami } from './gzmsg.mjs';
import { identity, inboxRoot, integrationConfig, token, api } from './inbox.mjs';

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
  const relayUrl = process.env.CLAUDE_BRIDGE_URL ?? cfg.relay_url;
  const channel = process.env.GZCOORD_CHANNEL ?? cfg.channel;
  const taxPath = findTaxonomy(root);
  const taxonomy = taxPath ? loadTaxonomy(taxPath) : undefined;
  const me = identity(who, taxonomy);

  // Validate as the last step before sending; the validator's own words go to stderr.
  const result = validate(text, { taxonomy });
  for (const w of result.warnings ?? []) console.error(`send: warning: ${w}`);
  if (!result.ok) { for (const e of result.errors ?? []) console.error(`send: ${e}`); console.error('send: not sent — the message does not validate'); return 2; }
  const msg = parse(text);
  const from = msg.metadata?.FROM;
  if (from !== me.address) {
    console.error(`send: FROM is ${from ?? '(missing)'} but this session is ${me.address}; not sent — the sender is the login, never a claim`);
    return 2;
  }
  const id = msg.metadata?.['MESSAGE-ID'] ?? '(none)';
  if (dry) { console.error(`send: would post ${msg.type} ${id} from ${me.address} to ${channel} at ${relayUrl}`); return 0; }

  const tok = token(root, cfg);
  if (!tok) { console.error('send: no CLAUDE_BRIDGE_AUTH_TOKEN in the environment or the working copy — not sent'); return 3; }
  let res;
  try {
    res = await api(tok, '/api/send', { method: 'POST', body: JSON.stringify({ channel, sender: me.address, content: text }), relayUrl });
  } catch (e) {
    console.error(`send: relay unreachable at ${relayUrl} (${e.message}) — not sent`); return 3;
  }
  console.log(`sent seq ${res.seq} ${msg.type} ${id}${res.deduplicated ? ' (deduplicated: the relay already had it)' : ''}`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  main().then(code => process.exit(code), e => { console.error(`send: ${e.message}`); process.exit(1); });
