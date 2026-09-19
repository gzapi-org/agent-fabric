// The control agent's extractors, against a scratch home: every section
// says what it knows or why not, and no output ever carries a secret value.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { identity, usage, keys, fabric, session, script, scriptCounts, notesDir, workerTranscripts, languages, langidCmd, memoryDirs, memorySlug, memory, tokens, equivalent, TOKEN_RATIOS, collect, KEY_NAMES, OPS, MEMORY_PART_BYTES } from '../ops.mjs';

const SECRETS = { OPENROUTER_API_KEY: 'sk-or-v1-abcdefghijklmnopqrstuvwxyz0123456789', GH_TOKEN: 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', CLAUDE_BRIDGE_AUTH_TOKEN: 'bridge-token-value-1234567890' };
const ACCESS = 'oauth-access-token-value-XYZ';
function home() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-home-'));
  fs.mkdirSync(path.join(h, '.config', 'agent-fabric'), { recursive: true });
  fs.mkdirSync(path.join(h, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(h, '.config', 'agent-fabric', 'secrets.env'), Object.entries(SECRETS).map(([k, v]) => `export ${k}='${v}'`).join('\n') + '\n');
  fs.writeFileSync(path.join(h, '.claude', '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: ACCESS, refreshToken: 'refresh-XYZ', subscriptionType: 'max' } }));
  fs.writeFileSync(path.join(h, '.claude.json'), JSON.stringify({ oauthAccount: { emailAddress: 'someone@example.org', organizationName: 'Example Org', accountUuid: 'u-1' } }));
  return h;
}
const who = { agent: 'db-admin', host: 'develop-qzapp', role: 'db-admin', project: 'gzapp', working_copy: '/home/db-admin/projects/gzapp' };
function assertNoSecret(obj) {
  const s = JSON.stringify(obj);
  for (const v of [...Object.values(SECRETS), ACCESS, 'refresh-XYZ']) assert.ok(!s.includes(v), `a secret value leaked into the output: ${v.slice(0, 6)}…`);
}

test('identity: the account and the Claude account it is signed into, no secret', () => {
  const h = home();
  const id = identity(h, who);
  assert.deepEqual(id, { agent: 'db-admin', host: 'develop-qzapp', role: 'db-admin', project: 'gzapp', working_copy: '/home/db-admin/projects/gzapp',
                         claude_account: { email: 'someone@example.org', organization: 'Example Org' }, credentials_present: true });
  assertNoSecret(id);
  fs.unlinkSync(path.join(h, '.claude.json'));
  assert.equal(identity(h, who).claude_account, null, 'no profile record: null, not a throw');
});

test('usage: the two windows through the account\'s own token, which goes into one header and nowhere else', async () => {
  const h = home();
  const seen = [];
  const fetchOk = async (url, init) => { seen.push({ url, auth: init.headers.Authorization, beta: init.headers['anthropic-beta'] });
    return { ok: true, status: 200, json: async () => ({ five_hour: { utilization: 12.5, resets_at: '2026-09-17T10:00:00+00:00' }, seven_day: { utilization: 80, resets_at: '2026-09-21T16:00:00+00:00' } }) }; };
  const u = await usage(h, fetchOk);
  assert.deepEqual(u, { status: 'ok', five_hour: { utilization: 12.5, resets_at: '2026-09-17T10:00:00+00:00' }, seven_day: { utilization: 80, resets_at: '2026-09-21T16:00:00+00:00' }, subscription: 'max' });
  assert.equal(seen[0].auth, `Bearer ${ACCESS}`); assert.equal(seen[0].beta, 'oauth-2025-04-20');
  assertNoSecret(u);
  assert.deepEqual(await usage(h, async () => ({ ok: false, status: 401 })), { status: 'read-failed', http: 401 });
  assert.deepEqual(await usage(h, async () => { throw new Error('ECONNREFUSED'); }), { status: 'read-failed' });
  assert.deepEqual(await usage(h, async () => ({ ok: true, status: 200, json: async () => { throw new Error('bad json'); } })), { status: 'unreadable' });
  fs.unlinkSync(path.join(h, '.claude', '.credentials.json'));
  assert.deepEqual(await usage(h, fetchOk), { status: 'no-credentials' });
});

test('keys: names and twelve-digit fingerprints, never a value; an absent key says so', () => {
  const h = home();
  const k = keys(h);
  assert.deepEqual(k.map(x => x.name), KEY_NAMES);
  const or = k.find(x => x.name === 'OPENROUTER_API_KEY');
  assert.equal(or.present, true);
  assert.equal(or.sha256_12, crypto.createHash('sha256').update(SECRETS.OPENROUTER_API_KEY).digest('hex').slice(0, 12));
  assert.deepEqual(k.find(x => x.name === 'OPENAI_API_KEY'), { name: 'OPENAI_API_KEY', present: false });
  assertNoSecret(k);
  assert.deepEqual(keys('/nonexistent').map(x => x.present), [false, false, false, false, false, false]);
});

test('fabric: head, branch, behind, dirty, through a fake git; a fetch that fails is said', async () => {
  const calls = [];
  const exec = (cmd, args) => { calls.push(args.slice(2).join(' '));
    const a = args.slice(2).join(' ');
    if (a.startsWith('rev-parse --short')) return 'abc1234\n';
    if (a.startsWith('rev-parse --abbrev-ref')) return 'main\n';
    if (a.startsWith('status')) return '';
    if (a.startsWith('fetch')) throw new Error('offline');
    if (a.startsWith('rev-list')) return '3\n';
    return ''; };
  assert.deepEqual(await fabric('/some/root', exec), { status: 'ok', root: '/some/root', head: 'abc1234', branch: 'main', dirty: false, fetch: 'failed', behind: 3 });
  assert.equal((await fabric('/no/checkout', () => { throw new Error('not a git repository'); })).status, 'not-a-checkout');
  const asyncExec = async (...a) => ({ stdout: exec(...a) });   // the real execFile shape
  assert.equal((await fabric('/some/root', asyncExec)).head, 'abc1234');
});

test('script: letters by script, thinking and text apart, from the account\'s own session records; nothing of the text leaves', () => {
  assert.deepEqual(scriptCounts('Hello, world! 123'), { latin: 10 });
  assert.deepEqual(scriptCounts('გამარჯობა hello'), { georgian: 9, latin: 5 });
  assert.deepEqual(scriptCounts('привет'), { cyrillic: 6 });
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'script-home-'));
  const dir = path.join(h, '.claude', 'projects', '-home-x-projects-demo'); fs.mkdirSync(dir, { recursive: true });
  const turn = (thinking, text) => JSON.stringify({ type: 'assistant', message: { content: [{ type: 'thinking', thinking }, { type: 'text', text }] } });
  const lines = [turn('I think in English about this', 'გამარჯობა — the answer in Georgian, then its rendering'), turn('ვფიქრობ ქართულად', 'ok'),
                 JSON.stringify({ type: 'user', message: { content: 'ignored' } }), 'not json'];
  fs.writeFileSync(path.join(dir, 'live.jsonl'), lines.join('\n') + '\n');
  const old = path.join(dir, 'old.jsonl'); fs.writeFileSync(old, turn('ძველი', 'old') + '\n');
  const past = new Date(Date.now() - 48 * 3600000); fs.utimesSync(old, past, past);
  const s = script(h);
  assert.equal(s.status, 'ok'); assert.equal(s.files, 1, 'a record older than the window is not read'); assert.equal(s.turns, 2);
  assert.equal(s.thinking.letters, 24 + 15); assert.ok(s.thinking.latin > s.thinking.georgian, JSON.stringify(s));
  assert.ok(s.text.georgian > 0 && s.text.latin > 0);
  assert.deepEqual(s.thinking_blocks, { only: 0, mixed: 0, latin: 1, empty: 1 }, 'the English block is latin; the short Georgian one is under the 20-letter floor');
  fs.appendFileSync(path.join(dir, 'live.jsonl'), turn('ვფიქრობ ქართულად და ვწერ ქართულად, ეს ბლოკი მხოლოდ ქართულია', 'x') + '\n' + turn('ნახევარი ქართული ნახევარი and half of it English text', 'x') + '\n');
  assert.deepEqual(script(h).thinking_blocks, { only: 1, mixed: 1, latin: 1, empty: 1 });
  assert.ok(!JSON.stringify(s).includes('answer'), 'no text leaves, only counts');
  assert.equal(script(h, { hours: 72 }).files, 2);
  assert.equal(script('/nonexistent').status, 'no-records');
  // The notes: the signature the holder controls, one file a day in the locale, paragraphs binned.
  assert.equal(s.notes.status, 'none');
  const nd = path.join(h, 'state', 'agent-fabric', 'agents', 'ge', 'notes'); fs.mkdirSync(nd, { recursive: true });
  fs.writeFileSync(path.join(nd, '2026-09-17.md'), 'მოთხოვნა: გადათარგმნილი მოთხოვნა ქართულად, სრული აბზაცი.\n\nჩემი მსჯელობა ქართულად: ეს ტექსტი მხოლოდ ქართულია და საკმაოდ გრძელი.\n\nA paragraph written in English, long enough to count as a block here.\n');
  const fakeLang = paras => ({ status: 'ok', paragraphs: paras.length, unreliable: 0, shares: { ka: 100 }, dominant: { ka: paras.length } });
  assert.equal(script(h, { notes: nd }).notes.language.status, 'unavailable', 'no venv on this scratch home: said, not guessed');
  const withNotes = script(h, { notes: nd, langid: fakeLang });
  assert.deepEqual(withNotes.notes.language, { status: 'ok', paragraphs: 3, unreliable: 0, shares: { ka: 100 }, dominant: { ka: 3 } }, 'every note paragraph reaches the detector');
  assert.equal(withNotes.notes.status, 'ok'); assert.equal(withNotes.notes.files, 1);
  assert.deepEqual(withNotes.notes.blocks, { only: 2, mixed: 0, latin: 1, empty: 0 }, JSON.stringify(withNotes.notes));
  assert.ok(withNotes.notes.georgian > withNotes.notes.latin);
  assert.ok(!JSON.stringify(withNotes).includes('მოთხოვნა'), 'no note text leaves');
  assert.equal(notesDir('/h', { XDG_STATE_HOME: '/st' }, 'ge'), '/st/agent-fabric/agents/ge/notes');
  assert.equal(notesDir('/h', {}, 'ge'), '/h/.local/state/agent-fabric/agents/ge/notes');
  // The workers: the subagent transcripts beside the session whose sidecar names the locale worker; its USER records the input.
  assert.deepEqual(s.workers, { status: 'none', other_subagents: 0 });
  const sub = path.join(dir, 'live', 'subagents'); fs.mkdirSync(sub, { recursive: true });
  const user = c => JSON.stringify({ type: 'user', message: { role: 'user', content: c } });
  const meta = (name, agentType) => fs.writeFileSync(path.join(sub, `${name}.meta.json`), JSON.stringify({ agentType, model: 'opus' }));
  const handback = JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 't', name: 'SubagentHandback', input: {} }] } });
  const worker = [user('თხოვნა: გადახედე ამ ტექსტს და უპასუხე ქართულად, სრული აბზაცი აქ.'),
                  turn('', 'პასუხი ქართულად, საკმაოდ გრძელი აბზაცი რომ დაითვალოს ბლოკად.'),
                  user([{ type: 'text', text: 'მეორე თხოვნა ქართულად, ისევ საკმაოდ გრძელი აბზაცი, სამოცამდე ასო.' }]),
                  user('<system-reminder>\nYour final report is delivered through SubagentHandback; a plain final message is NOT delivered. Call it now.\n</system-reminder>'),
                  JSON.stringify({ type: 'attachment', attachment: { type: 'x' } }),
                  turn('', 'მეორე პასუხი ქართულად, საკმაოდ გრძელი ტექსტი აქაც.'), handback];
  fs.writeFileSync(path.join(sub, 'agent-aaa.jsonl'), worker.join('\n') + '\n'); meta('agent-aaa', 'locale-worker');
  const reviewer = [user('Repository: /x. Review the range a..b'), JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 't', name: 'Read', input: {} }] } }), turn('', 'Findings: none.'), handback];
  fs.writeFileSync(path.join(sub, 'agent-bbb.jsonl'), reviewer.join('\n') + '\n'); meta('agent-bbb', 'code-review');
  fs.writeFileSync(path.join(sub, 'agent-nometa.jsonl'), user('a subagent with no sidecar, long enough to be a block') + '\n');
  const w = script(h, { langid: fakeLang }).workers;
  assert.equal(w.input.language.paragraphs, 2); assert.equal(w.text.language.paragraphs, 2);
  assert.equal(w.status, 'ok'); assert.equal(w.files, 1, 'only the sidecar that says locale-worker'); assert.equal(w.other_subagents, 2); assert.equal(w.turns, 3);
  assert.equal(w.tool_uses, 0, 'the hand-back is not a tool use of the worker');
  assert.deepEqual(w.input.blocks, { only: 2, mixed: 0, latin: 0, empty: 0 }, `the injected reminder is not the bridge's input: ${JSON.stringify(w.input)}`);
  assert.deepEqual(w.text.blocks, { only: 2, mixed: 0, latin: 0, empty: 0 });
  assert.equal(w.input.georgian, 100); assert.ok(w.input.letters > 0);
  assert.ok(!JSON.stringify(w).includes('თხოვნა'), 'no worker text leaves');
  // English reaching the worker is counted in the INPUT bins, from the user records — not from the answers; a real tool use is counted.
  fs.appendFileSync(path.join(sub, 'agent-aaa.jsonl'), user('A paragraph of English that the bridge let through to the worker.') + '\n' + JSON.stringify({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'u', name: 'TaskStop', input: {} }] } }) + '\n' + turn('', 'მოკლე პასუხი ქართულად, საკმაოდ გრძელი რომ ბლოკი გამოვიდეს.') + '\n');
  const leak = script(h).workers;
  assert.deepEqual(leak.input.blocks, { only: 2, mixed: 0, latin: 1, empty: 0 }, 'the leak is one latin input block');
  assert.deepEqual(leak.text.blocks, { only: 3, mixed: 0, latin: 0, empty: 0 }, 'the answers stay Georgian');
  assert.equal(leak.tool_uses, 1);
  const stale = path.join(sub, 'agent-ccc.jsonl'); fs.writeFileSync(stale, user('old English input, long enough to be a block') + '\n'); meta('agent-ccc', 'locale-worker'); fs.utimesSync(stale, past, past);
  assert.equal(script(h).workers.files, 1, 'a worker transcript older than the window is not read');
  assert.deepEqual(workerTranscripts([{ f: '/nonexistent/s.jsonl' }]), { status: 'none', other_subagents: 0 });
});

