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

This makes Telegram, Slack and logs easy to scan.

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
