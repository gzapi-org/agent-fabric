# Roles

Per-role knowledge, mined from the development sessions that produced this
repository.

A session can *become* a role — `/role flutter-dev` — and get that role's
charter, its index of what it knows, its workflow, and its own skills and
commands. Everything else stays on disk until something calls for it.

## Why this exists

Sessions accumulate knowledge that the repository never records. The
decision records say what was decided and why; the code says what is; the
CLAUDE.md files say what the rules are. None of them hold the things that
were learned the hard way — that a green test suite here can be testing
nothing, that a queued branch refuses a push, that a bare permission error
from a container is really a stale security label. That knowledge lived
only in a memory store that grows without bound and is organised by session
rather than by subject.

So it gets drained: mined, judged against a fixed bar, filed by role and by
kind of truth, and committed. The memory store becomes a short-term buffer
that is periodically consolidated and cleared, rather than an ever-growing
archive nobody can read.

## Layout

Launching: the dual-path launcher lives at `tools/launch/ori` (its README
and the dual-path table at `tools/launch/README.md`); the profile registry
below is what it reads.
```
.roles/
├── README.md              this file
├── RUBRIC.md              what earns a place here, and what does not
├── PROVISIONING.md        standing a role up as its own account on the host
├── taxonomy.json          roles, path rules, attribution rules — as DATA
├── schema/                JSON Schemas for everything structured
├── registry/              who produced what: clones and their history
│   ├── clones.jsonl       one identity per working copy, minted once
│   ├── bindings.jsonl     append-only windows: host, directory, role, when
│   ├── model-profiles.json  which OpenRouter model each subagent tier
│   │                        resolves to on the ori launch path, per role and
│   │                        per instance; the opus tier is a policy allowlist
│   └── ...
├── .instance/             (gitignored, per clone) the active role's state
│                         (state.json) and the ori launcher's gitignored
│                         model-profile.local.json experiment layer
├── shared/                knowledge two or more roles own — stored once
├── <role>/
│   ├── charter.md         scope: what is yours, what is not          (tier 1)
│   ├── INDEX.md           generated map of everything below          (tier 1)
│   ├── workflow/          how work is actually done here             (tier 1)
│   ├── domain/            true of the field, regardless of us        (tier 2)
│   ├── solution/          what we implement today                    (tier 2)
│   ├── intersection/      where we follow the field, where we depart (tier 2)
│   ├── rationale/         reasoning not yet in a decision record     (tier 2)
│   ├── threads.md         known loose ends                           (tier 2)
│   ├── recall.md          how to ask the corpus about past episodes  (tier 2)
│   ├── crossref.json      artifact → where it was learned and landed
│   ├── skills/            installed into discovery by /role
│   └── commands/          installed into discovery by /role
└── .instance/             THIS working copy's state — gitignored
    ├── state.json         which role it is, what was installed, its identity
    ├── active -> ../<role>/
    └── stash/             copies rescued from a forced switch
```

**Everything under `<role>/` is a stateless template**, identical in every
clone. **Everything under `.instance/` says which of them this clone
currently is.** Keeping those apart structurally is what lets two sessions
run the same role at once without interfering — they are different working
copies holding the same template.

## Two tiers, and why

Activation loads three classes: charter, index, workflow. Everything else
waits for a cue.

**Workflow is a directory, and it is still tier 1** — the classes below it
are filed one slice per file and so is this one, but every workflow slice
declares `tier: 1` and the switcher lists all of them at activation. The
distinction is load time, not file shape: workflow is how work is *done*
here, so a session that has to be cued into it has already made the
mistake the slice exists to prevent. Naming it `workflow.md` in this file
once cost exactly that — the switcher's existence check never matched a
directory, so 28 tier-1 slices across nine roles loaded nowhere and
nothing said so.

The index is the mechanism. Each slice's frontmatter carries a one-line
description written as a retrieval cue, and the index is **generated** from
those lines — never hand-maintained, because a hand-written index drifts
from the files beside it and then quietly lies. A session reads the index,
recognises that knowledge exists, and opens the one slice that matches.

A role that loaded everything at activation would cost more than it saves.
That is the whole argument for the split.

## Six kinds of truth

Slices are filed by **epistemic class**, not by topic, because the classes
decay and verify differently and mixing them is how a knowledge base starts
lying:

| class | what it is | how it is checked | how fast it rots |
|---|---|---|---|
| `domain` | true of the field regardless of us | against the discipline | slowly |
| `solution` | what we implement today | against the tree | every merge |
| `intersection` | where we follow or depart, and why | against the decisions | when a decision changes |
| `rationale` | reasoning not yet in a decision record | against the record | until promoted |
| `workflow` | how work is actually done | by doing it | when tooling changes |
| `threads` | known loose ends | by closing them | continuously |