// The drain over the control plane: the account's own memory directories,
// each matched to the working copy it was written from, harvested by the
// account's own harvester and answered as a gzipped bundle in relay-sized
// parts with the report beside it. Nothing of a memory's text is in the
// reply but the bundle itself.
test('memoryDirs: every memory directory with a memory in it, matched to ~/projects/<wc> by slug; MEMORY.md alone is nothing', () => {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'mem-home-'));
  const wc = path.join(h, 'projects', 'gzapp'); fs.mkdirSync(wc, { recursive: true });
  const dotted = path.join(h, 'projects', 'gzapi.ge'); fs.mkdirSync(dotted, { recursive: true });
  fs.mkdirSync(path.join(h, 'projects', 'agent-fabric'), { recursive: true });
  fs.writeFileSync(path.join(h, 'projects', 'notes.txt'), 'not a working copy');
  const mem = slug => { const d = path.join(h, '.claude', 'projects', slug, 'memory'); fs.mkdirSync(d, { recursive: true }); return d; };
  fs.writeFileSync(path.join(mem(memorySlug(wc)), 'fact.md'), '---\nname: fact\n---\nx');
  fs.writeFileSync(path.join(mem(memorySlug(wc)), 'MEMORY.md'), '- index');
  fs.writeFileSync(path.join(mem('-home-elsewhere-old-checkout'), 'stray.md'), 'x');
  fs.writeFileSync(path.join(mem(memorySlug(dotted)), 'brand.md'), 'x');
  fs.writeFileSync(path.join(mem(memorySlug(path.join(h, 'projects', 'agent-fabric'))), 'MEMORY.md'), '- only the index');
  fs.mkdirSync(path.join(h, '.claude', 'projects', '-no-memory-dir'), { recursive: true });
  const ds = memoryDirs(h).sort((a, b) => a.slug.localeCompare(b.slug));
  assert.deepEqual(ds, [
    { slug: '-home-elsewhere-old-checkout', memory: path.join(h, '.claude', 'projects', '-home-elsewhere-old-checkout', 'memory'), files: 1, working_copy: null },
    { slug: memorySlug(dotted), memory: path.join(h, '.claude', 'projects', memorySlug(dotted), 'memory'), files: 1, working_copy: dotted },
    { slug: memorySlug(wc), memory: path.join(h, '.claude', 'projects', memorySlug(wc), 'memory'), files: 1, working_copy: wc },
  ]);
  assert.ok(memorySlug(dotted).endsWith('-projects-gzapi-ge'), 'the dotted copy is matched under the harness\'s spelling');
  assert.deepEqual(memoryDirs('/nonexistent'), []);
  fs.mkdirSync(path.join(h, 'projects', 'gzapi-ge'), { recursive: true });   // the same slug as gzapi.ge
  const amb = memoryDirs(h).find(d => d.slug === memorySlug(dotted));
  assert.deepEqual({ wc: amb.working_copy, ambiguous: amb.ambiguous }, { wc: null, ambiguous: true }, 'two working copies with one slug: neither is guessed');
  assert.equal(memorySlug('/home/x/projects/gzapp'), '-home-x-projects-gzapp');
  assert.equal(memorySlug('/home/x/projects/gzapp.decks'), '-home-x-projects-gzapp-decks', 'a dot is a dash too, as the harness names it');
  assert.equal(memorySlug('/home/x/.claude-mem'), '-home-x--claude-mem');
});

