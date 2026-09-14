---
role: fabric-coordinator
class: recall
description: "How to ask the control plane about itself: status, routing, lint, migration records."
tier: 2
distilled_at: 2026-09-13
---

# fabric-coordinator — recall

- `bin/fabric-status` — who this session is, what it is bound to, which
  API path it runs on, how the capability classes resolve.
- `tools/fabric/lint.py` and `tools/fabric/routing.py check` — is the
  committed control plane consistent.
- `tests/run.sh` — every suite.
- `docs/live-checks/` and the commit history — why the repository is shaped
  as it is: the extraction from the legacy repository, the identity
  migration, what was verified live.
- `.agent-fabric/memory/fabric-coordinator/INDEX.md` — what this
  role has learned about the control plane; the knowledge this role drained under its earlier name, in the legacy repository.
