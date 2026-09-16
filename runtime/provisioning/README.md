# Provisioning — what an agent account needs from the control plane

An agent is a Linux login. Giving a role its own account is a host
action, and most of it is the deployment's (SSH and forge credentials,
commit signing, the toolchain of the projects it will work on, data
areas): that runbook lives with the deployment. This is the part that is
the control plane's, the same for every deployment and every project.

## The layout every account has

```text
~/projects/
├── CLAUDE.md                 workspace instructions: one line and an import
│                             of agent-fabric/CLAUDE.md (written by bootstrap)
├── .claude/settings.json     the hooks, wired to the checkout below (bootstrap)
├── agent-fabric/             this repository — a checkout per account
└── <working copy>/…          the managed repositories the account works in
```

The account name identifies the agent (`bin/fabric-whoami`); the
directory it stands in identifies context, never identity.

## The steps, per account

**One command does all of it** (fabric-coordinator, from its own login;
the account steps go through `sudo`, the Doppler steps use the
coordinator's CLI token). It starts with a host audit: a Qubes AppVM
keeps only `/home` and `/usr/local` across a reboot, so the rpm tools
(git, gh, node, npm, python3, jq, gpg, podman, ImageMagick) are checked
and a missing one is named with its package for the TemplateVM; doppler
goes to `/usr/local/bin` once; the account's own tools go under its
`~/.local`:

```sh
runtime/provisioning/new-agent.sh <login> <role> [--project <id>]... [--dry-run]
runtime/provisioning/new-agent.sh brand-comms-01 brand-comms --project gzapi.ge --project gzapp.decks
```

Idempotent — every step is checked before it is done, so it is also how
an account that came out short is completed. In order: the Linux account
(home 700, the shared-cache group); the home skeleton, then `claude` and `ori`
installed as the account the way their vendors say (`claude.ai/install.sh`
on the vendor's latest — every account runs latest, the coordinator
included, and the fabric is fixed where latest breaks it; `--claude`
pins — and `openrouter.ai/labs/ori/install.sh`; an installer that fails
fails the script, nothing is copied from another account); GitHub's host key in
`known_hosts`; `~/projects/agent-fabric` over https (the fabric is
public; the account has no key yet); Doppler enrolment — `enroll.sh
<login>`, `fill-from <coordinator>`, then `issue-openrouter-keys` and
`issue-openai-keys` **once each** (a key of the account's own on each
API; presence in its config is the check) — and the first sync; every
`--project` cloned as the account over SSH from the remote the registry
names; `bootstrap.sh`; `bin/fabric-role bind <role>`; the toolchain each
project's lockfile declares (pnpm under `~/.local`, `pnpm install`,
`npm ci`, a venv); then verification (`fabric-secrets status`, `gh`, SSH
to every origin, the git identity, `launch --print` on both providers)
and the short list of what only a person at a terminal can do: the GPG
secret key (a passphrase prompt), `~/.claude/.credentials.json` for the
plain-claude path (a credential copy a classifier refuses an agent), and
the workspace-trust dialog at the first interactive launch. It was
written on 2026-09-15 after two accounts walked by hand came out short —
a missing binary, a root-owned `~/.local/bin`, an untrusted host key, no
toolchain, and a `fill-from` that copied the coordinator's admin keys.

What the steps are, when done by hand:

1. **Clone agent-fabric** beside the working copies:
   `git clone git@github.com:gzapi-org/agent-fabric.git ~/projects/agent-fabric`.
2. **Run bootstrap** as the account:
   `~/projects/agent-fabric/runtime/claude-code/bootstrap.sh`. It writes
   the workspace `CLAUDE.md` and `.claude/settings.json`, installs
   user-scope the capability-class agent files, the
   review class's Bash fence and the `subagent-dispatch` skill, and sets
   `core.hooksPath` on this checkout and on every registered working copy
   beside it (the attribution ban and the `.agent-fabric/` fence).
   Idempotent; re-run after pulling.
3. **Bind a role once**, as the account, from a login shell, inside its
   working copy: `~/projects/agent-fabric/bin/fabric-role bind <role>`
   (`tools/fabric/role.py`; refused inside a session). The binding lives
   under `${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/`;
   the launcher refuses to run without one and renders the role into the
   session's system prompt. A different role later is a rebind here and a
   relaunch.