test('memory: one harvester run per directory — the tar from stdout, the report from stderr — gzipped, base64, in parts; a failure and a strayed directory are rows, not throws', async () => {
  const tar = crypto.randomBytes(3000);   // incompressible: the parts are real
  const report = { role: 'db-admin', claims: 2, counts: { in_scope: 3, total: 3 }, needs_rendering: ['ka-note'], skipped_no_roles_class: ['private'], memory_dir: '/never/leaves' };
  const calls = [];
  const exec = async (cmd, args, opts) => { calls.push({ cmd, args, opts });
    if (args.includes('/m/broken')) throw Object.assign(new Error('exit 1'), { stderr: 'harvest_memory: refusing rather than guessing where these belong:\n  private-secret.md' });
    return { stdout: tar, stderr: Buffer.from(JSON.stringify(report)) }; };
  const dirs = [{ slug: 's-gzapp', memory: '/m/gzapp', files: 3, working_copy: '/home/x/projects/gzapp' },
                { slug: 's-stray', memory: '/m/stray', files: 1, working_copy: null },
                { slug: 's-broken', memory: '/m/broken', files: 1, working_copy: '/home/x/projects/broken' }];
  const m = await memory('/home/x', { root: '/r', exec, dirs, all: true, partBytes: 1000 });
  assert.equal(m.status, 'ok'); assert.equal(m.bundles.length, 3);
  const [ok, stray, broken] = m.bundles;
  assert.equal(ok.status, 'ok'); assert.equal(ok.bytes, 3000); assert.equal(ok.sha256, crypto.createHash('sha256').update(tar).digest('hex'));
  assert.ok(ok.parts >= 4 && ok._parts.length === ok.parts, `${ok.parts} parts of 1000 chars for ~4 KB of base64`);
  assert.ok(ok._parts.every((p, i) => p.length === 1000 || i === ok._parts.length - 1));
  assert.deepEqual(zlib.gunzipSync(Buffer.from(ok._parts.join(''), 'base64')), tar, 'the parts reassemble to the tar');
  assert.deepEqual(ok.report, { claims: 2, counts: { in_scope: 3, total: 3 }, needs_rendering: ['ka-note'], skipped_no_roles_class: ['private'] });
  assert.ok(!('memory_dir' in ok.report), 'only the whitelisted report keys travel');
  assert.deepEqual(stray, { slug: 's-stray', files: 1, status: 'no-working-copy' });
  assert.equal(broken.status, 'harvest-failed'); assert.match(broken.error, /refusing rather than guessing/);
  assert.equal(calls.length, 2, 'one run per harvestable directory, none for the stray');
  assert.equal(calls[0].cmd, 'python3'); assert.equal(calls[0].args[0], '/r/tools/fabric/harvest_memory.py');
  assert.deepEqual(calls[0].args.slice(1), ['--bundle', '-', '--memory', '/m/gzapp', '--working-copy', '/home/x/projects/gzapp', '--all']);
  assert.equal(calls[0].opts.env.AGENT_FABRIC_ROOT, '/r');
  const noAll = []; await memory('/home/x', { root: '/r', exec: async (c, a) => { noAll.push(a); return { stdout: tar, stderr: 'not json' }; }, dirs: [dirs[0]] });
  assert.ok(!noAll[0].includes('--all'), 'the watermark applies unless asked'); 
  assert.equal(MEMORY_PART_BYTES, 90 * 1024, 'under the relay\'s 128 KiB message limit with the envelope');
  const whole = await memory('/home/x', { root: '/r', exec, dirs: [dirs[0]] });
  assert.equal(whole.bundles[0].parts, 1, 'a 3 KB tar is one part at the real size');
});

