// runtime/control/accounts.mjs — the Claude accounts this login observes
// (ops.mjs `accounts`; docs/claude-accounts.md). Run as the observing login,
// in practice the coordinator's.
//
//   fabric-accounts login <account>   sign one Claude account in, once: opens the harness
//                                     in that account's own config directory; /login in the
//                                     browser AS THAT ACCOUNT, then /exit. A real terminal.
//   fabric-accounts list              each observed account: signed in, email, sign-in expiry
//   fabric-accounts read              read every account's windows now (the harness's /usage)
//
// Prints no token: a sign-in is described by its email, its expiry and
// whether a refresh token is held — never by a value.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { accountsDir, accountSlugs, accounts, claudeBin, ACCOUNT_SLUG } from './ops.mjs';

const USAGE = `usage: fabric-accounts login <account> | list | read
  <account>: lowercase letters, digits and hyphens — the account's email with @ and . as -,
             e.g. claude-pzhuy-8alias-com (the Doppler template's name without its prefix)`;

function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } }

// What a config directory holds, in words: no token leaves this function.
export function describe(dir, now = Date.now()) {
  const oauth = readJson(path.join(dir, '.credentials.json'))?.claudeAiOauth ?? null;
  const profile = readJson(path.join(dir, '.claude.json'))?.oauthAccount ?? null;
  const exp = Number(oauth?.expiresAt);
  return {
    slug: path.basename(dir),
    email: profile?.emailAddress ?? null,
    signed_in: Boolean(oauth?.accessToken),
    refresh_token: Boolean(oauth?.refreshToken),
    expires_at: Number.isFinite(exp) ? new Date(exp).toISOString() : null,
    expired: Number.isFinite(exp) ? exp <= now : null,
  };
}

export function listLines(dir, now = Date.now()) {
  const slugs = accountSlugs(dir);
  if (!slugs.length) return [`no Claude account observed under ${dir} — fabric-accounts login <account>`];
  return slugs.map(s => {
    const d = describe(path.join(dir, s), now);
    const state = !d.signed_in ? 'not signed in' : !d.refresh_token ? 'signed in, NO refresh token (will lapse)' : d.expired ? `sign-in lapsed at ${d.expires_at} (the next read renews it)` : `signed in until ${d.expires_at}`;
    return `${s.padEnd(34)} ${(d.email ?? '-').padEnd(34)} ${state}`;
  });
}

export async function main(argv = process.argv.slice(2), { home = os.homedir(), env = process.env, stdinTTY = process.stdin.isTTY, spawn = spawnSync, read = accounts } = {}) {
  const [cmd, arg] = argv;
  const dir = accountsDir(home, env);
  if (cmd === 'list' && argv.length === 1) { console.log(listLines(dir).join('\n')); return 0; }
  if (cmd === 'read' && argv.length === 1) {
    const r = await read(home, { dir });
    if (r.status === 'none') { console.log(listLines(dir).join('\n')); return 1; }
    for (const a of r.accounts) {
      const m = (a.limits ?? []).map(l => `${l.kind} ${l.percent ?? '-'}%${l.model ? ` (${l.model})` : ''} resets ${String(l.resets_at ?? '-').slice(0, 16)}`).join('; ');
      console.log(`${(a.email ?? a.slug).padEnd(34)} ${a.status}${m ? `  ${m}` : ''}${a.error ? `  ${a.error}` : ''}`);
    }
    return r.accounts.every(a => a.status === 'ok') ? 0 : 1;
  }
  if (cmd === 'login' && argv.length === 2) {
    if (!ACCOUNT_SLUG.test(arg)) { console.error(`fabric-accounts: ${JSON.stringify(arg)} is not an account name\n${USAGE}`); return 2; }
    if (!stdinTTY) { console.error('fabric-accounts: login opens the harness for /login in a browser — run it in a real terminal, not through a tool or `!`'); return 2; }
    const target = path.join(dir, arg);
    fs.mkdirSync(target, { recursive: true, mode: 0o700 });
    fs.chmodSync(target, 0o700);
    console.error(`fabric-accounts: ${arg} — in the harness that opens now: /login, approve in the browser SIGNED IN AS THAT ACCOUNT, then /exit`);
    // The same clean environment the reads use: an inherited token would
    // make the harness think it is already signed in, as someone else.
    const clean = Object.fromEntries(Object.entries(env).filter(([k]) => !['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL'].includes(k)));
    const r = spawn(claudeBin(home), [], { cwd: target, env: { ...clean, CLAUDE_CONFIG_DIR: target }, stdio: 'inherit' });
    const d = describe(target);
    console.error(d.signed_in ? `fabric-accounts: ${arg} signed in as ${d.email ?? '(email not yet recorded)'}${d.refresh_token ? '' : ' — but with no refresh token; it will lapse'}` : `fabric-accounts: ${arg} is not signed in (no /login completed)`);
    return d.signed_in && r.status === 0 ? 0 : 1;
  }
  console.error(USAGE);
  return 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(c => process.exit(c)).catch(e => { console.error(`fabric-accounts: ${e.message}`); process.exit(1); });
