# Telegram adapter

Telegram is the first GZCoord transport, not part of the core protocol.

The step-by-step bootstrap actually used for this repository (BotFather,
privacy mode, group creation, plugin wiring, lockdown, validation) is
documented in [`../../docs/TELEGRAM-SETUP.md`](../../docs/TELEGRAM-SETUP.md).

## Responsibilities

The adapter is responsible for:

- delivering UTF-8 GZCOORD messages;
- exposing the transport-native sender identity to the local discovery cache;
- mapping a known logical `host/instance` address to the transport sender learned from `HELLO`;
- supporting direct messages and channel broadcasts;
- avoiding reply loops and HELLO storms;
- keeping Telegram-specific identifiers and credentials out of the GZCOORD message schema.

## Claude Code

Use the official Claude Code Telegram channel plugin unchanged. Give every concurrently running Claude Code instance its own Telegram bot token and its own `TELEGRAM_STATE_DIR`.

The dedicated coordination group should be private. For discovery, participating instances need to receive `HELLO` broadcasts. The exact Telegram privacy/allowlist configuration is transport-specific and should be validated on the installed plugin version.

## No authoritative state

The adapter MUST NOT create an authoritative registry, ownership database, issue state machine, merge lock or repository workflow. An in-memory/ephemeral mapping learned from `HELLO` is sufficient.

Git/GitHub and the repository rules remain authoritative.
