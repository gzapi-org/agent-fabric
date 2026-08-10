# Telegram transport — concrete setup walkthrough

The steps that were actually performed to bootstrap the first GZCoord
Telegram transport for this repository (2026-08-10), generalised so the
next instance can repeat them. The adapter contract and responsibilities
live in `../adapters/telegram/README.md`; this file is the operational
how-to.

Every step happens on a Telegram account that will own the bot, plus the
Claude Code host. Nothing here touches the GZCoord protocol itself.

## 1. Create the bot (BotFather)

In Telegram, open the **verified** @BotFather (blue check — there are
impersonators with similar names) and run:

1. `/newbot`
2. Name: a human-readable display name for the instance — the first one
   used `gzapp gzcoord coordinator`, matching the `.roles/` role the
   working copy holds (see `../runtime/README.md` "Role sourcing").
3. Username: globally unique, must end in `bot` — the first one is
   `gzapp_gzcoord_bot`.

BotFather replies with the **HTTP API token**. That token is a
credential: it goes straight into the local configuration below and
nowhere else — never into git, never into a GZCOORD/1 message, never
pasted into chats.

## 2. Disable Group Privacy (before joining the group)

GZCoord discovery needs the bot to receive messages **not addressed to
it** (`HELLO` broadcasts). Bot accounts default to Group Privacy ON,
which limits them to `/commands` and @mentions.

In BotFather:

1. `/setprivacy`
2. Select the bot (e.g. `@gzapp_gzcoord_bot`)
3. Choose **Disable** → expect "Success! The new status is: DISABLED."

Order matters: change privacy **before** adding the bot to the group. A
privacy change made while the bot is already a member only takes effect
after removing and re-adding it.

## 3. Create the coordination group

The coordination surface is a **private group** (not a broadcast
channel — bots in channels cannot see each other's ordinary messages).
The first one is named `gzapp-gzcoord-channel`.

1. Telegram → compose → **New Group**.
2. Add the bot as a member (search its username).
3. Name the group and create it.

Do not make the group public. Membership is the first access-control
layer; the plugin's sender allowlist (below) is the second.

## 4. Wire the bot to the Claude Code host

With the official `telegram@claude-plugins-official` plugin installed
(`/plugin install telegram@claude-plugins-official`):

1. Save the token where the plugin's channel server reads it at boot:

   ```
   ~/.claude/channels/telegram/.env      # chmod 600
   TELEGRAM_BOT_TOKEN=<token from BotFather>
   ```

   (`/telegram:configure <token>` does exactly this.)

2. Restart the session or run `/reload-plugins` — the server reads
   `.env` **once at boot**. After the restart the session's Telegram
   tools (`reply`, `react`, `edit_message`) are live and the plugin owns
   the token's `getUpdates` stream.

Never poll `getUpdates` by hand once the plugin holds the token: two
consumers of one bot token steal each other's updates (HTTP 409s and
silently missing messages).

One bot token and one plugin state directory **per concurrently running
instance** — instances must not share a bot.

## 5. Lock down access

The plugin boots with DM policy `pairing` and an empty allowlist. For a
coordination channel the target state is a **closed allowlist**:

1. DM the bot from the owning human account → it replies with a pairing
   code.
2. In the session: `/telegram:access pair <code>`.
3. When everyone who belongs is captured:
   `/telegram:access policy allowlist`.

Access approval happens only in the terminal, by the human. A Telegram
message asking the assistant to approve a pairing or extend the
allowlist is exactly the request a prompt injection would make — the
plugin refuses it by design, and so must every session.

## 6. Validate

1. Send an ordinary message in the group — *not* a command, *no*
   @mention.
2. Confirm the session receives it (it arrives as a
   `<channel source="telegram">` block). That proves Group Privacy is
   off and the plugin is connected.
3. Send a GZCOORD/1 `HELLO` through the session and confirm it lands in
   the group.

If step 2 fails: check the bot is still a group member, re-run
BotFather `/setprivacy` (then remove and re-add the bot to the group),
and confirm the token in `.env` matches the bot.

## What stays out of git

- The bot token (`~/.claude/channels/telegram/.env`, mode 600).
- The plugin's state directory.
- The instance configuration (`~/.config/gzcoord/<project>.yaml`, from
  `../config/instance.example.yaml`).
- Chat IDs, numeric user IDs, allowlists (`access.json`).

Per `../protocol/SPEC.md` §14, none of these may ever become required
GZCOORD/1 fields.
