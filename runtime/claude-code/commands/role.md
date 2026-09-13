---
description: Activate a role for this agent — install its skills and load its knowledge (flutter-dev, backend-dev, db-admin, web-dev, edge-hosting, devex-tooling, architect-cto, product-i18n, domain-transit, gzcoord-coordinator)
argument-hint: "<role> | status | deactivate | <role> --force | <role> --project <id>"
allowed-tools: Bash(python3 __AGENT_FABRIC_ROOT__/tools/fabric/role.py:*), Read
---

## Activate

<!-- __AGENT_FABRIC_ROOT__ is substituted by runtime/claude-code/bootstrap.sh: the
     command runner refuses shell parameter expansion, so the path is literal. -->

!`python3 __AGENT_FABRIC_ROOT__/tools/fabric/role.py $ARGUMENTS`

## Now load the role

If the activator reported a role (rather than a refusal or a status
listing), **read the files it listed under "load now"** before doing
anything else. That is the whole activation: a charter that says what is
yours and what is not, an index of what this role knows about the current
project, and the workflow it actually uses there.

Then work normally. **Do not read the rest of the role's memory now.** The
index exists so that knowledge stays out of context until something calls
for it — when you touch a subject whose index line matches, open that one
slice and no more.

Four things worth knowing while you hold a role:

- **You are still the same agent.** The role changed; your name — the
  Linux login the activator printed — did not, and neither did the
  project or working copy you are in. Another agent may hold the same
  role at the same time.
- **The installed skills are copies, and copies are working state.**
  Adapting a role's skill in this workspace is allowed and persists. If
  the change deserves to outlive this workspace, put it in
  `identities/roles/<role>/` in agent-fabric through a normal pull request.
- **`rationale` is a staging area, not an authority.** Where it disagrees
  with an active ADR or contract in the project, the project wins and the
  disagreement is a finding worth reporting.
- **`solution` decays.** It describes what was true when it was distilled,
  and the frontmatter says when. Where it conflicts with the tree, the tree
  is the fact — and the drift is worth recording.

If the activator refused, it will have said why: either a copy was adapted
here and would be lost, or a name would shadow a committed skill. Both want
a decision rather than a retry.
