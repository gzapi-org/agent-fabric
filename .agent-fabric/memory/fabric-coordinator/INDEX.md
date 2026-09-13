---
role: "fabric-coordinator"
class: index
description: "What fabric-coordinator knows and where it lives."
tier: 1
distilled_at: "2026-09-13"
---

# fabric-coordinator — knowledge index

Tier 1 — the charter, this index, and every `workflow` slice —
loads at activation. Every other section waits for a cue: open a
slice when its description matches what you are working on.
Paths are relative to this working copy; `../agent-fabric/` is the
control plane checked out beside it.

## charter

- [`identities/roles/fabric-coordinator/charter.md`](identities/roles/fabric-coordinator/charter.md) — Owns the control plane: agent-fabric's role definitions, catalogue, routing policy, authority rules and the GZCoord protocol; the only role that changes what other roles are.

## recall

- [`identities/roles/fabric-coordinator/recall.md`](identities/roles/fabric-coordinator/recall.md) — How to ask the control plane about itself: status, routing, lint, migration records.