test('languages: CLD2 judges only paragraphs of twenty letters; shares weighted by letters, dominant per paragraph, unreliable counted; no venv is unavailable', () => {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'lang-home-'));
  assert.equal(languages(['ქართული აბზაცი საკმაოდ გრძელი'], { home: h }).status, 'unavailable');
  const venvPy = langidCmd(h, '/r')[0]; fs.mkdirSync(path.dirname(venvPy), { recursive: true }); fs.writeFileSync(venvPy, '');
  assert.equal(langidCmd(h, '/r')[1], '/r/runtime/langid/langid.py');
  const seen = [];
  const paras = ['ქართული აბზაცი, საკმაოდ გრძელი რომ განისაჯოს', 'An English paragraph long enough to be judged here', 'ops.mjs:294 memory() exec harvest --bundle -', 'ნახევარი ქართული ნახევარი and half of it English text', 'ok'];
  const exec = (cmd, args, opts) => { seen.push({ cmd, args, input: JSON.parse(opts.input) }); return JSON.stringify([[true, 90, [['ka', 100]]], [true, 50, [['en', 98]]], [false, 40, []], [true, 60, [['ka', 56], ['en', 43]]]]); };
  const l = languages(paras, { home: h, root: '/r', exec });
  assert.equal(l.status, 'ok'); assert.equal(l.paragraphs, 4); assert.equal(l.unreliable, 1);
  assert.deepEqual(l.dominant, { ka: 2, en: 1 });
  assert.ok(l.shares.ka > l.shares.en && l.shares.ka + l.shares.en > 95 && l.shares.ka + l.shares.en <= 100, JSON.stringify(l.shares));
  assert.deepEqual(Object.keys(l.shares), ['ka', 'en'], 'sorted by share');
  assert.equal(seen[0].cmd, venvPy); assert.deepEqual(seen[0].args, ['/r/runtime/langid/langid.py']); assert.equal(seen[0].input.length, 4, 'the two-letter answer is not sent');
  assert.deepEqual(languages([], { home: h, root: '/r', exec }), { status: 'ok', paragraphs: 0, unreliable: 0, shares: {}, dominant: {} });
  assert.equal(languages([paras[1]], { home: h, root: '/r', exec: () => { throw Object.assign(new Error('x'), { stderr: 'langid: no pycld2 in this interpreter (runtime/langid/install.sh)\n' }); } }).why, 'langid: no pycld2 in this interpreter (runtime/langid/install.sh)');
  assert.equal(languages([paras[1]], { home: h, root: '/r', exec: () => 'nope' }).status, 'unavailable');
  assert.equal(languages([paras[1]], { home: h, root: '/r', exec: () => '[]' }).status, 'unavailable', 'a verdict count that does not match is not read');
});

