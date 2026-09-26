---
role: "fabric-coordinator"
class: threads
topic: "drain-report-last-run-wins"
description: "A multi-bundle drain writes last-drain-report.json once per assemble run — the last run wins: earlier runs' collision_decisions are lost and an index-only run empties the watermarks"
tier: 2
knowledge_scope: full
distilled_at: "2026-09-26"
origin:
  - agent: user
    host: "develop-qzapp"
    project: "agent-fabric"
    working_copy: "fabric-na"
derived_from:
  - 706c2df1196b7349
---

## A multi-bundle drain writes last-drain-report.json once per assemble run — the last run wins: earlier runs' collision_decisions are lost and an index-only run empties the watermarks

OPEN (found 2026-09-25). A drain across accounts is one
`assemble.py --bundle` per account into the same working copy, and each
run rewrites `.agent-fabric/memory/last-drain-report.json` whole. The
committed report describes only the last bundle. `collision_decisions`
applied by earlier runs are gone, which contradicts memory/README.md's
statement that "every applied decision is recorded". An index-only
refresh (empty claims for a role, which is how gzapp.decks and gzapi.brand
re-list brand-comms' domain slice) writes `"watermarks": {}`.

The workaround used that day: end each project with a real bundle run
so the watermark is real, restore the report in index-only repositories
(`git checkout -- last-drain-report.json`), and list the owner's
decisions in the commit and PR text. The fix belongs on the next branch.
Either merge into the existing report (watermark max per host, decisions
appended, per-role telemetry keyed by agent), or accept several bundles
in one run. Add an index-only mode that leaves the report alone. See
[[assemble-subheading-breaks-idempotence]].

*References: assemble-subheading-breaks-idempotence*

*Observed 2026-09-25 (fabric-coordinator)*
