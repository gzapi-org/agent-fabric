// runtime/mcp/websearch-locale/server.mjs — web search located in a
// login's locale, as an MCP server on stdio, over two engines.
//
// Claude Code's own WebSearch tool takes a query and two domain lists
// and nothing else (read back 2026-09-17: its schema is closed, and its
// description says US-only); Anthropic's `user_location` exists on the
// Messages API and is not exposed by the harness. So a language-culture
// holder, who must search as a reader of its locale would, gets this
// server instead: one tool per engine the locale file configures
// (identities/roles/language-culture/locale/<suffix>/locale.json, kept
// by the CEO: "keep both engines"):
//
//   web_search         Google's Custom Search JSON API, with `gl` (the
//                      country), `hl` (the interface language) and `lr`
//                      (results in a language) fixed from the file — the
//                      locale as a browser there would have it. Secrets
//                      GOOGLE_CSE_API_KEY (one request header) and
//                      GOOGLE_CSE_CX (the Programmable Search Engine id).
//   web_search_global  Brave's Search API, `country` from the file (ALL
//                      for a locale Brave lacks — it has no Georgian: GE,
//                      ka and ka-GE each refused, 2026-09-17) and
//                      search_lang / ui_lang only where the file names
//                      them: a second index, steered by the query's
//                      language. Secret BRAVE_SEARCH_API_KEY.
//
// The caller chooses the query, never the locale. Installed into the
// user scope of a language-culture login by install-agent-files.sh,
// removed from any other. Every secret is read from the synced file at
// call time and put into one header — never a URL, a log line or a
// result. Each tool's description is the file's, in the locale: its
// reader is the holder, who reasons in that language. The worker never
// sees these tools — it has one inert tool by design.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { syncedVar } from '../../../communication/gzcoord/scripts/inbox.mjs';

export const GOOGLE_URL = 'https://www.googleapis.com/customsearch/v1';
export const BRAVE_URL = 'https://api.search.brave.com/res/v1/web/search';
export const SECRETS = { google: ['GOOGLE_CSE_API_KEY', 'GOOGLE_CSE_CX'], brave: ['BRAVE_SEARCH_API_KEY'] };
export const TOOL_NAMES = { google: 'web_search', brave: 'web_search_global' };
const REQUIRED = { google: ['gl', 'hl', 'lr', 'tool_description'], brave: ['country', 'tool_description'] };

export function readLocale(file = process.env.WEBSEARCH_LOCALE_FILE) {
  if (!file) throw new Error('WEBSEARCH_LOCALE_FILE is not set: the locale file decides the country and language');
  const l = JSON.parse(fs.readFileSync(file, 'utf8'));
  const engines = Object.keys(REQUIRED).filter(e => l[e]);
  if (!engines.length) throw new Error(`locale file ${file}: no engine configured (google, brave)`);
  for (const e of engines) for (const k of REQUIRED[e]) if (typeof l[e][k] !== 'string' || !l[e][k]) throw new Error(`locale file ${file}: ${e}.${k} missing`);
  return l;
}

// The request URL per engine: the query, the locale's parameters, the
// count; a key never rides here (Google's cx is an engine id, not a key).
export function searchUrl(engine, query, locale, { cx, count } = {}) {
  if (engine === 'google') {
    const u = new URL(GOOGLE_URL); const g = locale.google;
    u.searchParams.set('q', query); u.searchParams.set('gl', g.gl); u.searchParams.set('hl', g.hl); u.searchParams.set('lr', g.lr);
    u.searchParams.set('cx', cx ?? ''); u.searchParams.set('num', String(Math.min(10, Math.max(1, Number(count) || 10))));
    return u.toString();
  }
  const u = new URL(BRAVE_URL); const b = locale.brave;
  u.searchParams.set('q', query); u.searchParams.set('country', b.country);
  if (b.search_lang) u.searchParams.set('search_lang', b.search_lang);
  if (b.ui_lang) u.searchParams.set('ui_lang', b.ui_lang);
  u.searchParams.set('count', String(Math.min(20, Math.max(1, Number(count) || 10))));
  return u.toString();
}

const secretsOf = (engine, env = process.env) => Object.fromEntries(SECRETS[engine].map(n => [n, syncedVar(n) ?? env[n]]));

