# The language-culture bridge

*2026-09-17. What changed in meaning: "a holder thinks in the language
it answers for" stopped being a disposition the holder is asked for and
became a construction the fabric installs, measures and drains through.*

## Why a structural answer

The CEO's rule for the `language-culture` role is that its holder
reasons in the locale it is named for, because a translation judged in
English is judged wrong. Two days of trying to *ask* for that showed
the harness cannot even see whether it happens: thinking blocks are
stored empty or as short summaries (a session with a hundred thousand
thinking tokens had none on disk), so the only artifact of the rule is
what the holder writes by rule — the notes, one file a day in the
locale, counted by script (`48dc399`, `0b384a8`). The notes prove the
order and shape of what a holder wrote. They do not prove what it
reasoned in.

The construction that forces it is the CEO's: **a worker that never
sees English**, and the holder in front of it as a **bridge**.

## What the worker sees

`identities/roles/language-culture/locale/<suffix>/worker.md` is a
Claude Code agent file — `name: locale-worker`, a one-line description
in the locale carrying the `agent-fabric` marker, a model alias, and
**one inert tool** (`tools: TaskStop`) — whose body is the locale. Not
none: read back on 2026-09-17, an empty `tools:` line inherits every
tool, and the harness refuses to spawn an agent whose list resolves to
none ("would be spawned with zero tools — refusing"); `TaskStop` stops a
background task the worker never has and returns nothing to read. The
live check has the four probes. The description never reaches
the worker (the body is its system prompt); its reader is the
dispatcher's agent listing, and the dispatcher is the holder, who
reasons in the locale — so the description is in the locale too, the
name and the marker kept as identifiers (the CEO, 2026-09-17; the first
draft had it in English). `install-agent-files.sh`
installs it as `~/.claude/agents/locale-worker.md` on a login whose
bound role is `language-culture` and whose suffix has a `locale/`
directory, and removes it from any other login (the `blind-reviewer.md`
removal pattern), so the type exists only where the bridge does
(`91baac0`). The dispatch guard has a branch for the shape: a model
required, isolation refused (it writes nothing), any alias without an
ask — language judgement is premium by design (`33fcd08`).

Inside its context the worker meets: its system prompt (the locale),
the text the bridge sent it (the locale, if the bridge did its job),
and the harness's own residue — the base prompt it wraps around any
subagent and the hand-back reminder. That residue is stated in the
charter, not hidden: the construction removes every English the fabric
controls, and names the English it does not.

## What the bridge does

The holder session is the bridge. A request arrives in any language;
the holder translates it into the locale (already its rule), dispatches
`locale-worker` with the locale text alone, takes the locale answer,
and renders it — the same text rendered, never a second composition,
which is the charter's existing rule for every answer. The worker
composes; the bridge carries.

The control plane reads the seam. `fabric-ctl <login> script` gained a
`workers` column (`37bc6a5`): the subagent transcripts stored beside
each session (`<session>/subagents/agent-*.jsonl`) whose sidecar
(`agent-*.meta.json`, written by the harness) says `agentType:
locale-worker`, with their user records counted as the worker's
**input** — less the `<system-reminder>` spans the harness injects into
every subagent, which are English and not the bridge's — and their text
blocks as its answers, per paragraph, by script; a `tool_use` other than
the hand-back is counted as `tool_uses`. A Latin paragraph in the input
is English that reached the worker: the bridge leaked. Counts only; no
text leaves the account. (The first cut identified the worker as "the
transcript with no `tool_use` block"; the blind review showed the
hand-back itself is one, `SubagentHandback`.)

## The charter and the memory

The charter the holder is launched with is the locale's translation:
`locale/<suffix>/charter.md`, a charter slice naming the English source
and its digest, rendered by `launch_prompt.py` for a login ending in
the suffix (`28c40bd`); lint validates it and reports the lag when the
English has moved past the digest (`4b505cd`). A stale translation is
served rather than failing a launch; the holder, the locale's expert,
keeps it in step through a pull request fabric-coordinator merges.

The holder's memory is written in the locale. A memory meant for the
fleet carries its rendering under `## English`; the harvester takes the
rendering as the claim, records the language in the provenance, and
names a non-Latin memory without one under `needs_rendering` in every
report until the holder renders it (`fdbfdac`). Nothing renders a
memory but its holder.

## The drain

The memory is asked for over the control plane, not read through sudo
(`b0f9b56`, the way out of god mode): `fabric-ctl all memory --out
<dir>` has every account's own daemon harvest its own memory and answer
with the bundles in relay-sized parts and the report beside them. For
a language-culture login the table is the dry run: the
`needs_rendering` names go to the holder as a `REQUEST` on the relay,
the holder renders them and answers with the count, and the next run
takes the claims. `memory/README.md` has the cycle.

## Search in the locale

A holder must search as a reader of its locale would. The harness's
`WebSearch` cannot: read back on 2026-09-17, its schema is `query`,
`allowed_domains`, `blocked_domains` and nothing else, its description
says US-only, and Anthropic's `user_location` lives on the Messages API
only. So a language-culture login gets `runtime/mcp/websearch-locale`,
an MCP server with one tool per engine its locale file configures
(`locale/<suffix>/locale.json`, lint validates it; the CEO: keep both
engines):

- `web_search` — Google's Custom Search JSON API with `gl`, `hl` and
  `lr` fixed from the file: the locale as a browser there would have it
  (`ge`: `gl=ge`, `hl=ka`, `lr=lang_ka`). Secrets `GOOGLE_CSE_API_KEY`
  (one request header) and `GOOGLE_CSE_CX`, the Programmable Search
  Engine id — an engine over the whole web, made by the CEO.
- `web_search_global` — Brave's Search API as a second index, `country`
  from the file and a language only where Brave has it. Brave has no
  Georgian locale (`country=GE`, `search_lang=ka`, `ui_lang=ka-GE` each
  refused with 422, read back 2026-09-17), so `ge` names `country:
  ALL`: a global search steered by the language of the query, which a
  Georgian query does steer (three of five results `ka`). Secret
  `BRAVE_SEARCH_API_KEY`.

The holder chooses the query, never the locale; each tool's description
is in the locale, since its reader is the holder. `install-agent-files.sh`
writes the server into the login's user-scope configuration on a
language-culture login with a locale file and removes it from any
other, by the server path in its args. Every secret is a synced value
read at call time, never in a URL, a log line or a result; the keys'
fingerprints show in `fabric-ctl <login> keys`. The worker never sees
these tools: search is the bridge's.

## The costs, stated

- **Tokens.** A locale render of the charter is allowed 1.35× the
  launch prompt's character ceiling, and the real cost is higher than
  the characters say: measured, Georgian tokenizes at 1.46 characters a
  token against 4.1 for English — the charter is 2.9× its source, the
  whole launch prompt 2.0× (the shared sections stay English). The
  CEO's choice for this role; the live check records the counts.
- **The residue.** The harness's base prompt and hand-back reminder
  reach the worker in English. Named, not removed.
- **A second model call per request.** The bridge dispatches a worker
  for what it once did in one turn. The bridge's own turn is the
  translation and the rendering; the judgement is the worker's.
- **Only `ge` exists.** The construction is generic by login suffix;
  the payload for a second locale is a second `locale/<suffix>/`
  directory, reviewed by its holder.
