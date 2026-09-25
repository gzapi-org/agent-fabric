# An assignment goes to one login, never to a role — what changed on 2026-09-19

`TO-ROLE` narrowed in meaning. Until today it was "whoever holds the
role", for any message; from today it is for what every holder applies
or only the role can decide — an `INFO`, a `DECISION`, a `QUESTION` —
and an **assignment** (a `REQUEST`, or any message with a `REQUEST:`,
`ACCEPTANCE:` or `DELIVER-TO:` section: a finding to fix, a supply, a
decision to record) is addressed `TO` one login. SPEC.md §13 states it
as a MUST on the sender and a MUST-reject on the validator; §18 lists
it; `send.mjs` refuses it before it leaves.

## Why

`backend-dev` has two holders on develop-qzapp. At 08:37Z devex-tooling
sent an `OBSERVATION` with a `REQUEST:` section `TO-ROLE: backend-dev`
— redirect the bare `dotnet test` lines in the backend `CLAUDE.md`
through the new host lease. The runtime delivers a role address to
every holder (SPEC §13 option 1). backend-dev-01 took it as gzapp #897;
backend-dev-02, unaware, took it as #899 three hours later: the same
section of the same file, twice, one `merge_group` run spent on a
duplicate, and a conflict for whichever landed second. Neither `REPLY`
named the other's PR; neither had seen it. The owner, in devex-tooling's
session: *"an assignment of a job must not be sent to a role."*

The spec already said a runtime facing several holders MUST NOT invent
an ownership rule. What it did not say is that the *sender* must not
put it in that position. The protocol's own examples —
`examples/observation.txt`, `examples/observation-diagnosis.txt` — were
`OBSERVATION` + `REQUEST:` + `TO-ROLE`: the misrouting shape, offered
as the pattern to copy. They now name a login.

## What the freeze says about this

The grammar (§6) is untouched: no field added, no value form changed.
A tightened MUST on an existing field retires a shape (§18) and the
sender is told which field is at fault — `a REQUEST is an assignment
and goes TO one instance, never TO-ROLE` — rather than misrouted. Every
message valid under the new text was valid under the old; the set only
narrows. The evidence bar in the coordinator's charter asks for a
pattern observed, not argued: two independent sessions, one message,
two PRs on one hunk, verified against GitHub.

## What a session does now

- **Sending:** an assignment names a login. Not knowing which holder is
  answered in order — the holder whose open PR touches the path
  (`pr-gate.sh --all`), else one holding it with a session running now
  (`fabric-ctl all presence`), else
  the lowest-numbered login — and the body says which rule chose. A
  wrong choice costs one `REPLY`; a role address costs the work twice.
  (`MESSAGE-FORMAT.md` §Direct versus role addressing, the `gzcoord-send`
  skill.)
- **Receiving one that reached the role anyway** (a sender on an older
  text): the first `REPLY` claims it, before any work; a holder that
  finds a sibling's `REPLY` or an open PR on the path stands down with
  no message; two who acted anyway close the later PR naming the
  earlier (the `gzcoord-receive` skill, step 6).

## Not changed

The runtime still delivers `TO-ROLE` to every holder; §13's options
stand for the messages that may still use it. No `GZCOORD/2`. The
coordinator's own `REQUEST` of the same morning, addressed `TO-ROLE:
devex-tooling`, was the same mistake on a role with one holder — the
rule binds this role too, and `send.mjs` would now refuse it.
