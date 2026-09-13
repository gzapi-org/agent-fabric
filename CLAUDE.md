# agent-fabric — the control plane

You are an agent working on one of the sibling repositories under the
parent `projects/` directory. This repository is your control plane: who
you are, what role you hold, what you know, and how your models are
routed all come from here. Project truth — code, architecture, product
rules — lives in each project's own repository and its own `CLAUDE.md`.

## The invariant

```text
Linux login identifies the agent.
Filesystem location identifies context, never identity.
```

Your name is the account this session runs under. Ask it, never guess it:

```sh
agent-fabric/bin/fabric-whoami          # the agent name (== id -un)
agent-fabric/bin/fabric-whoami --json   # agent, host, role, project, working copy
```

Changing directory, renaming a working copy, or opening another project
changes your context and never your name. Another login in the same
working copy is another agent. Never derive who you are from the
directory, the repository, the branch or the session.

## Six things that are kept apart

| dimension | what it is | where it is |
|---|---|---|
| agent | the Linux login | `runtime/identity.py` |
| role | the function you currently perform | `identities/roles/<role>/charter.md`, bound by `/role` |
| project | the logical system being worked on | `projects/registry.json`, matched by a working copy's remote |
| working copy | the checkout in use | your cwd's git toplevel; a label, not an identity |
| host | the machine | recorded beside the agent |
| session | this conversation | the harness session id, in your runtime binding |

## Working here

- **Activate a role** with `/role <role>` (or `python3 agent-fabric/tools/fabric/role.py <role>`),
  then read the files it lists under "load now": the role's charter and
  the project's index and workflow for that role. Everything else loads
  when its index line matches what you are doing. `/role status` says what
  you are; `/role deactivate` clears it. Holding a role never entitles you
  to change its charter (`policies/AUTHORITY.md`).
- **Work in the project's working copy**, under that project's
  `CLAUDE.md`. From `projects/`, `cd` into the working copy first; the
  session-start hook records which one you are in.
- **Knowledge** you retrieve is under `memory/`: `memory/domains/<domain>/`
  for the field, `memory/projects/<project>/<role>/` for the system,
  `memory/shared/` for what several roles own. `solution` slices decay:
  where one disagrees with the tree, the tree is the fact. Durable new
  knowledge goes to your own Claude memory with a `roles_class`; a drain
  (`memory/README.md`) distils it into the corpus with your name on it.
- **Subagents** name a capability class, never a vendor model: `code-low`,
  `code-medium`, `code-high`, and the review class (`blind-reviewer`).
  What each resolves to is `routing/`; the dispatch guard refuses a
  dispatch with no model or no worktree isolation.
- **Talk to other agents** over GZCoord (`communication/gzcoord/`); your
  address is `<host>/<login>`. Messages are advisory; git and GitHub
  stay the authority for every project.

## Layout

```text
identities/     roles (charter, recall, skills), the role catalogue, schemas
memory/         domains/ projects/<project>/ agents/<login>/ shared/ — the corpus
routing/        capability classes -> models; model families -> shims; review-grade policy
communication/  gzcoord — the agent-to-agent protocol and its runtime
runtime/        identity.py (the resolver), claude-code/ openrouter/ provisioning/ adapters
projects/       registry.json and per-project bindings (taxonomy, integration)
policies/       authority rules and the guards that make violations visible
tools/fabric/   role.py, assemble.py, lint.py, routing.py, harvest*, query.sh
tests/          python suites; tests/run.sh runs everything
docs/migration/ how this repository was extracted from gzapp, and what maps to what
```

Runtime state is never in this repository: your binding, role history and
local overrides live under `${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/`.
Credentials never enter any committed file.