// One search on one engine: the results as text, one block each —
// title, link, snippet — or an error the caller can read, never a secret.
export async function search(engine, query, locale, { secrets = secretsOf(engine), fetchImpl = globalThis.fetch, count } = {}) {
  const missing = SECRETS[engine].find(n => !secrets[n]);
  if (missing) return { isError: true, text: `no ${missing} in the synced secrets: bin/fabric-secrets sync, after it is in Doppler for this login` };
  const headers = engine === 'google' ? { Accept: 'application/json', 'x-goog-api-key': secrets.GOOGLE_CSE_API_KEY } : { Accept: 'application/json', 'X-Subscription-Token': secrets.BRAVE_SEARCH_API_KEY };
  let r;
  try { r = await fetchImpl(searchUrl(engine, query, locale, { cx: secrets.GOOGLE_CSE_CX, count }), { headers, signal: AbortSignal.timeout(20000) }); }
  catch (e) { return { isError: true, text: `search failed: ${e?.name === 'TimeoutError' ? 'timeout' : 'unreachable'}` }; }
  if (!r.ok) {
    let why = ''; try { const j = await r.json(); why = j?.error?.message ?? j?.error?.detail ?? ''; } catch { /* no body */ }
    return { isError: true, text: `search refused: HTTP ${r.status}${why ? ` — ${String(why).slice(0, 200)}` : ''}` };
  }
  let j; try { j = await r.json(); } catch { return { isError: true, text: 'search answered something that is not JSON' }; }
  const items = engine === 'google' ? (j?.items ?? []).map(x => [x.title, x.link, x.snippet]) : (j?.web?.results ?? []).map(x => [x.title, x.url, (x.description ?? '').replace(/<[^>]+>/g, '')]);
  if (!items.length) return { isError: false, text: `no results (${engine})` };
  return { isError: false, text: items.map(([t, l, d], i) => `${i + 1}. ${t ?? ''}\n   ${l ?? ''}\n   ${(d ?? '').replace(/\s+/g, ' ')}`).join('\n\n') };
}

export function tools(locale) {
  return Object.keys(REQUIRED).filter(e => locale[e]).map(e => ({
    name: TOOL_NAMES[e], description: locale[e].tool_description,
    inputSchema: { type: 'object', additionalProperties: false, required: ['query'],
                   properties: { query: { type: 'string', minLength: 2 }, count: { type: 'integer', minimum: 1, maximum: e === 'google' ? 10 : 20 } } } }));
}

// JSON-RPC 2.0 over stdio, newline-delimited, the MCP subset a tool
// server needs: initialize, the initialized notification, ping,
// tools/list, tools/call. Anything else is -32601.
export async function handle(msg, ctx) {
  const reply = result => ({ jsonrpc: '2.0', id: msg.id, result });
  const error = (code, message) => ({ jsonrpc: '2.0', id: msg.id ?? null, error: { code, message } });
  if (msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return error(-32600, 'invalid request');
  if (msg.method === 'notifications/initialized' || msg.method.startsWith('notifications/')) return null;
  if (msg.method === 'initialize') return reply({ protocolVersion: msg.params?.protocolVersion ?? '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'websearch-locale', version: '1' } });
  if (msg.method === 'ping') return reply({});
  if (msg.method === 'tools/list') return reply({ tools: tools(ctx.locale) });
  if (msg.method === 'tools/call') {
    const engine = Object.keys(TOOL_NAMES).find(e => TOOL_NAMES[e] === msg.params?.name && ctx.locale[e]);
    if (!engine) return error(-32602, `unknown tool ${msg.params?.name}`);
    const q = msg.params?.arguments?.query;
    if (typeof q !== 'string' || q.length < 2) return error(-32602, 'query: a string of at least two characters');
    const r = await search(engine, q, ctx.locale, { ...(ctx.secrets ? { secrets: ctx.secrets[engine] } : {}), fetchImpl: ctx.fetchImpl, count: msg.params?.arguments?.count });
    return reply({ content: [{ type: 'text', text: r.text }], isError: r.isError });
  }
  return error(-32601, `method not found: ${msg.method}`);
}

export async function main() {
  const ctx = { locale: readLocale(), fetchImpl: globalThis.fetch };   // secrets: read at each call
  let buf = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }) + '\n'); continue; }
      const out = await handle(msg, ctx);
      if (out) process.stdout.write(JSON.stringify(out) + '\n');
    }
  }
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(c => process.exit(c)).catch(e => { console.error(`websearch-locale: ${e.message}`); process.exit(1); });
