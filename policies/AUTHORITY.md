# Authority

Who may change what in agent-fabric, and why that is not the same
question as who is currently doing what.

## The distinction

```text
an agent operating WITHIN a role's charter      -> the role's runtime binding
who may REDEFINE that charter                   -> a policy, attached to a role
```

An agent holds a role by binding it (`/role`, `tools/fabric/role.py`).
Holding a role gives the agent that role's remit for its work. It gives
the agent nothing over the role's definition: a `flutter-dev` instance
does not widen `flutter-dev`'s charter, and the account it runs under is
irrelevant to the question. Authority attaches to roles and to policy
files, never to Linux logins and never to directories, unless a policy
explicitly names one.

## The rules

| what | who may change it | how it is made visible |
|---|---|---|
| `identities/roles/<role>/charter.md` (any role) | `architect-cto` | `policies/check_charter_authority.sh` |
| `identities/roles/catalog.json` | `architect-cto` | same |
| `projects/<project>/taxonomy.json` (where roles apply in a repository) | `architect-cto` | same |
| `communication/gzcoord/protocol/*` | `gzcoord-coordinator` | no tripwire yet — `identities/roles/gzcoord-coordinator/charter.md` states it |
| `routing/policies/review-grade.json`, the review class's model | `architect-cto` | `tools/fabric/lint.py` and `runtime/openrouter/launch` refuse a profile outside it |
| a distilled slice under `memory/` | any agent, through a drain (`memory/README.md`) | `tools/fabric/lint.py` demands provenance |
| `recall.md` for a role | the role itself | authored, exempt from provenance; must stay under `identities/roles/` |

## What the tripwire can and cannot do

`check_charter_authority.sh` reads the agent segment of the branch name
(`<host>/<agent>/<type>/<desc>`) and passes an `architect-cto*` agent.
Every session pushes as the same GitHub account, so there is no identity
to check; the branch name is self-declared. This is a **tripwire**: it
stops the accident and the absent-minded edit, and it makes a deliberate
change visible in review. A session that means to route around it can,
by naming its branch differently, and nothing in this repository would
catch that. It also does not confuse the two questions above: an agent
named `flutter-dev-02` editing `flutter-dev`'s charter is refused
(`test_check_charter_authority.sh`, "an agent HOLDING a role does not own
its definition").

## What did not weaken in the migration

- The charter and taxonomy authority rule, and its tripwire, moved from
  `tools/checks/` to `policies/` unchanged in force, widened to the
  catalogue and to every project's taxonomy.
- The review-grade gate moved from "the opus tier" to "the review
  capability" and is enforced in the same two places (lint on the
  committed files, the launcher on the merged result).
- The no-model-pins guard on committed settings is unchanged
  (`policies/check_repo_settings_carry_no_model_pins.sh`); the launcher
  fences the same scopes at launch and additionally refuses
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`.
- GZCoord's separation of identity claims from authentication is
  unchanged (`docs/migration/gzcoord-addressing.md`).
- The dispatch guard still denies a subagent with no model or no worktree
  isolation and asks on a premium model.

## Proposing a change

Open a pull request touching only the file in question, say what the
role is being asked to take on or give up, and leave it for the role
that owns it. Do not self-approve on the grounds of being the only
session that understands the surface; that is the argument these rules
exist to refuse.
