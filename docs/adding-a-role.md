# Adding a role — the order that breaks nobody's CI

A role is three commits in two repositories, and every managed project's
CI runs this repository's lint at `main` against its own working copy.
The order below is the one where no intermediate state fails a project
that never holds the role. Learned on 2026-09-17: `p2p-network-dev`'s
first domain slices landed here before the project that indexes them
had merged its `.agent-fabric/`, and every merge-queue run of an
unrelated project failed for an hour (relay seq 1076) — the lint judged
every domain whenever any project was visible. It now judges a domain
only where a visible project's taxonomy binds the role
(`tools/fabric/lint.py`, `case_domain_bound_by_an_unseen_project_is_not_judged`),
so the fabric-first order is safe; the order is still the rule, because
the guard covers one shape of the mistake and not the next.

1. **Here, one commit: the role.** `identities/roles/<role>/charter.md`
   and `recall.md` (a `brief.md` when there is a holder's account to
   distil), the catalogue entry, the placement in
   `runtime/hosts/registry.json`, and — for a new project — its
   `projects/registry.json` entry and `projects/<id>/integration/`.
   `tests/run.sh` green; push. Nothing here names the project in a
   generic file (lint refuses it); the project's remit is where the
   project appears.
2. **In the project, one PR: the binding.** `.agent-fabric/taxonomy.json`
   with the role's paths and keywords, `.agent-fabric/roles/<role>.md`
   (the remit), and `.agent-fabric/memory/<role>/INDEX.md` listing the
   charter, the recall and the brief in the assembler's line format.
   Lint it from here with `--working-copy <id>=<checkout>` before the
   PR opens; the project's own checks may need to skip `.agent-fabric/`
   (its links are working-copy-relative and reach `../agent-fabric/`).
   Merge it.
3. **The drain, once, both sides.** `harvest_memory.py --role <role>
   --working-copy <checkout> --all --out <drain>`, then `assemble.py
   --claims <drain>/claims --drain <drain> --project <id> --working-copy
   <checkout> --stamp <date>`: the domain slices land under
   `memory/domains/<role>/` here, the system slices and the regenerated
   `INDEX.md` in the project. Commit the project side first (its index
   links the domain slices by path that resolves through
   `../agent-fabric/`, so its CI needs the fabric commit — push the
   fabric commit before the project PR's checks run). Never run the
   assembler twice over the same drain: it duplicates every slice as
   `<name>-2`; restore and re-run, or edit the index by hand for a
   hand-authored addition.
4. **The account.** `runtime/provisioning/new-agent.sh <login> <role>
   --project <id>`; what it leaves for a person (the signing key, the
   credentials file, the first interactive launch) it prints at the end.
   The account is persisted across the host's reboot in the same run.

What breaks when the order is wrong: a domain slice here with no index
anywhere → nothing now, a lint finding on the binding project's CI once
its taxonomy binds the role; an index in a project pointing at a domain
slice not yet on `main` here → that project's CI fails on a dangling
link; a project remit naming a role not in the catalogue → that
project's lint finding. In every case the fix is to land the missing
half, never to loosen the lint.
