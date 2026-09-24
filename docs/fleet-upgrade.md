# Upgrading the fleet's software: one command, sessions come back on it

Until 2026-09-24 the coordinator upgraded Claude Code on sixteen accounts
with a hand-written `hostexec` loop, and distributed the fabric with
another; both had the same shape, and neither could bring a running
session onto the new version. The owner asked for one control-plane
command, general in shape, starting with the harness alone.

## The command

```sh
fabric-ctl <login|all> upgrade claude [--version V]
```

The target is **pinned in the repository**: `runtime/claude-code/harness.json`
names the Claude Code version the fleet runs. Moving the fleet is a
one-line PR, reviewed and revertable like any other change; `--version`
overrides it for one account, for a trial. Provisioning installs the same
pin, so a new account starts where the others are. Background auto-update
is off on every account through `env.DISABLE_AUTOUPDATER` in each login's
user settings (`runtime/claude-code/user-settings.py`, written by
bootstrap), so nothing else moves the version. `autoUpdates: false` in
`~/.claude.json` is not enough on a native install: the harness ignores it
when `autoUpdatesProtectedForNative` is true, and the coordinator's account
updated itself to 2.1.282 that way on 2026-09-24.

## What happens on each account

The account's control daemon (`runtime/control/agentd.mjs`, one per login,
running whether or not a session is open) receives the request and:

1. checks it is **signed with the operator's key** (`docs/control-plane.md`,
   "The fence"); an unsigned or wrongly signed action does nothing;
2. at the pin already: nothing moves, nothing restarts;
3. a session running: writes the restart marker
   (`<fabric state>/agents/<login>/restart.json`), then sends `claude` a
   **SIGTERM** — the harness's own graceful shutdown: SessionEnd hooks, the
   session saved, its failsafe bounding the wait. Never a SIGKILL: a session
   that does not stop within 90 s is a failure to report, not to force;
4. installs the version with the harness's own installer (`claude install
   <v>`) and verifies `claude --version`;
5. marks the marker done or failed and replies: `from → to`, and whether a
   session is restarting.

The **launcher** is still in the session's terminal (the session is its
child, not an exec). After the GOODBYE it finds the marker, waits while the
upgrade runs, says how it went, and re-executes itself — through the same
pull and checks as any launch — with `--resume <session id>`, so the agent
continues the same conversation on the new version, with a fresh HELLO. A
failed upgrade still brings the session back, on what is installed. A
marker older than the launch belongs to another session and is removed,
never obeyed.

The requester's own session is never stopped: it is the one waiting for
the reply. It is installed under it and told to relaunch.

## Setup, once

```sh
fabric-ctl keygen             # on the operator's login: private half into its Doppler config, public into the registry
bin/fabric-secrets sync       # the key reaches this login's secrets.env
git commit runtime/hosts/registry.json   # the fleet trusts the key once it has pulled this
```

## Why the daemon, and why signed

The owner chose the control-plane daemon over the coordinator's sudo
(`hostexec`): it is already running as each login, needs no per-host loop,
and answers in real time. The price is that the relay verifies no sender —
any holder of the relay token can claim the operator's address — which was
tolerable while every op only reported, and is not for an op that stops a
session and installs software. Hence the signature, required for actions
only.

## Assumptions, and what they cost

- **One session per login.** The marker and the binding's session id are
  per login: the fabric runs one agent per login (a second session is a
  second login), so there is one session to stop and one to resume.
- **The signing key lives in the operator's login.** `fabric-secrets sync`
  exports it into that login's shells, so anything that can run a command
  as the operator can sign an action — the same reach it already has
  through the operator's sudo. The key protects the fleet from the relay
  token's other holders, not from the operator's own sessions.
- **Where the marker lives** is the fabric state root both the daemon and
  the launcher resolve (`AGENT_FABRIC_STATE_DIR`, else `XDG_STATE_HOME`,
  else `~/.local/state`); measured 2026-09-24: no account sets either
  variable, in a login shell or under its systemd user manager.

## Not yet

- Other pieces: `fabric` (pull + bootstrap) and `ori` were left for later
  (the owner, 2026-09-24); a piece is an entry in `runtime/control/upgrade.mjs`
  `PIECES`, not a new op.
- Signed replies: a forged reply can still show a false row.
- A live run on the fleet: the sequence is tested against fakes; the first
  real upgrade should read back that the SessionEnd hook ran, the session
  resumed, and — on the broker path, where the launcher's child is `ori`,
  which starts `claude` — that the launcher reached its GOODBYE after the
  SIGTERM to `claude`.
