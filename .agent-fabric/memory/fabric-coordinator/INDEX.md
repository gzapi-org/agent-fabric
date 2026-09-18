---
role: "fabric-coordinator"
class: index
description: "What fabric-coordinator knows and where it lives."
tier: 1
distilled_at: "2026-09-18"
---

# fabric-coordinator — knowledge index

Tier 1 — the charter and brief (in the launch prompt), this index
and every `workflow` slice (from the session-start hook) — is given
to a session at start. Every other section waits for a cue: open a
slice when its description matches what you are working on.
Paths are relative to this working copy; `../agent-fabric/` is the
control plane checked out beside it.

## charter

- [`identities/roles/fabric-coordinator/charter.md`](identities/roles/fabric-coordinator/charter.md) — Owns the control plane: agent-fabric's role definitions, catalogue, routing policy, authority rules and the GZCoord protocol; the only role that changes what other roles are.

## brief

- [`identities/roles/fabric-coordinator/brief.md`](identities/roles/fabric-coordinator/brief.md) — How fabric-coordinator works day to day: the control plane's only writer — roles, routing, policy, the protocol, the launch — changed in small verified commits, distributed to every account, never project truth.

## domain

- [`memory/shared/domain-claude-code-attribution-reminder.md`](memory/shared/domain-claude-code-attribution-reminder.md) — Where Claude Code's Co-Authored-By / Generated-with reminder comes from, what switches it off, and what a session that still sees one means (shared)

## recall

- [`identities/roles/fabric-coordinator/recall.md`](identities/roles/fabric-coordinator/recall.md) — How to ask the control plane about itself: status, routing, lint, migration records.
