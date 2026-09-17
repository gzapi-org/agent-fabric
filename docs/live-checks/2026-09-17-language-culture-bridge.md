# The language-culture bridge, read back — 2026-09-17

`docs/language-culture-bridge.md` and the lint budget for a locale
charter rest on one measurement outside the fabric — what a Georgian
body costs in tokens — and on the read-backs below after the roll-out.
Measured on `develop-qzapp`, as login `user`, with the harness's own
`claude -p --model haiku --output-format json`.

## What a Georgian charter costs

The two bodies (frontmatter stripped) sent as a prompt after a fixed
preamble, against the preamble alone; the cost of a body is the
difference in total input (`input_tokens` + `cache_creation_input_tokens`
+ `cache_read_input_tokens`, since the harness caches its own prefix).

| body | characters | total input | body tokens | chars / token |
|---|---|---|---|---|
| preamble alone | — | 25 785 | — | — |
| `charter.md` (English, at `70fa2cb`) | 10 931 | 28 427 | 2 642 | 4.1 |
| `locale/ge/charter.md` (Georgian) | 11 041 | 33 369 | 7 584 | 1.46 |

- The rendering is the size of its source in characters (Georgian is
  compact: 1.01×) and **2.9× its tokens**. Decides: the character
  ceiling on a locale launch prompt needs little headroom
  (`launch_prompt.LOCALE_CHARS_FACTOR` stays 1.35); the token cost is
  the one the plan named ("~2–3×") and the CEO accepted for the role.
- The guess lint carried before the measurement — 2 characters a token
  and a ceiling of 1.35× the tier-1 budget (4 050 tokens) — was
  optimistic on the divisor and impossible on the ceiling: no full
  rendering of a 2 600-token charter fits 4 050 at any divisor.
  Decides: `NON_LATIN_CHARS_PER_TOKEN = 1.5`, `LOCALE_BUDGET_FACTOR = 3`
  (9 000 tokens); the first rendering lints at ~7 360.
- The launch prompt for `language-culture-ge` renders at 17 862
  characters with the English charter (ceiling 20 000) — the Georgian
  render is measured after the roll-out, below.

## After the roll-out (`2de43d3` on every account)

- `fabric-ctl all fabric`: 16 accounts, every head `2de43d3`, every
  daemon restarted on the pull (uptimes 2–54 s). Decides: a pull is the
  distribution; nothing else needs a hand.
- **The drain over the control plane.** `fabric-ctl all memory --out
  <dir>`: 3.1 s for the fleet; 16 bundles written and every one opened
  by `assemble.open_bundle` with its manifest digests verified — the
  first drain that read no home but the account's own. Two rows were
  not bundles, and both are named, not lost: `backend-dev-02`
  `harvest-failed` (one memory with `roles_class: backend-dev`, a role
  rather than a class; the harvester refuses the whole drain by design —
  an OBSERVATION to that role), and, on the first run, every dotted
  working copy (`gzapi.ge`, `gzapp.decks`) as `no-working-copy`: the
  harness spells a launch directory with every non-alphanumeric
  character as `-`, and both slug derivations mapped `/` alone. Fixed in
  `2de43d3`; the second run bundled them (brand-comms-01: 8 claims).
- **The installer.** `install-agent-files.sh --dry-run` as
  `language-culture-ge`: `+ ~/.claude/agents/locale-worker.md (would
  write)`; as `db-admin`: no mention. The launcher writes it at the
  holder's next launch.
- **The launch prompt.** `launch_prompt.py --print` as
  `language-culture-ge`: 17 972 characters (ceiling 27 000), the charter
  section is `# language-culture — ქარტია`; measured as above, the whole
  prompt is **9 387 tokens** against 4 609 for fabric-coordinator's
  English one of 18 275 characters — 2.0× overall, the charter's 2.9×
  diluted by the shared sections, which stay English.
- Not yet read back: a live `locale-worker` dispatch under the guard,
  and `fabric-ctl language-culture-ge script` with a `workers` column —
  both need the holder's next launch; asked of it in the review REQUEST.

## What "no tools" means on this harness (after the blind review)

The review's one unproven risk — does an empty `tools:` line mean no
tools? — settled by four probes: a throwaway agent file on this login,
dispatched from a fresh headless session (`claude -p --model haiku`,
each dispatch on `haiku` with a worktree), asked to run `id -un` and
read a file and to list its tools.

