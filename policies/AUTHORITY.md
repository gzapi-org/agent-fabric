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
| `identities/roles/<role>/charter.md` (any role) | `fabric-coordinator` | `policies/check_charter_authority.sh` |
| `identities/roles/catalog.json` | `fabric-coordinator` | same |
| `projects/<project>/taxonomy.json` (where roles apply in a repository) | `fabric-coordinator` | same |
| `routing/policies/review-grade.json`, the review class's model | `fabric-coordinator` | same; `tools/fabric/lint.py` and `runtime/openrouter/launch` refuse a profile outside it |
| `policies/authority.json`, who holds `fabric-coordinator` | `fabric-coordinator` | same, read from the base side of the diff so a branch cannot appoint itself |
| `communication/gzcoord/protocol/*` | `fabric-coordinator`, and `gzcoord-coordinator` as the narrower protocol role | no tripwire yet — both charters state it |
| a managed project's architecture (gzapp: ADRs, contracts) | that project's roles (`architect-cto`) | the project's own guards, in its repository |
| a distilled slice under `memory/` | any agent, through a drain (`memory/README.md`) | `tools/fabric/lint.py` demands provenance |
| `recall.md` for a role | the role itself | authored, exempt from provenance; must stay under `identities/roles/` |

## What the tripwire can and cannot do

`check_charter_authority.sh` reads the agent segment of the branch name
(`<host>/<agent>/<type>/<desc>`) and passes a recognised holder of
`fabric-coordinator`: a login listed in `policies/authority.json` (at the
base of the diff, never the branch's own copy) or an account named for the
role.
Every session pushes as the same GitHub account, so there is no identity
to check; the branch name is self-declared. This is a **tripwire**: it
stops the accident and the absent-minded edit, and it makes a deliberate
change visible in review. A session that means to route around it can,
by naming its branch differently, and nothing in this repository would
catch that. It also does not confuse the two questions above: an agent
named `flutter-dev-02` editing `flutter-dev`'s charter is refused, and so
is `architect-cto-01` — gzapp's architecture authority is not the control
plane's (`test_check_charter_authority.sh`).

## What did not weaken in the migration

- The charter and taxonomy authority rule, and its tripwire, moved from
  `tools/checks/` to `policies/`, widened to the catalogue, every
  project's taxonomy, the routing policies and the holders file. The
  owning role changed from `architect-cto` (gzapp's architecture role,
  which owned charters only because they lived in gzapp) to
  `fabric-coordinator`, the role whose remit is this repository.
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
