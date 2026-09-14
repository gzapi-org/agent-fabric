---
role: "devex-tooling"
class: domain
description: "Inside a reusable workflow, github.event_name reflects the CALLING workflow's event"
tier: 2
knowledge_scope: "domain-only"
distilled_at: "2026-08-10"
origin:
  - clone_id: "clone-948c9fcd4da94057"
    host: "develop-qzapp"
  - clone_id: unresolved
    host: "develop-qzapp"
derived_from:
  - 0eb9458052405327
  - 2d508d12807af565
  - b00c726f217a6d52
---

## Inside a reusable workflow, github.event_name reflects the CALLING workflow's event

A `workflow_call` job's `github.event_name` is not a synthetic "reusable-workflow" value — it's whatever event started the top-level (orchestrator) workflow. A manual `workflow_dispatch` run of an orchestrator (here, a release gate) arrives inside every child reusable workflow as `workflow_dispatch`, not as `push` or `merge_group`. A step condition written as `github.event_name == 'merge_group' || github.event_name == 'push'` — a reasonable way to gate an expensive build step to "real" triggers — silently skips on a manual dispatch instead of matching, and if the skip branch reports success (e.g. an echo/no-op step), the whole release gate can go green having never actually built the artifact it exists to verify. Any condition gating a step by event type needs to explicitly enumerate every event that can reach that reusable workflow, including manual dispatch of its caller.

*References: ADR-047*
