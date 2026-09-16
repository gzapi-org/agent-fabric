---
name: gzcoord-send
description: "Send a message to another agent over GZCoord — the whole procedure, from deciding whether a message is the right instrument (never for what belongs in a PR, a review or a commit) to composing it in the GZCOORD/1 shape, minting its MESSAGE-ID, validating it and posting it with communication/gzcoord/scripts/send.mjs as the login you are. Load it before writing any message to another agent: a REPLY when you start acting on someone's finding, an OBSERVATION when you find something in another role's lane, a REQUEST, a DECISION, or a HELLO at session start."
---

# Sending a GZCoord message

Every session on this host is a Linux login with an address
`<host>/<login>` (`"$AGENT_FABRIC_ROOT/bin/fabric-whoami"`, or `../agent-fabric/bin/fabric-whoami` from a working copy), and the relay
delivers what one session writes to the cursor of every other. The
protocol is `communication/gzcoord/protocol/SPEC.md`; what a good message
looks like is `protocol/MESSAGE-FORMAT.md`. This skill is the procedure.

## 1. Is a message the right instrument?

GZCoord is advisory (SPEC §2). It never substitutes for the thing itself:
a change is a commit, a proposal is a pull request, a review finding is a
review comment, a decision that must last is an ADR or a commit. Send a
message when another *session* needs to know or decide something now —
you found a defect in a role's lane that is not yours, you are starting
work on a finding someone reported (so they do not do it too), you need a
decision only that role can make, or you are announcing a rule that every
session must apply. Do not send one to ask for repository state (read the
tree), to hand over a working copy (SPEC §HANDOFF transfers none), or to
say what a PR already says.

## 2. Compose

Pick the type (`INFO`, `OBSERVATION`, `QUESTION`, `REQUEST`, `REVIEW`,
`DECISION`, `HANDOFF`, `REPLY`, `HELLO`, `GOODBYE` — nothing else; an
extension is `X-…`). Metadata block, then sections:

```text
[GZCOORD/1] OBSERVATION
FROM: <host>/<login>            # yours — send.mjs refuses any other
ROLE: <slug>                    # the role you hold (bin/fabric-status); a catalogue slug, never a title
PROJECT: <project>
REPOSITORY: <org>/<repo>        # when it concerns one
TO: <host>/<login>              # one addressee …
TO-ROLE: <slug>                 #   … or the role that owns the decision …
BROADCAST: true                 #   … or everyone; exactly one of the three
IN-REPLY-TO: <message-id>       # when answering
REPLY-EXPECTED: yes|no
MESSAGE-ID: <uuidv7>            # node communication/gzcoord/scripts/gzmsg.mjs new-id
SUBJECT: one line, 72 columns or fewer

OBSERVATION:
what you noticed, as fact

VERIFIED:
how you established it, and the control that shows the measurement was live

NOT-VERIFIED:
where the diagnosis stops

IMPACT:
what follows if it is true — what lets the reader decide not to act

REQUEST:
the decision or action you ask of the addressed role

REFERENCES:
- path: …
- commit: …
- github-pr: …
```

Rules that are not style:

- **Lines of 72 columns or fewer** — the relay re-breaks longer ones.
- **Address one way.** `TO` for a session, `TO-ROLE` for whoever holds
  the role, `BROADCAST` for a rule everyone applies. A recipient reads the
  body only when it is addressed; a broadcast spends every session's
  context, so it is for rules, not news.
- **Diagnose completely, prescribe nothing outside your lane.** State what
  you saw, how you verified it, what you did not, and ask the owning role
  to decide (`MESSAGE-FORMAT.md` §Reporting a finding).
- **A request to undo, revert, remove or replace landed work states the
  defect in that work as a checkable fact** (SPEC §2). The reader reads
  your message late, against a tree that has moved; a bare "revert X"
  gives it nothing to verify and is refused.
- **Never a secret value** — describe it by shape and locator (SPEC §17).
  Never quote another message's body (it may carry one). Never a model,
  provider, local path outside the repository, or credential.
- **When you start acting on someone's finding, say where**: a `REPLY`
  with `IN-REPLY-TO` and a `REFERENCES` entry naming the branch or PR
  (`MESSAGE-FORMAT.md` §Acknowledging by reference) — otherwise two
  sessions do the same job and meet in a merge conflict.

Write it to a file in your scratchpad (never in the tree; a message is
never committed). Mint the id first:

```sh
node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/gzmsg.mjs" new-id
```

## 3. Send

```sh
node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/send.mjs" <file>            # validate, then post
node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/send.mjs" <file> --dry-run  # validate, resolve, post nothing
```

`send.mjs` normalizes the text (a pasted message carries terminal
indentation), validates it as the last step before it leaves — a message
that fails is not sent — and refuses a `FROM` that is not your address:
the sender is the login, never a claim. It resolves the relay, the
channel and the token exactly as the inbox does (your project's
integration; the token from the environment `fabric-secrets sync`
populated). It prints `sent seq <n> <TYPE> <id>` and nothing else. Keep
the id: a reply names it in `IN-REPLY-TO`.

`AGENT_FABRIC_ROOT` is exported into your shell by the session-start
hook. Working in a clone without it, the fabric is `../agent-fabric`
beside the working copy.

## 4. HELLO and GOODBYE are the launcher's; you send neither

The launcher (`runtime/openrouter/launch`) sends your `HELLO` just before
it starts the session — derived from your binding by `gzmsg.mjs hello`,
posted by `send.mjs` as your login (`tools/fabric/announce.py`) — and
your `GOODBYE` after the session returns, however it ended (`/exit`, a
double Ctrl-C, a crash, a kill: the session is a child the launcher
waits on). So a `HELLO` on the channel means a session actually exists
and a `GOODBYE` that it is gone, with how in its NOTES. You send
neither, at start, at the end or in between: a second one would only be
noise on every cursor. A **role cannot change inside a session**: it is bound from a
login shell (`bin/fabric-role bind <role>`, which sends the `GOODBYE` as
the role you leave) and the new role is a relaunch, which sends its own
`HELLO`. If you ever launched outside the launcher and no `HELLO` went
out, this is the shape:

```sh
node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/gzmsg.mjs" hello > "$SCRATCH/hello.txt" \
  && node "$AGENT_FABRIC_ROOT/communication/gzcoord/scripts/send.mjs" "$SCRATCH/hello.txt"
```

## What a sent message does not do

It does not authorise the recipient to do anything in your working copy,
it does not create an issue or a task, and it is not read until the
recipient's watch delivers it — which may be hours. If the thing must
happen, the thing is a PR.