test('session: counts the harness processes of the uid; none is zero, not a throw', () => {
  const s = session(4242, (cmd, args) => { assert.deepEqual(args, ['-u', '4242', '-x', 'claude']); return '111\n222\n'; });
  assert.equal(s.claude_processes, 2); assert.equal(typeof s.planning, 'boolean');
  assert.equal(session(4242, () => { throw Object.assign(new Error('no match'), { status: 1 }); }).claude_processes, 0);
});

test('tokens: per model from the login\'s own records — deduplicated by request, in the window by timestamp, direct and broker apart, subagents counted, synthetic dropped; nothing of the text leaves', async () => {
  const h = home();
  const now = Date.parse('2026-09-19T12:00:00Z');
  const day = 86400000;
  const proj = path.join(h, '.claude', 'projects', '-home-x-projects-gzapp');
  const sub = path.join(proj, 's1', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  const rec = (ts, model, u, extra = {}) => JSON.stringify({ type: 'assistant', timestamp: new Date(ts).toISOString(), requestId: extra.req, message: { id: extra.id ?? 'm-' + Math.random(), model, usage: u, content: [{ type: 'text', text: 'SECRET-TEXT-NEVER-COUNTED' }] } }) + '\n';
  const u1 = { input_tokens: 10, cache_creation_input_tokens: 100, cache_read_input_tokens: 1000, output_tokens: 20 };
  fs.writeFileSync(path.join(proj, 's1.jsonl'),
    rec(now - day, 'claude-opus-5', u1, { req: 'r1' }) +
    rec(now - day, 'claude-opus-5', u1, { req: 'r1' }) +          // the same request, one record per content block
    rec(now - 2 * day, 'z-ai/glm-5.3', { input_tokens: 500, output_tokens: 5 }, { req: 'r2' }) +
    rec(now - 30 * day, 'claude-opus-5', u1, { req: 'r-old' }) +   // outside the window by its own timestamp
    rec(now - day, '<synthetic>', { input_tokens: 0, output_tokens: 0 }, { req: 'r-syn' }) +
    JSON.stringify({ type: 'user', message: { content: 'hi' } }) + '\nnot json\n');
  fs.writeFileSync(path.join(sub, 'agent-a1.jsonl'), rec(now - day, 'claude-sonnet-5', { input_tokens: 1, cache_read_input_tokens: 50, output_tokens: 7 }, { id: 'msg-sub' }));
  const stale = path.join(proj, 'old.jsonl');
  fs.writeFileSync(stale, rec(now - day, 'claude-opus-5', u1, { req: 'r-stale' }));
  fs.utimesSync(stale, new Date(now - 40 * day), new Date(now - 40 * day));   // a file older than the window is not read
  const t = tokens(h, { now });
  assert.equal(t.status, 'ok');
  assert.equal(t.days, 7);
  assert.deepEqual(t.requests, { session: 2, subagent: 1 });
  assert.deepEqual(Object.keys(t.models), ['z-ai/glm-5.3', 'claude-opus-5', 'claude-sonnet-5'], 'ordered by equivalents (525, 335, 41), synthetic absent');
  assert.deepEqual(t.models['claude-opus-5'], { requests: 1, input: 10, cache_write: 100, cache_read: 1000, output: 20, equiv: 335, path: 'claude' });
  assert.equal(equivalent({ input: 10, cache_write: 100, cache_read: 1000, output: 20 }), 10 + 125 + 100 + 100);
  assert.deepEqual(t.models['z-ai/glm-5.3'], { requests: 1, input: 500, cache_write: 0, cache_read: 0, output: 5, equiv: 525, path: 'broker' });
  assert.deepEqual(t.claude, { requests: 2, input: 11, cache_write: 100, cache_read: 1050, output: 27, equiv: 335 + 41 });
  assert.deepEqual(t.broker, { requests: 1, input: 500, cache_write: 0, cache_read: 0, output: 5, equiv: 525 });
  assert.equal(t.ratios, TOKEN_RATIOS);
  assert.equal(t.first, new Date(now - 2 * day).toISOString()); assert.equal(t.last, new Date(now - day).toISOString());
  assert.ok(!JSON.stringify(t).includes('SECRET-TEXT'), 'counts only');
  assert.equal(tokens(h, { now, days: 0.5 }).status, 'no-records', 'a narrower window with nothing in it says so');
  assert.equal(tokens(fs.mkdtempSync(path.join(os.tmpdir(), 'ctl-empty-'))).status, 'no-records');
  const c = await collect('tokens', { home: h, who, days: 3 });
  assert.deepEqual(Object.keys(c).sort(), ['identity', 'tokens'], 'tokens rides with identity, so the coordinator can group by Claude account');
  assert.equal(c.tokens.days, 3);
});

test('collect: status is every section, a single op its own, and a failing section is inline', async () => {
  const h = home();
  const ctx = { home: h, who, fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }), root: '/r', exec: () => { throw new Error('boom'); }, uid: 1 };
  const all = await collect('status', ctx);
  assert.deepEqual(Object.keys(all).sort(), ['fabric', 'identity', 'keys', 'session', 'usage']);
  assert.equal(all.fabric.status, 'not-a-checkout');
  assert.equal(all.session.claude_processes, 0);
  assertNoSecret(all);
  const one = await collect('keys', ctx);
  assert.deepEqual(Object.keys(one), ['keys']);
  assert.ok(OPS.includes('ping') && OPS.includes('status') && OPS.includes('memory'));
  assert.ok(!('memory' in all), 'a drain is asked for, never part of status');
  const mem = await collect('memory', { home: h, exec: () => { throw new Error('never runs'); } });
  assert.deepEqual(mem, { memory: { status: 'ok', bundles: [] } }, 'a home with no memory answers an empty drain');
});
