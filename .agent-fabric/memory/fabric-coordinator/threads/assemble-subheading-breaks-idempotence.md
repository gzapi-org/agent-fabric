---
role: "fabric-coordinator"
class: threads
topic: "assemble-subheading-breaks-idempotence"
description: "A claim whose body has its own `## ` headings is split at them on re-read: the first part loses its Observed date and the same memory collides with itself on the next drain"
tier: 2
knowledge_scope: full
distilled_at: "2026-09-26"
origin:
  - agent: user
    host: "develop-qzapp"
    project: "agent-fabric"
    working_copy: "fabric-na"
derived_from:
  - f528b0b9346eb0b8
---

## A claim whose body has its own `## ` headings is split at them on re-read: the first part loses its Observed date and the same memory collides with itself on the next drain

OPEN (found 2026-09-25, drain of that day). `tools/fabric/assemble.py`
renders a claim as one `## <heading>` section, and the body keeps any
`## ` lines the memory itself carried. `existing_sections()` then splits
the slice at every `## `, so the claim's first part has no
`*Observed … (role)*` line (it sits at the end of the LAST part) and its
text is cut short. Re-assembling the same bundle refuses both web-dev-01
slices `web-dev/solution/regime3-views-are-never-served-from-cache.md`
and `web-dev/threads/ru-severed-at-labels-a-date-with-a-state.md` as a
collision "in the corpus (observed undated)" with the author's own text.

Fix on the fabric's next branch. Either demote a body's `## ` to `### `
at render time, or split sections only on headings the index knows.
Test it by re-running one bundle twice and checking the tree is
byte-identical. [[assemble-not-idempotent-over-same-drain]] is the
earlier, different cause, which is fixed.

*References: assemble-not-idempotent-over-same-drain*

*Observed 2026-09-25 (fabric-coordinator)*
