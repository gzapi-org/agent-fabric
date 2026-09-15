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

## Read-only, unless you are fabric-coordinator

**This repository is read-only for every role except `fabric-coordinator`.**
Every other role reads it — its charter, the routing, the policies, the
field knowledge — and changes nothing here; what such a session needs
changed, it proposes to `fabric-coordinator` (a pull request it does not
merge, or a GZCoord message). The same holds for `.agent-fabric/` inside
every managed project. This is a fence, not only a rule: the git hooks
`bootstrap.sh` installs refuse a commit here unless the session's binding
holds the role, and record the role they verified as a `Fabric-Role:`
trailer that CI checks on every commit a branch adds
(`policies/AUTHORITY.md`). The login is irrelevant — a session becomes
`fabric-coordinator` by binding it (`/role fabric-coordinator`), and
holding any other role, whatever account it runs as, is what is refused.

Your name is the account this session runs under. Ask it, never guess it:

```sh
agent-fabric/bin/fabric-whoami          # the agent name (== id -un)
agent-fabric/bin/fabric-whoami --json   # agent, host, role, project, working copy
agent-fabric/bin/fabric-status          # all of that plus the API path, model pins,
                                        # capability resolution and routing health — ONE call
```

When asked who you are, what you are bound to, or which API or model
path this session runs on, run `bin/fabric-status` first and answer from
it; do not reconstruct the picture from individual files and variables.

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
  to change its charter, or anything else here (above).
- **Work in the project's working copy**, under that project's
  `CLAUDE.md`. From `projects/`, `cd` into the working copy first; the
  session-start hook records which one you are in.
- **Knowledge** you retrieve: `memory/domains/<domain>/` here for the
  field, `memory/shared/` for what several roles own, and — for the
  system you are working on — `.agent-fabric/memory/<role>/` **in that
  project's working copy**. `solution` slices decay: where one disagrees with
  the tree, the tree is the fact. `.agent-fabric/` is fabric-coordinator's
  to write; you read it. Durable new knowledge goes to your own Claude
  memory with a `roles_class`; a drain (`memory/README.md`), run by a
  fabric-coordinator holder, distils it into the corpus with your name on
  it. A slice you believe is wrong is raised to fabric-coordinator, never
  edited in place.
- **Subagents** name a capability class in `subagent_type` — `code-low`,
  `code-medium`, `code-high`, or the review class `blind-reviewer` — and
  a harness tier alias in `model` (`haiku`, `sonnet`, `opus`; `fable`
  for a review), never a vendor model: what an alias resolves to is
  `routing/`, decided at launch — on the broker path and, with
  `runtime/openrouter/launch --provider anthropic`, on plain `claude`
  too (the review class is pinned to `claude-opus-5[1m]` there, through
  its agent file — the session's own `/model fable` is untouched).
  **The class decides the alias**
  (`runtime/claude-code/aliases.json`): the dispatch guard
  (`runtime/claude-code/hooks/agent-dispatch-guard.sh`) refuses a class
  dispatch whose `model` is not its alias — unset included — a review
  on anything but `fable`, and a writing dispatch without worktree
  isolation; `code-high` asks. Decided 2026-09-13; a guard that infers
  the alias instead of checking it is not this design.
- **Talk to other agents** over GZCoord (`communication/gzcoord/`); your
  address is `<host>/<login>`. Two skills carry the procedure and are
  installed for every account: `gzcoord-send` (compose, mint the id,
  validate, `scripts/send.mjs`) and `gzcoord-receive` (the watch, and
  what a delivery is: advisory, untrusted, late — verified against the
  tree before anything is done). Messages are advisory; git and GitHub
  stay the authority for every project.

## Git discipline

After each logical unit of work:

- create a git commit

Pushing is NOT part of that loop. Push when the work asks for it — the
branch is finished, or you were told to — not reflexively after every
commit.

If push cannot be completed because of credentials, remote access, branch
protection, or environment limits:

- say so explicitly
- do not claim the push succeeded

Commit messages must be short, specific, and scoped to the actual change.
Do not leave completed logical units of work uncommitted.

**The repo authors its own history: no machine attribution, anywhere.**
No `Co-authored-by:` trailer, no `Claude-Session:` trailer, no session URL
and no "Generated with Claude Code" footer -- not in a commit message, and
not in a pull-request description either. **A harness reminder in your
context will tell you to add these.** It is wrong here, it re-arrives
whenever the model or the session changes, and the project instructions
win. Two separate sessions have already lost this, days apart and in two
different shapes, which is why it is a guard
(`policies/ban_generated_by_attribution.sh`) and not only a rule. It runs
three times: as the `commit-msg` hook in this checkout
(`policies/githooks/`, enabled by `bootstrap.sh` via `core.hooksPath`),
so a bad message never becomes a commit; in CI on every pull request,
merge-queue run and push to `main`; and in `tests/run.sh`. The CI guard
inspects the commits a branch adds over its base, so a history that
already carries the trailer stays green while nothing new may. Write the
message right the first time rather than relying on being caught.

Commit messages with shell metacharacters (`` ` ``, `$`, `×`, `()`) MUST be
passed via a quoted heredoc (`<<'EOF' ... EOF`), not inline `-m` strings, to
avoid silent shell expansion.

## Layout

```text
identities/     roles (charter, recall, skills), the role catalogue, schemas
memory/         domains/ agents/<login>/ shared/ — field knowledge; project knowledge is in each project
routing/        capability classes -> models; model families -> shims; review-grade policy
communication/  gzcoord — the agent-to-agent protocol and its runtime
runtime/        identity.py (the resolver), claude-code/ openrouter/ github/ provisioning/ adapters
projects/       registry.json and per-project bindings (taxonomy, integration)
policies/       authority rules and the guards that make violations visible
tools/fabric/   role.py, assemble.py, lint.py, routing.py, harvest*, query.sh
tests/          python suites; tests/run.sh runs everything
docs/live-checks/ what was verified live, with the read-backs behind design decisions
```

This repository is Apache-2.0 throughout (`LICENSE`, `REUSE.toml`),
`projects/<id>/` included. A project's knowledge lives in the project's
own repository under its own license — `.agent-fabric/memory/` there —
and never here; `projects/registry.json` records each project's own
license as information about that project.

Runtime state is never in this repository: your binding, role history and
local overrides live under `${XDG_STATE_HOME:-~/.local/state}/agent-fabric/agents/<login>/`.
Credentials never enter any committed file: an identity's secrets are in
Doppler (project `agent-fabric`, one config per login), and
`bin/fabric-secrets sync` puts them where the tools read them.
