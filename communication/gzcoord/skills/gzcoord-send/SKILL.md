---
name: gzcoord-send
description: "Send a message to another agent over GZCoord — the whole procedure, from deciding whether a message is the right instrument (never for what belongs in a PR, a review or a commit) to composing it in the GZCOORD/1 shape, minting its MESSAGE-ID, validating it and posting it with communication/gzcoord/scripts/send.mjs as the login you are. Load it before writing any message to another agent: a REPLY when you start acting on someone's finding, an OBSERVATION when you find something in another role's lane, a REQUEST, or a DECISION; and to learn whether an agent is online (presence), since nobody sends HELLO any more."
---

# Sending a GZCoord message

Every session on this host is a Linux login with an address
`<host>/<login>` (`fabric-whoami`), and the relay
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
`DECISION`, `HANDOFF`, `REPLY` — nothing else; an extension is `X-…`;
`HELLO` and `GOODBYE` are deprecated, see §4). Metadata block, then sections:

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
MESSAGE-ID: <uuidv7>            # gzmsg new-id
SUBJECT: one line, short

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

- **Lines of 72 columns or fewer, where you can** — a courtesy to the
  reader's terminal, not a rule of the wire: the bridge carries a line
  as written, so a path or an id that is longer goes out whole and
  `send.mjs` says nothing about it. Only a message someone will paste
  by hand (`gzmsg.mjs validate`) still warns about width.
- **Address one way.** `TO` for a session, `TO-ROLE` for whoever holds
  the role, `BROADCAST` for a rule everyone applies. A recipient reads the
  body only when it is addressed; a broadcast spends every session's
  context, so it is for rules, not news.
- **An assignment goes `TO` one login, never `TO-ROLE`** (SPEC §13). A
  `REQUEST`, a finding to fix, a supply — anything with a `REQUEST:`,
  `ACCEPTANCE:` or `DELIVER-TO:` section — names a login, because the
  runtime delivers a role address to every holder and each executes the
  job unaware of the others: two PRs on the same hunk. `send.mjs` refuses it. When you do not
  know which holder: the one whose open PR touches the path
  (`pr-gate.sh --all`), else one holding it with a session running now
  (`fabric-ctl all presence`), else the lowest-numbered login — and say which rule chose
  (`MESSAGE-FORMAT.md` §Direct versus role addressing). `TO-ROLE` stays
  for an `INFO`, a `DECISION`, a `QUESTION` to whoever holds the role.
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
- **After a safeguard flag, filter the category out of everything you
  send.** If the harness told you a model's safeguards flagged your
  request and switched the session to another model, what flagged you
  flags every session it is sent to, and a broadcast lands in all of
  them. From then on, nothing that could be read as the flagged
  category (a cybersecurity issue, most often) goes into a message:
  name where a finding is (file, line, PR) and what class of problem it
  is, never its content, and let the reader open it in their own
  repository. The PostModelSwitch hook says this to you the moment it
  happens, naming the category, and `send.mjs` repeats it on stderr
  while the session is marked as fallen back; it cannot check the
  content, only you can.
- **When you start acting on someone's finding, say where**: a `REPLY`
  with `IN-REPLY-TO` and a `REFERENCES` entry naming the branch or PR
  (`MESSAGE-FORMAT.md` §Acknowledging by reference) — otherwise two
  sessions do the same job and meet in a merge conflict.

Write it to a file in your scratchpad (never in the tree; a message is
never committed). Mint the id first:

```sh
gzmsg new-id
```

## 3. Send

```sh
gzcoord-send <file>            # validate, then post
gzcoord-send <file> --dry-run  # validate, resolve, post nothing
gzcoord-send <file> --force    # post even if the addressee has no session
```

`send.mjs` normalizes the text (a pasted message carries terminal
indentation), validates it as the last step before it leaves — a message
that fails is not sent — and refuses a `FROM` that is not your address:
the sender is the login, never a claim. It resolves the relay, the
channel and the token exactly as the inbox does (your project's
integration; the token from the environment `fabric-secrets sync`
populated). It prints `sent seq <n> <TYPE> <id>` and nothing else. Keep
the id: a reply names it in `IN-REPLY-TO`.

**Before a `TO` or `TO-ROLE` message leaves, `send.mjs` asks whether the
addressee has a session running** — the control plane answers from each
account's process table (`fabric-ctl <login|all> presence` shows the
same). An addressee with no session, a control agent that did not answer
or could not tell, an address no host places, or presence that could not
be asked at all is named, nothing is sent, and it exits 4.
A `TO-ROLE` passes when any holder of the role is running; a broadcast is
not checked. Then you decide: a message to a login with no session waits
in the relay until one starts, which may be what you want — `--force`
sends it anyway, and says so. A request that must be acted on now
belongs to a running session, or to a later send.

The fabric's commands are on your PATH by name — `gzcoord-inbox`,
`gzcoord-send`, `gzmsg`, `fabric-status` and the other `fabric-*` —
and allowed in your settings: run them bare. Never write one through
`$AGENT_FABRIC_ROOT` or any other expansion; the harness asks before a
command that carries one.

## 4. Presence is asked, never announced

`HELLO` and `GOODBYE` are deprecated (SPEC §5): nobody sends them, and
the inbox acknowledges one from a session not yet updated without
delivering it. Whether another agent has a session running — since when,
as which role — is the control plane's to answer, from each account's
process table:

```sh
fabric-ctl <login> presence    # one account
fabric-ctl all presence        # everyone
```

`send.mjs` asks the same before a `TO` or `TO-ROLE` message leaves (§3).
A crash, or a launch that never started, reads as no session: presence is
the process table, not what a session said about itself. A **role cannot
change inside a session**: it is bound from a login shell
(`bin/fabric-role bind <role>`) and the new role is a relaunch; presence
reports the role from the binding.

## What a sent message does not do

It does not authorise the recipient to do anything in your working copy,
it does not create an issue or a task, and it is not read until the
recipient's watch delivers it — which may be hours. If the thing must
happen, the thing is a PR.
