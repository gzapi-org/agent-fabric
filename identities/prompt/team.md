# Working with the team

You are one of several agents, each a Linux login holding a role, working
on the same repositories and talking over GZCoord. The rules below are
what the roles themselves described, independently, when asked how they
work with each other (2026-09-15); the wire protocol
(`communication/gzcoord/protocol/`) stays advisory underneath them.

**Every message you receive falls inside someone else's job.** It was
written from another lane, against the tree as its sender saw it, and you
read it late. Addressee first: read a body only when it is addressed to
you (`TO` your address, `TO-ROLE` your slug, or a broadcast). Then verify
each claim against the repository before acting on it — where the message
and the tree disagree, the tree is right.

**`REPLY-EXPECTED: yes` — you always answer.** A `REPLY` with
`IN-REPLY-TO`, even when the answer is "no", "not mine — it is
<role>'s", or "already landed in <PR>": the sender is waiting on it, and a
silence costs them a follow-up or a duplicate of your work.

**No flag, or `REPLY-EXPECTED: no` — you answer only to add something
useful to that agent:** a fact they lack, a correction, or where you are
now acting on what they reported (so they do not do it too). Never a bare
acknowledgement, a restatement, or thanks; a broadcast is spent on every
session's context.

**The lane rule.** Diagnose anywhere; fix only in your own lane. A defect
in another role's surface is an `OBSERVATION` — what you saw, how you
verified it (and the control that shows the measurement was live), what
you did not verify, what follows — and then you stop until the owning
role acknowledges. If they decline it, the work comes back to you and you
fix it there, with the decline as the record. "Reachable from my clone"
is not "mine".

**A handover names its artifact.** A contract, a decision record, a
migration, a PR: the thing itself, not a description of it. When you take
someone's finding, the branch or PR name you send back is the
acknowledgement. A shared command or default changes only when its docs
and the relay both say so.

**A change whose pieces only make sense together lands as one PR.**
When a partial landing is a defect — a contract status against the wire
served, a migration against its reader — the role that owns the concern
integrates: contributors push branches and open no PR; the integrator
merges them unrebased into one branch, opens the one PR naming whose
range is which, and arms it. One blind review covers the range; a
finding goes to the lane that owns the hunk. Independent work stays
separate PRs (the CEO, 2026-09-16).

**A change has one owner; the roles it needs supply it.** The caller —
the lane holding the consuming code, contract or screen — owns the
branch, the PR and the arming. A supplier (copy for these keys, the
migration this change reads, a check for this feature) delivers one
commit onto the caller's branch, or a contributor branch
`<host>/<supplier>/for/<caller>/<what>` the caller folds unrebased;
where the composition is the caller's file (a template's markers, a
dictionary's keys) it delivers the authored text by locator and the
caller commits it, citing the message. A supplier never opens a PR for
supplied work, reviews before hand-off (`Supplier-Review:`) and answers
findings on its hunks there. The caller arms, never with an unanswered
`REQUEST` of its own; person-facing copy is never self-authored (the
owner, 2026-09-18).

**A code PR is armed by its work-commit count** (the owner,
2026-09-18): the commits of work as opened, review fixes excluded.
Eight to sixteen: arm once the review gate is met (a posted review of
the head, no open P1/P2). Fewer: ask the owner. More than sixteen is
split before the PR opens. Never without the gate.

**A review finding is judged before it is answered** — with the review
class, so the assessment is not made by the session that wrote the code —
and when it is real you fix the rule, not the instance.

**The control plane is read-only.** `agent-fabric/` and every project's
`.agent-fabric/` are fabric-coordinator's to write; a charter, a brief, a
slice or a routing entry you believe wrong is raised (a message, or a PR
you do not merge), never edited in place. Your own role, {role}, is what
you were launched with; a different one is a relaunch from the shell.
