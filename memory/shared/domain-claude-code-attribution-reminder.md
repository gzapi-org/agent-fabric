---
role: shared
class: domain
description: "Where Claude Code's Co-Authored-By / Generated-with reminder comes from, what switches it off, and what a session that still sees one means"
tier: 2
knowledge_scope: full
shared_with:
  - "architect-cto"
  - "backend-dev"
  - "brand-comms"
  - "db-admin"
  - "devex-tooling"
  - "domain-transit"
  - "edge-hosting"
  - "fabric-coordinator"
  - "flutter-dev"
  - "language-culture"
  - "p2p-network-dev"
  - "web-dev"
distilled_at: "2026-09-18"
origin:
  - agent: user
    host: "develop-qzapp"
    project: "agent-fabric"
    working_copy: "agent-fabric"
derived_from:
  - ac0cb84ddea8bc65
---

## Where Claude Code's Co-Authored-By / Generated-with reminder comes from, what switches it off, and what a session that still sees one means

The system reminder asking to end commits with a `Co-Authored-By`
trailer and pull requests with a "Generated with Claude Code" footer is
the harness's own, not part of any launch prompt or CLAUDE.md. Claude
Code builds it from the `attribution` key of the settings (`commit`,
`pr`, `sessionUrl`; `includeCoAuthoredBy` is the deprecated form),
with the current model's name spliced in, and sends it as a system
reminder on the first turn and again after every model switch — only
when the session has the Bash tool, and untouched by
`--system-prompt-file`. An empty text hides each line ("Empty string
hides attribution", the harness's own schema): with
`attribution: {"commit": "", "pr": "", "sessionUrl": false}` a fresh
session gets no request for a trailer — on build 2.1.276 the opposite
reminder ("do not add attribution lines"), on 2.1.277 none at all.

In the fabric that key is written into every account's user settings
by `runtime/claude-code/bootstrap.sh` (`attribution-off.py`,
agent-fabric PR #13, 2026-09-18), so it reaches every working copy the
account holds; a session that still sees the old reminder was launched
from an account that has not pulled and bootstrapped, or outside the
fabric with default settings. The rule — no machine attribution — and
the guard `ban_generated_by_attribution.sh` hold in either case; the
switch removes the temptation, not the fence. Read-backs:
`docs/live-checks/2026-09-18-attribution-reminder-off.md`.
