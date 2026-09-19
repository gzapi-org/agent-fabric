# Message Format Guide

The wire format is intentionally closer to an email or incident note than to JSON.

## Shape

```text
[GZCOORD/1] TYPE
KEY: value
KEY: value

SECTION:
Free-form human-readable content.

SECTION:
- list item
- list item
```

The core parser treats the metadata block as simple `KEY: value` lines. Once a body section begins, subsequent lines belong to that section until another uppercase `SECTION:` marker appears — including lines that happen to look like `KEY: value`, such as `PR: #184` inside a `REFERENCES` body. Metadata is only ever the contiguous block before the first section marker; only a bare `SECTION:` line (name and colon, no value) starts a new section.

## Good messages

A good message answers:

- Who is speaking?
- In what role?
- About which project?
- Who is it for?
- What is the point?
- What repository context matters?
- Is any action requested?
- Where is the authoritative artifact?

## Reporting a finding

A finding that asks the owning lane to *fix* something is an assignment:
it is addressed `TO` one login, never `TO-ROLE` (§Direct versus role
addressing below). A finding that only informs — the lane decides
whether anything follows — may go to the role.

An `OBSERVATION` or `REVIEW` is complete when it diagnoses and stops. The
recommended shape:

```text
OBSERVATION:
what was noticed, stated as fact

VERIFIED:
how it was established, and the control that shows the measurement
was live

NOT-VERIFIED:
what was deliberately not checked, so the reader knows where the
diagnosis ends

IMPACT:
what follows if it is true, so the reader can decide not to act

REQUEST:
what the addressed role is asked to decide
```

`VERIFIED` is what separates a fact from a rumour with confidence
attached. A measurement can succeed while measuring nothing: a
type-checker that resolved to the wrong package and reported zero errors,
a pattern that never matched, a probe against the working tree when the
guard reads committed diffs. The control is whatever shows the instrument
was really pointed at the target — a second flag that yields a known
non-zero count, a deliberately broken input that is caught, a count that
agrees with an independent source. Give the commands, not a summary of
them, so the recipient can rerun them rather than remeasure.

When the finding is a leaked secret, `VERIFIED` names its shape and
location and never its value (SPEC.md §17). The proof of a leak must not
be a second copy of it.

`NOT-VERIFIED` is not an apology. It is the boundary of the claim, and it
is what lets the recipient extend the diagnosis instead of redoing it.

`IMPACT` is recommended for these two types specifically. A finding
without a stated impact gets the recipient's default treatment, and
"do nothing" is a legitimate outcome the message should make easy to
choose.

`REQUEST`, when present, asks the addressed role to exercise its own
judgement — "decide whether strict mode is enabled per app or through a
shared base config" — rather than to execute a fix the sender has
prescribed from outside that role's lane. The sender reports; the
recipient decides, and acts in its own working copy (SPEC.md §2). What a
session then does in its own working copy is governed by the
repository's rules, not by this protocol.

`examples/observation-diagnosis.txt` is a complete example.

## Requesting a supplied piece

A change has one owner — the caller, whose lane holds the consuming
code, contract or screen — and the pieces it needs from other lanes
(copy for a set of keys, the migration it reads, a check for its
feature) are supplied as commits onto the caller's branch, never as a
supplier's own pull request (the owner, 2026-09-18;
`identities/prompt/team.md`). The exchange is a `REQUEST` and its
`REPLY`; no new type. The recommended sections:

```text
REQUEST:
what is asked for, as the caller will consume it

DELIVER-TO:
the caller's branch and the base sha the supplier starts from

ACCEPTANCE:
what makes the piece done — copy: the key names, the caller's en-US
draft, the surfaces that reference them; a migration: its reader and
the columns; a check: what red and green mean

FACT:
for person-facing copy, the file:line, migration or contract that
makes each technical claim in the text true in every reachable state
— the supplier renders what is true, not what the draft assumed

BY:
when the branch is otherwise done, so the supplier knows the window
```

A supply `REQUEST` carries `REPLY-EXPECTED: yes` written out: the
caller's arming is gated on that `REPLY`, so the default is not left
to be inferred. The `FACT` line exists because a draft's claim can be
false in a state its author did not see — "no sign-in account" was
false for a pending row that already carried its identity pair, and
the copy shipped that way until the fact was named (gzapp #870,
2026-09-18).

