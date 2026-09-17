// The locale search server: the locale fixes country and language, the
// caller only the query; the key goes into one header and nowhere else;
// the MCP subset answers what Claude Code asks.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { readLocale, searchUrl, search, handle, tools, KEY_NAME } from '../server.mjs';

const SERVER = new URL('../server.mjs', import.meta.url).pathname;
const LOCALE = { country: 'GE', search_lang: 'ka', ui_lang: 'ka-GE', timezone: 'Asia/Tbilisi', tool_description: 'ვებ-ძიება ქართულად' };
const KEY = 'BSA-secret-key-value-0123456789';
const localeFile = () => { const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'loc-')), 'locale.json'); fs.writeFileSync(f, JSON.stringify(LOCALE)); return f; };

test('readLocale: every field required; searchUrl: the locale decides country and language, the caller the query', () => {
  assert.deepEqual(readLocale(localeFile()), LOCALE);
  const bad = localeFile(); fs.writeFileSync(bad, JSON.stringify({ ...LOCALE, ui_lang: '' }));
  assert.throws(() => readLocale(bad), /missing ui_lang/);
  assert.throws(() => readLocale(undefined), /WEBSEARCH_LOCALE_FILE/);
  const u = new URL(searchUrl('თბილისის მეტრო', LOCALE, 5));
  assert.equal(u.origin + u.pathname, 'https://api.search.brave.com/res/v1/web/search');
  assert.equal(u.searchParams.get('q'), 'თბილისის მეტრო'); assert.equal(u.searchParams.get('country'), 'GE');
  assert.equal(u.searchParams.get('search_lang'), 'ka'); assert.equal(u.searchParams.get('ui_lang'), 'ka-GE'); assert.equal(u.searchParams.get('count'), '5');
  assert.equal(new URL(searchUrl('x', LOCALE, 99)).searchParams.get('count'), '20', 'clamped');
  assert.equal(new URL(searchUrl('x', LOCALE)).searchParams.get('count'), '10');
});

test('search: the key in one header and nowhere else; results as text; every failure named without the key', async () => {
  const seen = [];
  const ok = async (url, init) => { seen.push({ url, init }); return { ok: true, status: 200, json: async () => ({ web: { results: [{ title: 'მეტრო', url: 'https://example.ge/m', description: 'აღწერა <strong>ხაზი</strong>' }] } }) }; };
  const r = await search('მეტრო', LOCALE, { key: KEY, fetchImpl: ok });
  assert.equal(r.isError, false); assert.match(r.text, /1\. მეტრო\n   https:\/\/example\.ge\/m\n   აღწერა ხაზი/);
  assert.equal(seen[0].init.headers['X-Subscription-Token'], KEY); assert.ok(!seen[0].url.includes(KEY), 'never in the URL');
  assert.ok(!JSON.stringify(r).includes(KEY));
  assert.deepEqual(await search('x', LOCALE, { key: undefined, fetchImpl: ok }), { isError: true, text: `no ${KEY_NAME} in the synced secrets: bin/fabric-secrets sync, after the key is in Doppler for this login` });
  assert.deepEqual(await search('x', LOCALE, { key: KEY, fetchImpl: async () => ({ ok: false, status: 429 }) }), { isError: true, text: 'search refused: HTTP 429' });
  assert.deepEqual(await search('x', LOCALE, { key: KEY, fetchImpl: async () => { throw new Error('ECONNREFUSED'); } }), { isError: true, text: 'search failed: unreachable' });
  assert.deepEqual(await search('x', LOCALE, { key: KEY, fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ web: { results: [] } }) }) }), { isError: false, text: 'no results (GE/ka)' });
});

test('handle: the MCP subset — initialize, initialized, ping, tools/list in the locale, tools/call, and -32601 for the rest', async () => {
  const ctx = { locale: LOCALE, key: KEY, fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ web: { results: [{ title: 't', url: 'u', description: 'd' }] } }) }) };
  const init = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }, ctx);
  assert.equal(init.result.protocolVersion, '2025-06-18'); assert.deepEqual(init.result.capabilities, { tools: {} });
  assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }, ctx), null, 'a notification gets no reply');
  assert.deepEqual((await handle({ jsonrpc: '2.0', id: 2, method: 'ping' }, ctx)).result, {});
  const list = await handle({ jsonrpc: '2.0', id: 3, method: 'tools/list' }, ctx);
  assert.deepEqual(list.result.tools, tools(LOCALE)); assert.equal(list.result.tools[0].description, 'ვებ-ძიება ქართულად'); assert.deepEqual(list.result.tools[0].inputSchema.required, ['query']);
  const call = await handle({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'web_search', arguments: { query: 'მეტრო' } } }, ctx);
  assert.equal(call.result.isError, false); assert.match(call.result.content[0].text, /^1\. t/);
  assert.equal((await handle({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'other', arguments: {} } }, ctx)).error.code, -32602);
  assert.equal((await handle({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'web_search', arguments: { query: 'x' } } }, ctx)).error.code, -32602);
  assert.equal((await handle({ jsonrpc: '2.0', id: 7, method: 'resources/list' }, ctx)).error.code, -32601);
  assert.equal((await handle({ id: 8, method: 'ping' }, ctx)).error.code, -32600);
});

test('stdio: newline-delimited JSON-RPC end to end; a missing key is a tool error, not a crash; the key never on stderr or stdout', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-home-')); fs.mkdirSync(path.join(home, '.config', 'agent-fabric'), { recursive: true });
  fs.writeFileSync(path.join(home, '.config', 'agent-fabric', 'secrets.env'), `export ${KEY_NAME}='${KEY}'\n`);
  const child = spawn('node', [SERVER], { env: { ...process.env, HOME: home, WEBSEARCH_LOCALE_FILE: localeFile() } });
  let out = '', err = ''; child.stdout.on('data', d => { out += d; }); child.stderr.on('data', d => { err += d; });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }) + '\n');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) + '\n');
  child.stdin.write('not json\n');
  child.stdin.end();
  await new Promise(r => child.on('close', r));
  const lines = out.trim().split('\n').map(l => JSON.parse(l));
  assert.equal(lines[0].id, 1); assert.equal(lines[0].result.serverInfo.name, 'websearch-locale');
  assert.equal(lines[1].id, 2); assert.equal(lines[1].result.tools[0].name, 'web_search');
  assert.equal(lines[2].error.code, -32700);
  assert.ok(!out.includes(KEY) && !err.includes(KEY));
});