Two consequences worth stating plainly. **`solution` carries an as-of
date** and where it conflicts with the tree, the tree is the fact and the
drift is worth recording. **`rationale` is a staging area, not an
authority**: where it disagrees with an active decision record, the record
wins and the disagreement is a finding. Entries there that prove durable
get promoted into an actual decision record and deleted here — this file
set is supposed to shrink as knowledge graduates into governance.

## Who may change a role's definition

**A role's DEFINITION is changed by architect-cto, not by the role.** That
means `charter.md` — the tier-1 file that says what is yours and what is
not — and a role's entry in `taxonomy.json`. A session working as
`flutter-dev` proposes a charter change; it does not make one.

This is the same shape as gzcoord-coordinator holding sole authority over
`tools/gzcoord/protocol/*` (root CLAUDE.md §Agent communication): the
artefact that defines the boundary is not edited by the party the boundary
constrains.

Why it needs saying at all: every other file here is *generated* — the
assembler writes them and `lint.py` rejects a hand-edit, so scope cannot
drift by accident. `charter` and `recall` are the two classes lint exempts
from `derived_from` precisely because they are authored. That exemption is
what makes them the one place a session could quietly widen its own remit,
and it lints clean, because lint checks provenance and not authority.

**To propose a change**, open a PR touching only the charter, say what the
role is being asked to take on or give up, and leave it for architect-cto.
Do not self-approve it on the grounds that you are the only session that
understands the surface — that is the argument the rule exists to refuse.

`tools/checks/check_charter_authority.sh` makes a violation visible. Read
what it can and cannot do in its header: every session pushes as the same
GitHub account, so this is a tripwire keyed on the branch name, not a
fence. It stops the accident and the absent-minded edit. It does not stop
a session that means to route around it, and nothing available here would.

Some evidence comes from sibling projects. It can teach how a platform
behaves but says nothing about what we implement, so it is marked
`domain-only` and may support `domain` claims and nothing else. The sibling
project is never named.

## The drain cycle — DORMANT

**Nothing runs this today, and the corpus below is what it produced.** The
store it drained was claude-mem's, that plugin is gone, and
`~/.claude-mem/claude-mem.db` is an empty 4 KB file. `harvest.py` still
points at it, so a drain would find nothing.

That costs nothing, because the drain's OUTPUT is committed: 176 slices
across ten roles, 146 carrying `derived_from` provenance. `/role` loads
them exactly as before. What stopped is the growth, not the knowledge.

New durable knowledge goes to Claude's own per-account memory instead
(`~/.claude/projects/<slug>/memory/`), which is written deliberately, one
fact per file, with a `why` and a `how to apply` — the shape a slice wants,
without a transcript-scraping pipeline in between. A replacement observer
was written (`tools/roles/observe.py`) and is deliberately NOT wired: see
its module docstring for why turning it on was judged not worth the cost.

**The next drain reads memory, not a store.**
`tools/roles/harvest_memory.py` turns this account's memories into a claims
file the existing assembler consumes — no model pass, because a memory is
already a claim:

```sh
tools/roles/harvest_memory.py --role architect-cto --out /tmp/drain --dry-run
tools/roles/harvest_memory.py --role architect-cto --out /tmp/drain
tools/roles/assemble.py --claims /tmp/drain/claims --drain /tmp/drain \
    --out .roles --stamp $(date +%F)
```

The role payload sits in `claims/`, one level below the drain metadata:
the assembler reads every `.json` under `--claims` as a role payload, so
`references.json` beside it would be read as one.

Each account distils **its own** memories into this shared corpus; nothing
reads another account's home directory.

**Role knowledge is opt-in.** A memory reaches the corpus only if it carries
`roles_class` in its `metadata:` block — nothing is inferred from `type`.
That was the first design and it was wrong in three ways at once: a mapping
table, a special case to drop `user` memories, and a refusal for
unrecognised types, all answering one question. And `type` cannot answer it:
memory has four types, this corpus has nine classes, and `project` alone
covers both live threads and durable constraints. On this account's first
five memories the mapping mis-filed two of three.

A memory with no `roles_class` is skipped **and named** in the report. An
omission you can see beats a wrong filing you cannot. `charter` and `recall`
are refused as targets — lint exempts exactly those two from `derived_from`,
which is what marks them hand-authored.

Read the rest of this section as a record of how the corpus was built, not
as something that repeats:

0. **Materialise queued identity changes** — `tools/roles/materialize_bindings.py`.
   The switcher queues host, role and rename changes rather than writing the
   committed registry mid-task; this is the step that applies them, closing
   the old window and opening the new one before anything resolves against it.
1. **Harvest** — `tools/roles/harvest.py`, per host, from the watermark
   forward. Pure SQL and regex: re-attributes observations whose recorded
   project is just the directory the observer ran in, assigns roles by
   path, and extracts the citation graph.
2. **Classify** — whatever the mechanical pass could not settle goes to a
   fan-out of cheap agents, which decide project and role together (project
   is the prior question: sibling repositories share our directory shapes,
   so a path rule alone would file their work under our roles).