The supplier's `REPLY` carries `REFERENCES` with the sha or range it
delivered and one more section:

```text
SUPPLIER-REVIEW:
what was checked before hand-off — the review the Supplier-Review:
trailer on the commit names
```

A hand-off ahead of any caller branch — the supplier finished first —
names the intended caller role in `DELIVER-TO` and a `FOLD-BY` date
(the next day by default): past it unclaimed, the supplier pings the
role once, then opens its own pull request under the count rule. The
caller's acknowledgement is the fold and the line in the PR body naming
whose range is which, not a message.

**The flow, end to end.** One sequence, so a reader does not assemble
it from three sections: an `OBSERVATION` names the gap → the caller's
`REPLY` names the branch (the acknowledgement by reference) → the
caller's `REQUEST` with `DELIVER-TO`, `ACCEPTANCE` (and `FACT` for
copy), `BY`, `REPLY-EXPECTED: yes` → the supplier's `REPLY` with the
sha range under `REFERENCES` and `SUPPLIER-REVIEW` → the caller's
range line in the PR body → one blind review of the whole range, each
finding routed to the lane whose `Fabric-Role:` the hunk's commit
carries → a `DECISION` only to materialise what already landed. The
worked example is gzapp #875 (2026-09-18): five lanes, one PR. Every
supplier push is a `pull_request` run on the caller's PR, so a
supplier batches its pushes where it can.

## Carrying the owner's word

A message never authorises anything (SEMANTICS.md), and twice in one
day the same kind of relayed word was refused by one session and
accepted by another. What makes the difference legible is how the
word is carried. A `DECISION` that carries the owner's word states it
verbatim, with the session it was given in and the time, under a
fixed section:

```text
OWNER-WORD:
"arm 871" — given in develop-qzapp/architect-cto-01, 2026-09-18T16:45Z
```

A paraphrase ("the owner agreed") is not an `OWNER-WORD`. What the
recipient does with it is in SEMANTICS.md, "The owner's word, relayed".

## Asking for an undo

Every message arrives late — read after an unknown delay, against a tree
that has moved (SPEC §2). The reader verifies what it says against the
repository before acting, so a message that asks for something to be
undone, reverted, removed or replaced has to give the reader something to
verify: **the defect in the change it asks to reverse**, stated as a
fact. Without it, "revert X" read an hour later cannot be told apart from
a message written before X was fixed, superseded or kept on purpose — and
the reader is right to refuse it.

```text
[GZCOORD/1] REQUEST
FROM: develop-qzapp/backend-dev-01
ROLE: backend-dev
TO-ROLE: fabric-coordinator
PROJECT: gzapp
MESSAGE-ID: 01a09fc1-…
SUBJECT: Revert the index refresh in 21a8714f: it dropped two entries

CONTEXT:
21a8714f (gzapp #699, merged 12:16 UTC) refreshed nine INDEX.md files.

OBSERVATION:
Two of them lost an entry that is not a recall.md line:
.agent-fabric/memory/db-admin/INDEX.md no longer lists
workflow/migrations.md, and web-dev's no longer lists
rationale/bundle-split.md. Both slices still exist in the tree.

VERIFIED:
- git diff 21a8714f^ 21a8714f -- .agent-fabric/memory/db-admin/INDEX.md
  shows the line removed; the slice file is unchanged.
- lint.py --working-copy gzapp=. passes, so the lint does not catch a
  dropped entry — only a drifted one.

REQUEST:
Restore the two entries (a revert of the two hunks, not of the commit —
the other seven files are correct).
```

The reader can check every line of that against the tree. A request
that only says "please revert 21a8714f" gives it nothing to check, and
after a delay nothing to distinguish it from noise.

## Acknowledging by reference

A complete diagnosis does not stop its sender from acting on it. Unless
the sender hears that someone else has, the natural next step is to do
the work itself — and two instances then do the same job, with a merge
conflict as the only signal between them.

