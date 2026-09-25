---
role: "language-culture"
class: domain
description: "По-русски merge ветки/PR — «вливать», не «сливать»: «сливать» в разговорной речи значит «провалить, сдать», ровно наоборот"
tier: 2
knowledge_scope: full
distilled_at: "2026-09-25"
origin:
  - agent: "language-culture-ru"
    host: "develop-qzapp"
    project: gzapp
    working_copy: gzapp
derived_from:
  - 9da6cee0d182f51a
---

## По-русски merge ветки/PR — «вливать», не «сливать»: «сливать» в разговорной речи значит «провалить, сдать», ровно наоборот

In Russian text the fleet writes, "merge" (a branch, a PR) is rendered with the verb "вливать", never "сливать": in spoken Russian "сливать" means "to throw away, to fail, to give up" ("слить проект"), so "the coordinator сливает the PR" reads as the opposite of what is meant. The noun "слияние" carries no such ambiguity and stays. Found by the locale worker's first pass on the charter (agent-fabric PR #6, commit ea88d67, 2026-09-18); applied across `identities/roles/language-culture/locale/ru/`. Applies to every Russian text the fleet writes — charters, briefs, slices, dictionaries, UI copy.

*Observed 2026-09-18 (language-culture)*