4. **Enrol the identity's secrets** (fabric-coordinator, from its own
   login): `runtime/provisioning/secrets/enroll.sh <login>` — see
   "Secrets" below. After it, `OPENROUTER_API_KEY`, `GH_TOKEN`,
   `OPENAI_API_KEY` and the GZCoord token are in the account's
   environment from `~/.config/agent-fabric/secrets.env`, git identity
   and signing are set, and `runtime/openrouter/launch` (with the `ori`
   CLI on `PATH`) runs from the working copy
   (`runtime/openrouter/README.md`). `fill-from` never copies the
   coordinator's own credentials (`*_ADMIN_KEY`, `*_PROVISIONING_KEY`,
   `AGENT_FABRIC_READ_TOKEN`) nor a per-login name the registry declares
   under `agent_env` (the API keys, a port offset): those have their own
   steps.

`runtime/claude-code/provision-capability-classes.sh` does step 2's
agent-file part for every account at once, as root, when the class files
change. `moveto/` opens a shell as another account in its working copy.
`rename-working-copy.sh <login> <old> <new>` moves a working copy and
carries the account's Claude Code history with it — transcripts, memory,
`~/.claude.json` project entry, prompt history, the binding — since all of
it is keyed by the clone's absolute path (2026-09-14: every clone renamed
from `~/projects/<login>` to `~/projects/gzapp`; a live session, or a
tree mid-work, is refused).

## Secrets

An identity's secrets are recorded in **Doppler**, project `agent-fabric`,
**one config per Linux login**: the branch config `<env>_<login>` under
the environment `agents` — `agents2`, `agents3`, `agents4` once one holds
its ten configs (a Developer-plan project: four environments of ten
configs, so the login is the branch, never the environment; `enroll.sh`
records the name in the account's doppler config, `enclave.config` at
scope `/`, which is how `fabric-secrets` knows its own). Each account
holds exactly one bootstrap secret — a read-only
service token for its own config, in `~/.doppler/.doppler.yaml` — and
everything else is derived from it:

| name | consumed as |
|---|---|
| `AGENT_LOGIN`, `AGENT_HOST` | `fabric-secrets sync` refuses a config whose `AGENT_LOGIN` is not the login running it — the invariant, enforced at the secret boundary |
| `OPENROUTER_API_KEY`, `GH_TOKEN`, `CLAUDE_BRIDGE_AUTH_TOKEN` | exported from `~/.config/agent-fabric/secrets.env` (0600), sourced by `~/.bashrc` |
| `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_SIGNING_KEY`, `GIT_GPG_PROGRAM` | `git config --global` (strings; the signing key material stays in the keyring) |
| `SSH_PRIVATE_KEY`, `SSH_PUBLIC_KEY` | `~/.ssh/id_ed25519(.pub)`, written only when absent (`--force` replaces) |
| a project's `agent_env` names (`projects/registry.json`; gzapp: `GZAPP_PORT_OFFSET`) | exported from `secrets.env` when the config has them — per-login values that are not secrets but belong to the identity, never reported missing |

- `bin/fabric-secrets sync` (as the account) pulls and applies; `status`
  reports presence, modes and ages — neither prints a value.
- `secrets/enroll.sh <login>|--all` (coordinator) creates the config,
  migrates what the account holds today, issues the token, runs the first
  sync and, once verified, retires the old sources (the `.bashrc` export,
  the clone's `settings.local.json` entry, the `gh` stored login).
- Rotation: change the value in the Doppler dashboard, then
  `secrets/enroll.sh sync-all`. Revoking an agent is revoking one token.
- Keys of a login's own: `secrets/enroll.sh issue-openrouter-keys <login>…`
  (OpenRouter, with the coordinator's provisioning key in its config as
  `OPENROUTER_PROVISIONING_KEY`) and `issue-openai-keys <login>…` (OpenAI: a
  service account `agent-fabric-<login>`, with the coordinator's admin key
  as `OPENAI_ADMIN_KEY`; the key is minted once and goes API → Doppler).
  Both providers then report spend per key, i.e. per agent.
- A login enrolled with names missing (an account that never had a key)
  is completed with `secrets/enroll.sh fill-from <login> [targets…]`:
  copies into each target only the names it lacks and the source has,
  never the identity names, then syncs the targets. Copied values are
  shared values — spend and provenance on them follow the source's key
  until the target gets its own.
- The coordinator's own Doppler CLI token (workplace admin) is the only
  credential that can write the project; it lives in the coordinator's
  home and nowhere in this tree.

## What does not transfer between accounts

Session memory is the account's (`~/.claude/projects/…/memory/`); a drain
distils it into the corpus, nothing copies it across. Runtime bindings,
role history and local model overrides are per account for the same
reason: they say what *this* agent is doing.
