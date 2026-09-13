# Telegram adapter — retired

> **RETIRED 2026-08-13. This document is history, not instruction.**
> Telegram is not GZCoord's transport. It was never able to carry the
> instance↔instance traffic the protocol exists for — see the blocking
> limitation below, which is the reason it was dropped. Read
> [`README.md`](README.md) first for what replaced it and what is still
> true. Do not implement against this file.

Telegram was the first GZCoord transport, never part of the core protocol.

The step-by-step bootstrap actually used for this repository (BotFather,
privacy mode, group creation, plugin wiring, lockdown, validation) is
documented in [`TELEGRAM-SETUP.md`](TELEGRAM-SETUP.md).

## Blocking limitation: bots cannot hear other bots

**This adapter cannot currently carry instance-to-instance traffic.**
Telegram bots do not receive messages sent by other bots — [Bot
FAQ](https://core.telegram.org/bots/faq#why-doesn-39t-my-bot-see-messages-from-other-bots):
*"we decided that bots will not be able to see messages from other bots
regardless of mode."* Disabling Group Privacy changes what a bot hears
from **humans**, and nothing about that rule.

With one bot per instance in a shared group, instance B therefore never
receives instance A's `HELLO`, and `TO`/`TO-ROLE`/`BROADCAST` routing
between instances cannot work. What does work is human↔instance: a
person reads every instance's output in the group and can address any
of them.

Two bootstrap validations pass anyway, which is why this was missed —
human→bot and bot→group are both fine, and neither exercises bot→bot.
Any validation that does not put **two instances** in the group and
watch one receive the other's `HELLO` proves nothing about the case the
protocol exists for.

Resolving it is a transport decision, not a protocol one (SPEC.md §14):
a relay that re-emits bot output under a non-bot identity, or a
different transport for instance↔instance traffic with Telegram kept as
the human-facing surface. One shared bot across instances is not an
option — the Claude Code plugin is a single consumer per token, so two
sessions polling one bot steal each other's updates.

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

The dedicated coordination group should be private. For discovery, participating instances need to receive `HELLO` broadcasts — which is exactly what the limitation above blocks, so treat the current setup as the human-facing surface until a relay or replacement transport is chosen. The exact Telegram privacy/allowlist configuration is transport-specific and should be validated on the installed plugin version.

## No authoritative state

The adapter MUST NOT create an authoritative registry, ownership database, issue state machine, merge lock or repository workflow. An in-memory/ephemeral mapping learned from `HELLO` is sufficient.

Git/GitHub and the repository rules remain authoritative.
