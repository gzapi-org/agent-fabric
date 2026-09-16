# `runtime/provisioning/platform/` — what differs per platform, in one file each

The provisioning worker (`new-agent-worker.sh`) sources
`platform/<id>.sh` after reading `/etc/os-release` (`ID`, and
`QUBES_*`/`/usr/share/qubes` for an AppVM); everything that is a
distribution's or a deployment's choice lives there, and nothing else in
the worker names one:

| function / variable | what it says |
|---|---|
| `PLATFORM_ID` | the id the host registry uses (`fedora-qubes`, `fedora`, `debian`) |
| `PKG_INSTALL_HINT` | the command a person runs to install packages, where they persist (a Qubes AppVM: in the TemplateVM) |
| `pkg_for <tool>` | the package that provides a tool of the fabric's contract |
| `PERSISTS_ACROSS_REBOOT` | whether a package installed on this machine is still there after a reboot (no, on a Qubes AppVM) |
| `GLOBAL_BASHRC` | the system bashrc a login shell sources (`/etc/bashrc` on Fedora, `/etc/bash.bashrc` on Debian) |
| `SUDO_GROUP_NOTE` | how sudo is granted to the operator here (the `qubes` group on Qubes; `sudo` on Debian) |

**The fabric's host contract** — the commands its hooks, scripts and
provisioning call, whatever the platform:
`bash sudo ssh getent pgrep timeout flock stat sha256sum cmp useradd
usermod shred install curl python3 node npm git gh jq gpg` (`cmp` is
what bootstrap's idempotence rests on; a Fedora container without
diffutils rewrote every file on every run — the smoke job's first find). `pkg_for` maps each
to its package; the CI smoke jobs install that list from the map on a
Fedora and a Debian container and run the suites, so the map is proven
by being used.

A project's extra needs (a container runtime, an image tool, a signing
wrapper) are the project's own `integration/provisioning/host-check.sh`.
