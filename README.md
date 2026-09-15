# agent-fabric

The control plane for the Claude Code (and, later, other-harness)
agents that work on the repositories beside it. It holds agent
infrastructure — identities, roles, memory, model routing, agent-to-agent
communication, policy — and nothing about what any project builds.

```text
Linux login identifies the agent.
Filesystem location identifies context, never identity.
```

```text
project repositories contain project truth
agent-fabric contains agent infrastructure
```

## Eleven independent dimensions

| dimension | the question | where the answer lives |
|---|---|---|
| **AGENT IDENTITY** | Which Linux user is this agent? | `runtime/identity.py` — `pwd.getpwuid(os.geteuid())`, nothing else; `bin/fabric-whoami` |
| **ROLE** | What function is this agent currently performing? | `identities/roles/<role>/` (charter, recall, skills); the catalogue `identities/roles/catalog.json`; bound at runtime by `tools/fabric/role.py` (`/role`) |
| **MEMORY** | What durable knowledge can it retrieve? | `memory/domains/`, `memory/agents/<login>/`, `memory/shared/` here; `<working copy>/.agent-fabric/memory/<role>/` in each project — generated indexes, provenance, tiered loading (`memory/README.md`) |
| **PROJECT** | Which logical system is it working on? | `projects/registry.json`, matched from a working copy's remote by `tools/fabric/workingcopy.py` |
| **WORKING COPY** | Which filesystem/Git checkout is being used? | the cwd's git toplevel, recorded in the agent's runtime binding as a path and a label |
| **CAPABILITY** | How much reasoning does a task require? | `routing/capabilities.json` classes: `code-low`, `code-medium`, `code-high`, `review` |
| **MODEL ROUTING** | Which concrete model satisfies that capability now? | `routing/capabilities.json` providers, layered by `routing/profiles.json` (per role, per login) |
| **COMPATIBILITY** | What shim does that model family need for this harness? | `routing/shims.json` — today only `z-ai/glm-*` → `@preset/glm2claude-shim` |
| **COMMUNICATION** | How do independent agents exchange work and knowledge? | `communication/gzcoord/` — GZCOORD/1; the address is `<host>/<login>` |
| **PROJECT BINDING** | Which roles, domains and path rules apply to each managed repository? | `<working copy>/.agent-fabric/taxonomy.json` in the project itself (`projects/registry.json` names the project); the fabric's own is `.agent-fabric/taxonomy.json` here |
| **RUNTIME ADAPTER** | How does all of this become Claude Code / OpenRouter / another harness's configuration? | `runtime/claude-code/` (hooks, `/role`, agent files, bootstrap), `runtime/openrouter/launch`, `runtime/provisioning/` |

Never collapse them. An agent keeps its name across roles, projects,
working copies, hosts and sessions. Two agents in one working copy are
two agents. A role is held by any number of agents at once.

## How a session starts

```sh
cd ~/projects
claude
```

`projects/CLAUDE.md` (three lines, written by
`runtime/claude-code/bootstrap.sh`) imports `agent-fabric/CLAUDE.md`. The
workspace `.claude/settings.json` runs `runtime/claude-code/hooks/session-start.sh`,
which asks the OS who is running, records the working copy and project
the session is in, and prints one context line. `/role <role>` binds a
role to the agent and installs that role's skills into the workspace.
Every sibling repository keeps its own `CLAUDE.md`; `projects/` is not a
git repository.

Through OpenRouter: `agent-fabric/runtime/openrouter/launch` resolves the
capability classes to concrete models, attaches family shims, exports the
composites, and execs `ori claude` — see `runtime/openrouter/README.md`.

## Runtime state

Never in this repository. Per agent, under
`${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/`:
`binding.json` (role, project, working copy, session),
`role-history.jsonl`, `model-profile.local.json` (the agent's own model
choices per provider; `bin/fabric-model`). Credentials stay in
each account's shell environment.

## Provenance

Every distilled slice records who learned it (`agent`), where (`host`,
`working_copy`), what it applies to (`project`, the role, the class) and
when (`distilled_at`, the observation hashes). Slices from before the
identity migration carry the old `clone_id` as a label; nothing resolves
it any more, and a slice that names one is simply older than the login
model.

## Origin

This infrastructure began inside one managed repository and was
extracted with `git filter-repo` into a control plane of its own; before
it went public its history was rewritten once more so that no commit
carries that project's knowledge or names its internals. The record of
the extraction is not kept: what it explained, this repository now
states. `docs/live-checks/` holds what was verified live here.

## One-call status

```sh
agent-fabric/bin/fabric-status        # agent, binding, API path, pins, capability resolution, routing health
```

## Tests

```sh
tests/run.sh
```

## License

**Apache-2.0**, throughout (`LICENSE`; `REUSE.toml` assigns nothing else,
and `reuse lint` passes). A managed project's knowledge lives in the
project's own repository (`<working copy>/.agent-fabric/memory/`) under
that project's license and is never here; `projects/<id>/` holds a
project's binding and integration material, which is this repository's.
`projects/registry.json` records each project's own license as
information. `tools/fabric/lint.py` refuses a second license in
`REUSE.toml`, a project with no stated license, and any project
knowledge under `memory/projects/`.
