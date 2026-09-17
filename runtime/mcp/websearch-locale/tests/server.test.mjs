// The locale search server: the locale fixes country and languages per
// engine, the caller only the query; every secret goes into one header
// and nowhere else; the MCP subset answers what Claude Code asks, one
// tool per configured engine.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { readLocale, searchUrl, search, handle, tools } from '../server.mjs';

const SERVER = new URL('../server.mjs', import.meta.url).pathname;
const LOCALE = { timezone: 'Asia/Tbilisi',
                 google: { gl: 'ge', hl: 'ka', lr: 'lang_ka', tool_description: 'ვებ-ძიება ქართულად' },
                 brave: { country: 'ALL', tool_description: 'გლობალური ვებ-ძიება' } };
const G = { GOOGLE_CSE_API_KEY: 'AIza-secret-key-value-0123456789', GOOGLE_CSE_CX: '0123456789abcdef0' };
const B = { BRAVE_SEARCH_API_KEY: 'BSA-secret-key-value-0123456789' };
const localeFile = (l = LOCALE) => { const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'loc-')), 'locale.json'); fs.writeFileSync(f, JSON.stringify(l)); return f; };

test('readLocale: an engine block is complete or absent; at least one; searchUrl per engine — the locale decides the parameters, the caller the query, no key in a URL', () => {
  assert.deepEqual(readLocale(localeFile()), LOCALE);
  assert.throws(() => readLocale(localeFile({ timezone: 'x', google: { ...LOCALE.google, lr: '' } })), /google\.lr missing/);
  assert.throws(() => readLocale(localeFile({ timezone: 'x' })), /no engine configured/);
  assert.deepEqual(Object.keys(readLocale(localeFile({ timezone: 'x', brave: LOCALE.brave }))), ['timezone', 'brave'], 'one engine alone is fine');
  assert.throws(() => readLocale(undefined), /WEBSEARCH_LOCALE_FILE/);
  const g = new URL(searchUrl('google', 'თბილისის მეტრო', LOCALE, { cx: G.GOOGLE_CSE_CX, count: 5 }));
  assert.equal(g.origin + g.pathname, 'https://www.googleapis.com/customsearch/v1');
  assert.deepEqual(['q', 'gl', 'hl', 'lr', 'cx', 'num'].map(k => g.searchParams.get(k)), ['თბილისის მეტრო', 'ge', 'ka', 'lang_ka', G.GOOGLE_CSE_CX, '5']);
  assert.ok(!g.searchParams.has('key'), 'the key never rides in the URL');
  assert.equal(new URL(searchUrl('google', 'x', LOCALE, { cx: 'c', count: 99 })).searchParams.get('num'), '10', 'clamped to the API maximum');
  const b = new URL(searchUrl('brave', 'თბილისის მეტრო', LOCALE, { count: 5 }));
  assert.equal(b.origin + b.pathname, 'https://api.search.brave.com/res/v1/web/search');
  assert.deepEqual(['q', 'country', 'count'].map(k => b.searchParams.get(k)), ['თბილისის მეტრო', 'ALL', '5']);
  assert.ok(!b.searchParams.has('search_lang') && !b.searchParams.has('ui_lang'), 'a language Brave lacks is not sent');
  const withLang = new URL(searchUrl('brave', 'x', { brave: { country: 'US', search_lang: 'en', ui_lang: 'en-US' } }));
  assert.equal(withLang.searchParams.get('search_lang'), 'en'); assert.equal(withLang.searchParams.get('ui_lang'), 'en-US');
});

test('search: each secret in its one header and nowhere else; results as text from either shape; every failure named without a secret', async () => {
  const seen = [];
  const google = async (url, init) => { seen.push({ url, init }); return { ok: true, status: 200, json: async () => ({ items: [{ title: 'მეტრო', link: 'https://example.ge/m', snippet: 'აღწერა\nხაზი  ორი' }] }) }; };
  const r = await search('google', 'მეტრო', LOCALE, { secrets: G, fetchImpl: google });
  assert.equal(r.isError, false); assert.match(r.text, /1\. მეტრო\n   https:\/\/example\.ge\/m\n   აღწერა ხაზი ორი/);
  assert.equal(seen[0].init.headers['x-goog-api-key'], G.GOOGLE_CSE_API_KEY); assert.ok(!seen[0].url.includes(G.GOOGLE_CSE_API_KEY)); assert.ok(seen[0].url.includes(`cx=${G.GOOGLE_CSE_CX}`));
  const brave = async (url, init) => { seen.push({ url, init }); return { ok: true, status: 200, json: async () => ({ web: { results: [{ title: 't', url: 'u', description: 'd <strong>e</strong>' }] } }) }; };
  const rb = await search('brave', 'x', LOCALE, { secrets: B, fetchImpl: brave });
  assert.equal(rb.isError, false); assert.match(rb.text, /1\. t\n   u\n   d e/);
  assert.equal(seen[1].init.headers['X-Subscription-Token'], B.BRAVE_SEARCH_API_KEY); assert.ok(!seen[1].url.includes(B.BRAVE_SEARCH_API_KEY));
  for (const out of [r, rb]) assert.ok(![...Object.values(G), ...Object.values(B)].some(v => JSON.stringify(out).includes(v)));
  assert.deepEqual(await search('google', 'x', LOCALE, { secrets: { GOOGLE_CSE_API_KEY: G.GOOGLE_CSE_API_KEY }, fetchImpl: google }), { isError: true, text: 'no GOOGLE_CSE_CX in the synced secrets: bin/fabric-secrets sync, after it is in Doppler for this login' });
  assert.deepEqual(await search('brave', 'x', LOCALE, { secrets: {}, fetchImpl: brave }), { isError: true, text: 'no BRAVE_SEARCH_API_KEY in the synced secrets: bin/fabric-secrets sync, after it is in Doppler for this login' });
  assert.deepEqual(await search('google', 'x', LOCALE, { secrets: G, fetchImpl: async () => ({ ok: false, status: 403, json: async () => ({ error: { message: 'API key not valid. Please pass a valid API key.' } }) }) }), { isError: true, text: 'search refused: HTTP 403 — API key not valid. Please pass a valid API key.' });
  assert.deepEqual(await search('brave', 'x', LOCALE, { secrets: B, fetchImpl: async () => ({ ok: false, status: 422, json: async () => ({ error: { detail: 'Unable to validate request parameter(s)' } }) }) }), { isError: true, text: 'search refused: HTTP 422 — Unable to validate request parameter(s)' });
  assert.deepEqual(await search('google', 'x', LOCALE, { secrets: G, fetchImpl: async () => ({ ok: false, status: 429, json: async () => { throw new Error('x'); } }) }), { isError: true, text: 'search refused: HTTP 429' });
  assert.deepEqual(await search('google', 'x', LOCALE, { secrets: G, fetchImpl: async () => { throw new Error('ECONNREFUSED'); } }), { isError: true, text: 'search failed: unreachable' });
  assert.deepEqual(await search('google', 'x', LOCALE, { secrets: G, fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({}) }) }), { isError: false, text: 'no results (google)' });
});

