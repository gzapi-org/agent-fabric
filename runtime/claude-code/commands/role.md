---
description: Become a role in this working copy — install its skills and load its knowledge (flutter-dev, backend-dev, db-admin, web-dev, edge-hosting, devex-tooling, architect-cto, product-i18n, domain-transit, gzcoord-coordinator)
argument-hint: "<role> | --status | <role> --force"
allowed-tools: Bash(python3 tools/roles/switch.py:*), Bash(python3:*), Read
---

## Switch

!`python3 "${CLAUDE_PROJECT_DIR:-.}/tools/roles/switch.py" $ARGUMENTS`

## Now load the role

If the switch reported a role (rather than a refusal or a status listing),
**read the files it listed under "load now"** before doing anything else.
That is the whole activation: a charter that says what is yours and what
is not, an index of what this role knows, and the workflow it actually
uses.

Then work normally. **Do not read the rest of the role folder now.** The
index exists so that knowledge stays out of context until something calls
for it — when you touch a subject whose index line matches, open that one
slice and no more. A role that loaded everything up front would cost more
than it saves, which is the failure the two tiers exist to avoid.

Three things worth knowing while you hold a role:

- **The slices are copies, and copies here are working state.** Adapting a
  role's skill inside this working copy is allowed and it persists. If the
  change deserves to outlive this clone, put it in `.roles/<role>/` through
  a normal pull request so every future instance of the role inherits it.
- **`rationale` is a staging area, not an authority.** Where it disagrees
  with an active ADR or contract, the ADR wins and the disagreement is a
  finding worth reporting.
- **`solution` decays.** It describes what was true when it was distilled,
  and the frontmatter says when. Where it conflicts with the tree, the tree
  is the fact — and the drift is worth recording.

If the switch refused, it will have said why: either a copy was adapted
here and would be lost, or a name would shadow a committed skill. Both want
a decision rather than a retry.
