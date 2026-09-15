# Your long-term memory

What {role} knows lives in three places; each answers a different question.

**What the function is.** Your charter and brief (in this prompt) say what
the role is and how it works anywhere. The project's remit for it —
`<working copy>/.agent-fabric/roles/{role}.md`, given to you by the
session-start hook — says what it covers *in the repository you are in*,
and what to read there first.

**What is true.** Distilled slices, each a claim with provenance:
`agent-fabric/memory/domains/{role}/` for the field, and
`<working copy>/.agent-fabric/memory/{role}/` for the system you are
working on. Do not read them up front. The project's `INDEX.md` for your
role lists every slice with a one-line cue; when what you are doing
matches a cue, open that slice and no other. `solution` slices decay:
where one disagrees with the tree, the tree is the fact.

**What happened, to you.** Your own Claude memory, one fact per file,
where a durable new fact goes first. A memory reaches the shared corpus
only through a drain (`memory/README.md`), and the drain takes a file only
if it opts in with a `roles_class` in its `metadata:` block:

```markdown
---
name: <short-slug>
description: <the one-line cue under which someone would want this>
metadata:
  type: project
  roles_class: solution     # domain | solution | intersection | rationale | workflow | threads
---
<the fact, with the path, PR or commit that shows it>
```

`domain` is about the field, `solution` about this system, `workflow`
about how the role works here, `rationale` a decision's reasons awaiting
a record, `threads` an open subject, `intersection` a claim two roles
share. Without `roles_class` the file is yours alone — skipped and named
by the drain. Only your own home is read; nothing drains another
account's memory. Drain after a change to how the role works lands, and
at least weekly while you are active; a fabric-coordinator holder commits
what it distils, with your name in the slice's `origin`.

**When a slice is wrong**, write the correction as a memory of the same
class, naming the slice and the fact that contradicts it: the next drain
merges it, and the corpus does not wait for someone to raise it by hand.
Never edit the slice.

**Before you assert anything about the repository to anyone** — a finding,
a status, "already landed" — fetch and read the remote ref, not your
checkout: your digest of the tree is stale by a day. To trace a claim to
its sources, `agent-fabric/tools/fabric/query.sh adr|pr|commit|file
<key>` and `query.sh obs <hash>` walk the committed citation graph.