test('handle: the MCP subset — initialize, initialized, ping, one tool per engine in the locale, tools/call on each, and -32601 for the rest', async () => {
  const ctx = { locale: LOCALE, secrets: { google: G, brave: B }, fetchImpl: async url => ({ ok: true, status: 200, json: async () => url.includes('googleapis') ? { items: [{ title: 'g', link: 'u', snippet: 'd' }] } : { web: { results: [{ title: 'b', url: 'u', description: 'd' }] } } }) };
  const init = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }, ctx);
  assert.equal(init.result.protocolVersion, '2025-06-18'); assert.deepEqual(init.result.capabilities, { tools: {} });
  assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }, ctx), null, 'a notification gets no reply');
  assert.deepEqual((await handle({ jsonrpc: '2.0', id: 2, method: 'ping' }, ctx)).result, {});
  const list = await handle({ jsonrpc: '2.0', id: 3, method: 'tools/list' }, ctx);
  assert.deepEqual(list.result.tools, tools(LOCALE)); assert.deepEqual(list.result.tools.map(t => [t.name, t.description]), [['web_search', 'ვებ-ძიება ქართულად'], ['web_search_global', 'გლობალური ვებ-ძიება']]);
  assert.deepEqual(tools({ brave: LOCALE.brave }).map(t => t.name), ['web_search_global'], 'only the configured engine');
  const g = await handle({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'web_search', arguments: { query: 'მეტრო' } } }, ctx);
  assert.equal(g.result.isError, false); assert.match(g.result.content[0].text, /^1\. g/);
  const b = await handle({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'web_search_global', arguments: { query: 'მეტრო' } } }, ctx);
  assert.match(b.result.content[0].text, /^1\. b/);
  assert.equal((await handle({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'web_search_global', arguments: { query: 'x' } } }, { ...ctx, locale: { google: LOCALE.google } })).error.code, -32602, 'an engine the locale lacks is not a tool');
  assert.equal((await handle({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'web_search', arguments: { query: 'x' } } }, ctx)).error.code, -32602);
  assert.equal((await handle({ jsonrpc: '2.0', id: 8, method: 'resources/list' }, ctx)).error.code, -32601);
  assert.equal((await handle({ id: 9, method: 'ping' }, ctx)).error.code, -32600);
});

test('stdio: newline-delimited JSON-RPC end to end; a missing secret is a tool error, not a crash; no secret on stderr or stdout', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-home-')); fs.mkdirSync(path.join(home, '.config', 'agent-fabric'), { recursive: true });
  fs.writeFileSync(path.join(home, '.config', 'agent-fabric', 'secrets.env'), `export GOOGLE_CSE_API_KEY='${G.GOOGLE_CSE_API_KEY}'\n`);   // no cx, no brave key
  const child = spawn('node', [SERVER], { env: { ...process.env, HOME: home, WEBSEARCH_LOCALE_FILE: localeFile() } });
  let out = '', err = ''; child.stdout.on('data', d => { out += d; }); child.stderr.on('data', d => { err += d; });
  for (const m of [{ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }, { jsonrpc: '2.0', method: 'notifications/initialized' }, { jsonrpc: '2.0', id: 2, method: 'tools/list' },
                   { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'web_search', arguments: { query: 'მეტრო' } } }]) child.stdin.write(JSON.stringify(m) + '\n');
  child.stdin.write('not json\n'); child.stdin.end();
  await new Promise(r => child.on('close', r));
  const lines = out.trim().split('\n').map(l => JSON.parse(l));
  assert.equal(lines[0].result.serverInfo.name, 'websearch-locale');
  assert.deepEqual(lines[1].result.tools.map(t => t.name), ['web_search', 'web_search_global']);
  assert.equal(lines[2].result.isError, true); assert.match(lines[2].result.content[0].text, /no GOOGLE_CSE_CX/);
  assert.equal(lines[3].error.code, -32700);
  assert.ok(!out.includes(G.GOOGLE_CSE_API_KEY) && !err.includes(G.GOOGLE_CSE_API_KEY));
});