| frontmatter | result |
|---|---|
| `tools:` (empty) | spawned with **every** tool: `bash`, `read_file`; `id -un` → `user` |
| `tools: []` | the same |
| `tools: none` | refused: "would be spawned with zero tools — refusing. Its tools list resolved to nothing: unrecognized [none]" |
| `disallowedTools: <17 names>` | spawned with what the list missed: `EnterWorktree`, `ExitWorktree`, `Monitor`, `SendMessage`, the MCP tools |
| `tools: TodoWrite` | refused: unrecognized — not a tool of this harness |
| `tools: ExitWorktree` | spawned with that one tool; could run nothing, read nothing |
| `tools: TaskStop` | spawned with that one tool; could run nothing, read nothing |

- Decides: the worker carries `tools: TaskStop` — one tool that stops a
  background task it never has and returns nothing to read — and lint
  requires exactly that; the charter, the Georgian charter and the
  docs say "one tool that reads and writes nothing" where they said
  "no tools".
- The sidecar `agent-<id>.meta.json` beside each subagent transcript
  carries `agentType` (seen: `code-review`, `claude-code-guide`, the
  probes) — the `workers` measure keys on it. Every transcript also
  carries the hand-back as a `tool_use` named `SubagentHandback` and an
  injected `<system-reminder>` user record in English; the measure
  ignores the first and strips the second.
- The review's P1 — a credential in a memory would have crossed the
  channel — was real: the harvester had no hygiene step (the comment
  claiming one was wrong). It now refuses the whole drain on a
  credential-shaped hit, before any claim is built.

## The language detector on this host (the CEO: fastText, then "look at CLD2 / pycld2")

fastText's `lid.176.ftz` was tried first (938 013 bytes, loads in
0.06 s, 2 000 predictions in 0.06 s): `ka` 0.81 on a Georgian note, `en`
0.96, `it` 0.95, `ru` 0.998 — but it is a single-label classifier: a
half-Georgian, half-English paragraph came back `ka 0.83`, the English
invisible, and a code line scored `en 0.38`, a bare `ok` `en 0.63`. The
CEO asked for CLD2 instead. `pycld2==0.42` builds from source on this
host (gcc/g++ present) and reads back:

| paragraph | CLD2 |
|---|---|
| a Georgian note line | reliable, `ka` 100 |
| an English paragraph | reliable, `en` 98 |
| an Italian paragraph | reliable, `it` 98 |
| a Russian paragraph | reliable, `ru` 99 |
| half Georgian, half English, with a path | reliable, **`ka` 56 / `en` 43** |
| a code line (`ops.mjs:294 memory() exec …`) | unreliable |
| `ok` | unreliable |
| Georgian in Latin letters | unreliable |

2 000 detections in 9 ms. Decides: the `language` section is CLD2's —
shares per language weighted by letters, the dominant language per
paragraph, the unreliable count — with no probability floor to tune; a
paragraph under twenty letters is not sent; the script shares stay for
Latin-letter Georgian, which neither detector reads. The binding needs
a C++ compiler where it is installed; without one the section says
`unavailable`.

## Brave has no Georgian locale

As `language-culture-ge`, with its own key: `country=GE`,
`search_lang=ka` and `ui_lang=ka-GE` are each refused with HTTP 422
("Unable to validate request parameter(s)"), together or alone;
`country=US&search_lang=en&ui_lang=en-US` answers 200. A Georgian query
with no locale parameter (or `country=ALL`) returns Georgian pages:
three of five results `ka`, on `.ge` hosts and `ka.wikipedia.org`.
With `country: ALL` and no language the `ge` tool answered a Georgian
query with Georgian results (madloba.info/ka, tbilisimetro.org) — a
global search steered by the query, less than the "Georgian browser"
asked for. Google's Custom Search JSON API was tried next and is
**closed to new customers** (its overview page, 2026-09-17; existing
customers until 2027-01-01; the full-web alternative is "contact us"),
so Google's index is reachable only through a SERP proxy. Decides:
Serper.dev (`gl=ge`, `hl=ka`) is the located `web_search`, and Brave
stays as `web_search_global`, a second index (the CEO: keep both).
