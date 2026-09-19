# Resources: what an account may consume on the machine it shares

Written 2026-09-19, the day `develop-qzapp` died under two backend
integration suites (`live-checks/2026-09-19-develop-qzapp-crash.md`).
Until then the fabric governed *where* an account lives (placement,
`runtime/hosts/registry.json`) and could *read* what it spends (the
control plane's usage and token ops), and governed nothing about what an
account takes from the host it shares with fifteen others. This note
names the three layers that gap has, says which one exists, and holds
the others to the same bar as everything else here: built when a second
incident gives them a shape, not before.

## Three layers, kept apart

| layer | the question | the mechanism | status |
|---|---|---|---|
| **host lease** | may this job start *now*, on *this* host? | one `flock` per named resource in `/run/lock/agent-fabric/`, `bin/fabric-lease` | built (this note) |
| **account quota** | how much of the host may *one* account take? | the kernel: `MemoryHigh`, `MemoryMax`, `CPUWeight` on `user-<uid>.slice`, set where `persist-accounts.sh` already sets per-account boot state | next; not built |
| **fleet lease** | may this job start now, *anywhere*? | a record on the relay's control channel, answered by the holder's daemon | not built; no observed need |

The lease is **per host on purpose**. What it protects — memory, cores,
a rootless-podman postgres — is the host's, and two hosts each running
the backend suite is the concurrency we want; only two accounts on one
host must be serialised. A resource that is genuinely fleet-wide (a
shared staging database, a device farm, the Actions-minute budget) is
the third layer, and reaching for `fabric-lease` for it would only look
like it worked until the second host joined.

The lease does **not** stop one account from eating the VM alone. That
is the quota layer, and it is the next piece worth doing: `MemoryHigh`
on each account's slice makes the kernel throttle the offender where
today the hypervisor's balloon lets the whole VM go. Small, host-local,
one more line where the boot script re-adds the accounts.

## The host lease

```sh
fabric-lease <name> [--wait SECS] [--need-mem MB] -- <cmd> [args...]
fabric-lease <name> --who
```

- **A name is a resource, not a job.** `backend-test` — the suite and
  its postgres — whoever runs it, from whichever checkout. Two names
  are two leases; the project decides its names, and writes them where
  the job is started (a Makefile target), never in the fabric.
- **Fail fast by default.** A session's tool call has a timeout of its
  own; refused, it is told `held by <login> <pid> <since> <name>` and
  decides — wait (`--wait`), do something else, or ask. Exit 75
  (`EX_TEMPFAIL`) so a wrapper can tell "busy" from "failed".
- **`--need-mem`** checks `MemAvailable` *under* the lease, so two
  callers cannot both pass. It exists because of the balloon: a Qubes
  VM grows on demand with a lag, and a suite started at 8.6 GiB does
  not get its 18 before it needs them.
- **Nothing stale.** The lock is the kernel's on an open descriptor: a
  killed holder releases it; the command runs with the descriptor
  closed, so nothing it spawns and leaves behind holds it. The command
  runs in its own process group and TERM, INT and HUP to the wrapper
  reach that group, so a killed wrapper takes its suite down with it —
  except by KILL, which cannot be forwarded: a harness that ends a
  timed-out tool call with KILL to the wrapper alone frees the lease
  under a running suite. Not observed; the shape to settle if it is.
- **No privilege.** An agent has no sudo, and needs none here: the
  directory is root's, made at boot by provisioning; taking a lease,
  reading `--who`, and the control plane's `host` op are all
  unprivileged reads and locks. The one privileged read the `host` op
  attempts, xenstore's `static-max`, degrades to `null` for an account
  and `fabric-ctl` prefers the operator's row.
- **The directory survives the boot** on both platform kinds: the
  account boot script makes it on a Qubes AppVM (volatile `/run`, `/etc`
  and all), tmpfiles.d where `/etc` persists; `persist-accounts.sh`
  installs both and makes it for the running boot
  (`runtime/provisioning/platform/README.md`).

Who owns what: the directory, the tool and this note are the fabric's;
the call site — which targets take which lease, with what memory floor
— is the project's, in the lane that owns its build entrypoints
(`devex-tooling`, on gzapp).
