---
role: "devex-tooling"
class: domain
description: "`gh pr merge --auto --merge` on gzapp prints what looks like a refusal, leaves autoMergeRequest null, yet DOES enqueue the PR."
tier: 2
knowledge_scope: full
distilled_at: "2026-09-18"
origin:
  - agent: "devex-tooling"
    host: "develop-qzapp"
    project: gzapp
    working_copy: gzapp
derived_from:
  - 796c6629674f5430
---

## `gh pr merge --auto --merge` on gzapp prints what looks like a refusal, leaves autoMergeRequest null, yet DOES enqueue the PR.

`main` in gzapi-org/gzapp is merge-queue managed, so the queue owns the merge
strategy. Passing a strategy flag anyway:

    gh pr merge <n> --auto --merge
    ! The merge strategy for main is set by the merge queue

That single line reads as a refusal, and `autoMergeRequest` stays **null**
afterwards — so the usual "verify it armed" check reports NOT ARMED. Both
signals point at failure. **The PR is nevertheless enqueued**: a follow-up
`gh pr merge <n> --auto` answers `already queued to merge`, and the GraphQL
`mergeQueueEntry` shows a real entry.

So `autoMergeRequest: null` does not mean "nothing will merge this" on a
queue-managed repo — auto-merge and a direct queue entry are two different
landing paths. Confirm with:

    gh api graphql -f query='query{repository(owner:"gzapi-org",name:"gzapp"){
      pullRequest(number:N){mergeQueueEntry{state position}}}}'

Also: `AWAITING_CHECKS` for many minutes is normal, not a stall — the
merge_group run takes ~12 minutes here. Compare against the run's COMPLETION
time, not its creation time, before diagnosing a stuck queue.

Belongs in the `pr-lifecycle` skill eventually; recorded here because the
session that found it could not commit.