When a recipient starts acting on an `OBSERVATION`, `REVIEW` or
`REQUEST`, it SHOULD send a `REPLY` with a `REFERENCES` entry naming the
branch or pull request where the work is happening. If the original
carried a `MESSAGE-ID`, the `REPLY` echoes it in `IN-REPLY-TO`; if it
did not, `SUBJECT` together with the original's `BRANCH` or `COMMIT`
(SPEC.md §7.3) is the correlation available. A message that invites
action SHOULD therefore carry a `MESSAGE-ID`, so the acknowledgement
can name it:

```text
[GZCOORD/1] REPLY
FROM: develop-gzapp/web-dev
ROLE: web-dev
TO: develop-gzapp/architect-cto
PROJECT: gzapp
MESSAGE-ID: web-dev-0003
IN-REPLY-TO: architect-cto-0007
SUBJECT: Acting on strict mode in my working copy

REFERENCES:
- branch: develop-gzapp/web-dev/fix/ts-strict-all-apps

NOTES:
Enabling strict in all four apps. Six real errors in admin_web; fixing
them.
```

This is descriptive context (SPEC.md §7.3) and means exactly what it
says: this is where the work is. It does not reserve the finding, own
the branch or block anyone — SEMANTICS.md lists what a message never
does, and this `REPLY` is no exception. Two instances MAY both send one;
the second reads the first and decides for itself. A sender that
receives one MAY take it as reason not to duplicate the work. If none
arrives, nothing is blocked and the sender proceeds as it would have
anyway. The acknowledgement is terminal: do not reply to it. The thread
ends there, and the pull request announces completion.

`examples/reply.txt` is the same message as a file.

## Avoid protocol clutter

Do not expose runtime trivia:

```text
MODEL: ...              # no
PROVIDER: ...           # no
TOKEN-BUDGET: ...       # no
SUBAGENT-DEPTH: ...     # no
WORKING-DIRECTORY: ...  # no
TELEGRAM-BOT: ...       # no
```

These belong to local configuration or the transport adapter.

## Subject

For non-HELLO messages, `SUBJECT` SHOULD be a one-line metadata field:

```text
SUBJECT: Stop resolution contract change
```

This makes chat transports and logs easy to scan.

## Direct versus role addressing

Known peer — the address alone; the role it holds is in the peer
directory, not repeated in the message:

```text
TO: develop-gzapp/architect-cto
```

What only the role decides, or every holder applies — the role alone
(never an assignment: below):

```text
TO-ROLE: architect-cto
```

Everyone:

```text
BROADCAST: true
```

Exactly one of the three, never two (SPEC.md §7.1): the field is who
receives, and a transport that filters by it cannot obey two. To ask one
party to act while others watch, send the ask to that party; its
acknowledgement by reference and the pull request are how the others
learn of it. `HELLO` and `GOODBYE` are broadcasts by definition and carry
none of the three.

**An assignment goes `TO` one login, never `TO-ROLE`** (SPEC.md §13; the
owner, 2026-09-19, after both holders of `backend-dev` executed one
`OBSERVATION` with a `REQUEST:` section as gzapp #897 and #899, the same
hunk twice). A `REQUEST`, a finding to fix, a supply, a decision to
record — anything with a `REQUEST:`, `ACCEPTANCE:` or `DELIVER-TO:`
section — names a login; the validator refuses it otherwise. `TO-ROLE`
is for what every holder applies or only the role decides: an `INFO`,
a `DECISION`, a `QUESTION` to whoever holds it.

When you do not know which holder, choose in this order and say in the
body which rule chose: (1) the holder whose open branch or pull request
already touches the path — `tools/gh/pr-gate.sh --all` or
`pr-sessions.sh --all` lists every open PR by owner; (2) the holder
whose `HELLO` is the most recent on the channel — the inbox's metadata
lines carry them; (3) the lowest-numbered login of the role. A wrong
choice costs one `REPLY` ("not mine — it is `<login>`'s") and nothing
else; a role address costs a duplicate of the work.

If an assignment reaches a role anyway — a sender on an older text — the
first holder to act sends its `REPLY` naming the branch or PR before
any other step; every other holder, on seeing that `REPLY` or an open PR
on the path by a sibling (`pr-gate.sh --all`), stands down silently: no
message, no branch. Two who acted before seeing each other: the later-
opened PR closes, naming the earlier.
