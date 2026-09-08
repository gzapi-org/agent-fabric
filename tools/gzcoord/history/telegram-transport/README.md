# Telegram transport — retired

**Status:** Retired (2026-08-13). Telegram is **not** GZCoord's transport and
never will be. Nothing in this folder describes how the protocol works today.

**Do not follow these steps.** They are kept because the bootstrap knowledge
was expensive to acquire and is useful to whoever designs the replacement
transport — not because any of it is still current. Nothing here is
maintained, and the review findings outstanding against these documents were
answered by retiring the transport rather than by fixing them.

## Why it was retired

Telegram bots never receive messages sent by other bots, regardless of privacy
mode — [Bot FAQ](https://core.telegram.org/bots/faq#why-doesn-39t-my-bot-see-messages-from-other-bots):
*"we decided that bots will not be able to see messages from other bots
regardless of mode."* Disabling Group Privacy changes what a bot hears from
**humans**, and nothing about that rule.

With one bot per instance in a shared group, instance B therefore never
receives instance A's `HELLO`, and `TO` / `TO-ROLE` / `BROADCAST` routing
between instances cannot work at all. What the walkthrough actually produced
was a **human↔instance** channel: a person reads every instance's output in
the group and can address any of them. That is not the leg GZCoord exists for.

The failure hid for a while because both bootstrap validations pass anyway —
human→bot and bot→group are each fine, and neither exercises bot→bot. Any
validation that does not put **two instances** in the group and watch one
receive the other's `HELLO` proves nothing about the case that matters.

### Why the workaround was refused

The obvious way around the bot-to-bot rule was to give each instance a full
user account rather than a bot. Telegram permits it, and it would have
delivered `HELLO`s. It was refused, and the refusal is the decision that
actually retired this transport: an agent operating under a human-style
identity can interact with third-party humans while appearing to be one,
whether by design or by mistake. That is not a risk worth a message bus, and
it is not specific to Telegram — any candidate transport that can only give
an agent a human's identity fails on the same ground. The bot-to-bot rule
above is the reason a workaround was needed; this is the reason it was not
taken. Both are recorded because the first invites re-litigation and the
second ends it.

The replacement is a new **transport**, designed for agent-to-agent delivery
from the start rather than a chat network adapted to it — a carrier for
GZCOORD/1, not a successor to it.

## What is here

| file | was | contents |
|---|---|---|
| [`TELEGRAM-ADAPTER.md`](TELEGRAM-ADAPTER.md) | `adapters/telegram/README.md` | the adapter's responsibilities, the blocking limitation, and the Claude Code plugin notes |
| [`TELEGRAM-SETUP.md`](TELEGRAM-SETUP.md) | `docs/TELEGRAM-SETUP.md` | the full operational walkthrough — BotFather, privacy mode, group creation, per-instance bot tokens and `TELEGRAM_STATE_DIR`, the access allowlist, `chat_id` capture, and validation |

## What survived the retirement, and where it lives now

| concern | now |
|---|---|
| the transport-independent adapter interface | [`../../docs/TRANSPORT-ADAPTER-CONTRACT.md`](../../docs/TRANSPORT-ADAPTER-CONTRACT.md) — it never named Telegram and is unchanged |
| the rule that transport-native identifiers stay off the wire | `protocol/SPEC.md` §14, `MESSAGE-FORMAT.md`, `CONFORMANCE.md`, and the `FORBIDDEN` set in `scripts/gzmsg.mjs`. `TELEGRAM_CHAT_ID` and friends are still named there **as forbidden fields** — those are warnings, not transport selection, and they stay |
| the state of the protocol itself | [`../../CLAUDE.md`](../../CLAUDE.md) — GZCoord is inactive; reactivating it requires a transport decision first |

Credentials were never in Git and are not here: bot tokens and plugin state
lived outside the repository, and removing them is an operator task on the
host, not a change to this tree.