3. **Distil** — one agent per role, applying `RUBRIC.md`. Distillers emit
   **claims only**; they never write files.
4. **Assemble** — `tools/roles/assemble.py` places claims into slices,
   writes provenance, regenerates every index, merges the citation graph,
   and runs the hygiene checks. Same claims in, byte-identical tree out.
5. **Land** — a normal pull request. `tools/roles/lint.py` gates it.
6. **Clear** — archive the store and empty it, so the next cycle drains
   only its own accumulation and stays small.

**Merge mode is the default from cycle two onward.** New claims fold into
existing slices; the existing file is the calibration anchor for what
counts as good enough; **an empty delta is a correct outcome.** Never
regenerate from scratch — that discards accumulated curation.

## Identity across hosts and renames

The memory store records a `project` that is just the basename of whatever
directory the writing process ran in. It changes when a working copy is
renamed, and it says nothing about which machine ran it — and the store is
shared per machine, not globally, so other hosts have their own.

So identity is separated from its attributes. A clone gets a `clone_id`
minted once and kept in its own gitignored state. Everything observable —
host, directory, role — is an **append-only binding window** in
`registry/bindings.jsonl`. Renaming a working copy or moving it to another
machine closes one window and opens another; nothing is rewritten, and an
observation recorded months ago under an old directory name still resolves
to the clone that produced it.

The switcher never writes the registry directly. It is a committed file and
a switch can happen mid-task, so identity changes queue in `.instance/`
and the next drain materialises them in its pull request.

Observations that resolve to no clone are reported **provisional**, never
guessed. Their knowledge is still admitted — only the attribution is
missing — and the tally is carried into `last-drain-report.json` and warned
about at assembly, because a drain of a clone that never registered has
*every* row provisional and otherwise looks exactly like a clean one.

**A clone that has never run `/role` cannot be registered from anywhere
else.** The id is minted by the clone itself, into its own gitignored
`.instance/`, so there is nothing for `(host, label, timestamp)` to resolve
against and no way to mint one on its behalf — writing plausible entries by
hand would give one working copy two identities in an append-only registry,
permanently. Run `/role <name>` **in that clone**, before its store is
drained; the next drain's `materialize_bindings` step commits the window.

The committed watermark lives in the same report, keyed by host — the store
is per machine, so "the" watermark is a per-host fact and one scalar would
be wrong the moment a second store is drained.

## Working with a role

```
/role flutter-dev            # become it
/role --status               # what am I, and has anything drifted?
/role flutter-dev --force    # replace locally adapted copies (stashes first)
```

Giving a role its own Linux account and its own clone — rather than having a
working copy become it — is a host operation, not a `/role` one:
[`PROVISIONING.md`](PROVISIONING.md).

The skills and commands a role installs are **copies**, and copies here are
working state. Adapting one inside a working copy is allowed and it
persists — a switch that would discard such an edit stops and says so. When
an adaptation proves worth keeping, promote it into `.roles/<role>/`
through a pull request so every future instance of the role inherits it.

Only the universally useful skills stay in `.claude/skills/`. Everything
role-specific lives here and is installed on demand, so a backend session
never has Flutter tooling on disk at all.

## Tools

```
tools/roles/materialize_bindings.py  apply queued identity changes first
tools/roles/harvest.py            drain the store into classified JSON
tools/roles/merge_classified.py   fold the model pass back in; taxonomy report
tools/roles/assemble.py           claims → slices, indexes, citation graph
tools/roles/lint.py               guard the committed base (CI)
tools/roles/switch.py             /role
tools/roles/query.sh              ask the citation graph
```

`query.sh` answers the questions the citation graph exists for:

```
tools/roles/query.sh adr ADR-054        # who learned from it, where it landed
tools/roles/query.sh migration 0007
tools/roles/query.sh obs <content-hash> # what a single observation taught
tools/roles/query.sh roles              # sizes
```

The graph stays in committed JSON rather than a database. It is small
enough that `jq` answers in milliseconds, and keeping it in files preserves
the property that matters most: a drain is reviewable as a diff. If
multi-hop queries ever become routine, the next step is a *generated*
SQLite edge cache — derived, never authoritative.

## Language

English, always, whatever the source was in. Prompts in particular are
often not English and are a primary source for `rationale`. Translate
rather than quote; mark a translated quote as translated. A non-English
slice found here is translated in place on the next drain, and `lint.py`
flags one that is not.

## What is not here yet

Recall is deliberate: a session consults the index, or a skill surfaces
through description matching. What is missing is *involuntary* recall —
knowledge arriving unbidden the moment matching code is touched. Two
documented routes exist when it is wanted: nested skill directories, which
activate when files in their subtree are read, or a pre-tool hook matching
path patterns. Neither is built. It is noted here because the absence is a
design choice rather than an oversight.
