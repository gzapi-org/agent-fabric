# Claude accounts: which one a login runs on, and how full each is

The fleet runs on more than one Claude subscription. Two questions follow,
and they have different answers because the two kinds of Claude Code token
can do different things.

| | `/login` sign-in | `claude setup-token` |
|---|---|---|
| scopes | `user:inference`, `profile`, `mcp_servers`, `plugins`, `sessions:claude_code`, `file_upload` | `user:inference` only |
| lifetime | 8 hours, renewed by the harness with a refresh token | one year, no renewal |
| holders | one — a refresh token shared between logins signs the others out at the first renewal | any number, at once |
| reads usage | yes | no (HTTP 403) |

claude.ai → Settings → Claude Code lists both kinds and revokes either.

## Which account a login's sessions run on

A **template** per Claude account: Doppler project `agent-fabric`,
environment `claude-accounts`, one config per account named after its
email (`claude-accounts_<email with @ and . as ->`), holding that account's
setup-token as `CLAUDE_CODE_OAUTH_TOKEN`. The token is created once per
account (`claude setup-token` in a real terminal, approved in a browser
signed in as that account — the browser decides the account, not the
CLI's own sign-in) and stored with `doppler secrets set`, never pasted
anywhere else.

A login chooses by one line in its own config:

```
CLAUDE_CODE_OAUTH_TOKEN = ${agent-fabric.claude-accounts_<account>.CLAUDE_CODE_OAUTH_TOKEN}
```

The login's read-only service token resolves the reference, `fabric-secrets
sync` exports it (it is a fabric-wide `agent_env` name in
`projects/registry.json`), and set, it outranks the login's own `/login`.
Moving a login to the other account is that line, a sync and a relaunch —
no browser. A login with no such line runs on its own sign-in, as before.

What a session on a template does not have: the claude.ai connectors, the
plugins synced from claude.ai, Remote Control and web sessions. The
fabric's work needs none of them.

The login's `~/.claude.json` keeps naming the account it last signed into,
so no report reads it for a switched login: `bin/fabric-status` prints
`claude sign-in setup-token <sha>`, `fabric-ctl status` the same, and
`bin/fabric-accounts templates` maps a fingerprint to its account.

## How full each account is

An **observer** on the coordinator's login holds one `/login` sign-in per
account, in its own Claude Code config directory under
`${XDG_STATE_HOME:-~/.local/state}/agent-fabric/accounts/<account>/`, and
nothing else uses it. The control daemon reads each every 4 hours, and on
request, with the harness's own `claude -p /usage` headless: no model call,
it renews the 8-hour sign-in the official way, and it returns the server's
meters — `session`, `weekly_all` and `weekly_scoped` (per model).

```sh
bin/fabric-accounts login <account>   # once per account, in a real terminal: /login as that account, /exit
bin/fabric-accounts list              # signed in, email, expiry — never a token
fabric-ctl user accounts              # the windows, from the daemon
```

Rejected: renewing the sign-in without the harness. It works — the
harness's refresh request is visible in its binary — but it would present
Claude Code's client id without being Claude Code, and break silently when
that private request changes. `claude auth status` is not a keep-alive: it
starts a renewal, exits, and leaves `~/.claude/.oauth_refresh.lock` (a
directory) that every later run trips on.

Measured: `docs/live-checks/2026-09-24-claude-accounts.md`.
