---
role: "fabric-coordinator"
class: workflow
description: "Never `check | tail -1 && git commit`: the pipe's status is tail's, so a failed lint/static/suite still commits — run the check, capture rc=$?, commit only on 0"
tier: 1
knowledge_scope: full
distilled_at: "2026-09-25"
origin:
  - agent: user
    host: "develop-qzapp"
    project: "agent-fabric"
    working_copy: "agent-fabric"
derived_from:
  - 770bfec8bc900afd
---

## Never `check | tail -1 && git commit`: the pipe's status is tail's, so a failed lint/static/suite still commits — run the check, capture rc=$?, commit only on 0

Twice on 2026-09-25 a check failed and the commit went ahead anyway:
`python3 tools/fabric/lint.py 2>&1 | tail -1 && … git commit` (PR #35 opened
with lint red: the hosts schema refused operator_key) and
`bash tests/static.sh 2>&1 | tail -1 && git add … && git commit` (a
`.pathname` module URL the static guard forbids). The pipe's exit status is
`tail`'s, always 0. [[cross-repo-lint-window]] already said "no pipe before
the commit &&"; it was not enough as a clause inside another memory.

A third time the same day, a different shape: `…; bash tests/static.sh | tail -1;
git add … && git status; git commit` — the check ran, printed FAILED, and the
`;` after it let the commit go (unpushed, amended). The rule is not "no pipe"
but "the commit is gated on the check's own status in the same command".

**How to apply:** `bash tests/static.sh >/dev/null 2>&1; rc=$?; [ $rc -eq 0 ] && git commit …`
— every commit command, even a "small" one after a multi-step edit
— or `set -o pipefail` in the same command. Show the output separately if
it is needed. A test suite's summary line is read, not trusted by `&&`.

*References: cross-repo-lint-window*

*Observed 2026-09-25 (fabric-coordinator)*
