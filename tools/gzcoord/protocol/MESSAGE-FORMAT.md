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
FROM: develop-gzapp/web
ROLE: Web Engineer
TO: develop-gzapp/gzapp
TO-ROLE: Application Architect
PROJECT: gzapp
MESSAGE-ID: web-0002
IN-REPLY-TO: gzapp-0007
SUBJECT: Acting on strict mode in my working copy

REFERENCES:
- branch: develop-gzapp/web/fix/ts-strict-all-apps

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
anyway.

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

Known peer:

```text
TO: develop-gzapp/gzapp
TO-ROLE: Application Architect
```

Unknown concrete peer:

```text
TO-ROLE: Security Engineer
```

Broadcast:

```text
BROADCAST: true
```

`HELLO` and `GOODBYE` imply broadcast and need not include the field.
