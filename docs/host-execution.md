# Host execution — what changed on 2026-09-16

A note under `docs/` because a concept was added: **where an account
lives, and how the coordinator acts there.**

## Before

The control plane knew many hosts in principle — a binding records its
host, a GZCoord address is `<host>/<login>`, `identity.py` strips the
domain from the hostname on purpose — and operated one in practice.
Every tool that acted on an account did so with the coordinator's own
sudo, `getent`, `/home/*` and filesystem: `enroll.sh` derived the
account's host from the machine running it, `new-agent.sh` created the
account beside itself, `moveto` opened a shell on this machine, a drain
read a home directory on this machine. Placing an account on another
host would have meant running each of those there by hand, and the
first of them would have stamped the wrong host into Doppler.

## After

**One boundary, two backends.** `runtime/hosts/registry.json` names the
hosts the fabric operates (by short hostname — the only id a host has
here, so two hosts never share one) and each account's *placement*: the
host it was provisioned on. `runtime/hostexec/hostexec <host> [--as
<login>] -- <cmd>` runs one command on that host:

- on the host this checkout is on (`ssh: null`), directly — the
  coordinator's present root-capable access is the **local backend**,
  unchanged and not going anywhere during the implementation rush;
- on any other host, over `ssh` to the host's operator, running the
  **same worker** (`runtime/hostexec/worker`) there.

The worker runs on the target because `getent`, the passwd and group
databases, PAM, `/run/user`, rootless containers, the account's `~/.claude`
and the filesystem permissions are all host-local; nothing here makes a
remote home look local. stdin flows through both backends, so a token or
a drain bundle passes without ever being an argument.

**Placement is not identity.** An account's name is its Linux login
(`runtime/identity.py`); its role is its binding; its host is where the
OS account exists. The registry records the third and nothing else — the
schema refuses a role or a name in a host entry — and `bin/fabric-status`
reports a session running on a host other than its placement as drift.

**The host reports itself.** The coordinator never stamps a host it is
not on: `AGENT_FABRIC_HOST` is a test override, `fabric-host <host>
check` asks the target for `hostname -s` and refuses a mismatch with the
registry id, and provisioning's worker records what the target says.

**What stays the coordinator's.** Doppler administration, the API keys
minted for an account, the registry itself. What is host-local — the
account, its home, the installers, a shell there (`fabric-host <host>
moveto`), a working-copy rename, a memory drain — goes through the
executor.

## What this decides

A tool that touches an account's host does it through `hostexec`
(`bin/fabric-host` for a person), never with its own `sudo -u` or a path
under `/home`. A new host is a registry entry and a `check`; a new
account on it is a placement. Retiring the local backend's direct access
later changes the backend, not the callers.
