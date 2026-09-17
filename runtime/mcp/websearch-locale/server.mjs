// runtime/mcp/websearch-locale/server.mjs — a web search located in a
// login's locale, as an MCP server on stdio.
//
// Claude Code's own WebSearch tool takes a query and two domain lists
// and nothing else (read back 2026-09-17: its schema is closed, and its
// description says US-only); Anthropic's `user_location` exists on the
// Messages API and is not exposed by the harness. So a language-culture
// holder, who must search as a reader of its locale would, gets this
// tool instead: one MCP tool, `web_search`, backed by the Brave Search
// API, whose `country`, `search_lang` and `ui_lang` are fixed from the
// locale file the fabric authored for the login's suffix
// (identities/roles/language-culture/locale/<suffix>/locale.json) — the
// caller chooses the query, never the locale. Installed into the user
// scope of a language-culture login by install-agent-files.sh, removed
// from any other. The key is BRAVE_SEARCH_API_KEY, read from the synced
// secrets file at call time and put into one request header; it never
// reaches argv, a log line or a result.
//
// The tool's description is the locale file's, in the locale: its reader
// is the holder, who reasons in that language. The worker never sees
// this tool — it has one inert tool by design.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { syncedVar } from '../../../communication/gzcoord/scripts/inbox.mjs';

export const BRAVE_URL = 'https://api.search.brave.com/res/v1/web/search';
export const KEY_NAME = 'BRAVE_SEARCH_API_KEY';
export const LOCALE_FIELDS = ['country', 'timezone', 'tool_description'];   // required; search_lang and ui_lang only where Brave has the language

export function readLocale(file = process.env.WEBSEARCH_LOCALE_FILE) {
  if (!file) throw new Error('WEBSEARCH_LOCALE_FILE is not set: the locale file decides the country and language');
  const l = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const k of LOCALE_FIELDS) if (typeof l[k] !== 'string' || !l[k]) throw new Error(`locale file ${file}: missing ${k}`);
  return l;
}

export function searchUrl(query, locale, count = 10) {
  const u = new URL(BRAVE_URL);
  u.searchParams.set('q', query);
  u.searchParams.set('country', locale.country);
  // Brave validates every locale parameter against its own lists (read
  // back 2026-09-17: GE, ka and ka-GE are each a 422); a locale file names
  // only the values Brave has, and a language it lacks is simply not sent.
  if (locale.search_lang) u.searchParams.set('search_lang', locale.search_lang);
  if (locale.ui_lang) u.searchParams.set('ui_lang', locale.ui_lang);
  u.searchParams.set('count', String(Math.min(20, Math.max(1, Number(count) || 10))));
  return u.toString();
}

// One search: the results as text, one block each — title, url,
// description — or an error the caller can read, never the key.
export async function search(query, locale, { key = syncedVar(KEY_NAME) ?? process.env[KEY_NAME], fetchImpl = globalThis.fetch, count } = {}) {
  if (!key) return { isError: true, text: `no ${KEY_NAME} in the synced secrets: bin/fabric-secrets sync, after the key is in Doppler for this login` };
  let r;
  try { r = await fetchImpl(searchUrl(query, locale, count), { headers: { Accept: 'application/json', 'X-Subscription-Token': key }, signal: AbortSignal.timeout(20000) }); }
  catch (e) { return { isError: true, text: `search failed: ${e?.name === 'TimeoutError' ? 'timeout' : 'unreachable'}` }; }
  if (!r.ok) return { isError: true, text: `search refused: HTTP ${r.status}` };
  let j; try { j = await r.json(); } catch { return { isError: true, text: 'search answered something that is not JSON' }; }
  const results = j?.web?.results ?? [];
  if (!results.length) return { isError: false, text: `no results (${locale.country}${locale.search_lang ? '/' + locale.search_lang : ''})` };
  return { isError: false, text: results.map((x, i) => `${i + 1}. ${x.title ?? ''}\n   ${x.url ?? ''}\n   ${(x.description ?? '').replace(/<[^>]+>/g, '')}`).join('\n\n') };
}

export function tools(locale) {
  return [{ name: 'web_search', description: locale.tool_description,
            inputSchema: { type: 'object', additionalProperties: false, required: ['query'],
                           properties: { query: { type: 'string', minLength: 2 }, count: { type: 'integer', minimum: 1, maximum: 20 } } } }];
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
    if (msg.params?.name !== 'web_search') return error(-32602, `unknown tool ${msg.params?.name}`);
    const q = msg.params?.arguments?.query;
    if (typeof q !== 'string' || q.length < 2) return error(-32602, 'query: a string of at least two characters');
    const r = await search(q, ctx.locale, { key: ctx.key, fetchImpl: ctx.fetchImpl, count: msg.params?.arguments?.count });
    return reply({ content: [{ type: 'text', text: r.text }], isError: r.isError });
  }
  return error(-32601, `method not found: ${msg.method}`);
}

export async function main() {
  const ctx = { locale: readLocale(), key: undefined, fetchImpl: globalThis.fetch };
  let buf = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }) + '\n'); continue; }
      const out = await handle(msg, { ...ctx, key: syncedVar(KEY_NAME) ?? process.env[KEY_NAME] });
      if (out) process.stdout.write(JSON.stringify(out) + '\n');
    }
  }
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().then(c => process.exit(c)).catch(e => { console.error(`websearch-locale: ${e.message}`); process.exit(1); });
export const _home = os.homedir;
