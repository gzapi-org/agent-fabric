# Cooperating on requests: what the record showed, and what changed

The owner asked (2026-09-26) for the fleet's cooperation to improve
without moving it into the control plane: agents divide work, agree
dependencies, resolve disagreements and revise commitments among
themselves; the infrastructure provides reliable information and tools
and enforces the existing security and authority boundaries, and does not
set their agenda. This note is the evidence behind the practices now in
`communication/gzcoord/protocol/MESSAGE-FORMAT.md` §Working on a request
together, what was deliberately left alone, how to tell whether it
helped, and what tools are missing.

## What was read

Twelve pull requests (gzapp #870, #875, #883, #887, #897, #899, #938,
#940, #941, #944; InterWeave #114, #125), about twenty-five workflow and
threads slices under each project's `.agent-fabric/memory/`, and the
messages addressed to the coordinator on 2026-09-26. No message body
addressed to anyone else was read: the committed record is where the
agents themselves wrote down what went wrong.

## What already works, and was not changed

- **One PR per change, suppliers committing onto the caller's branch**,
  with range lines and `Supplier-Review:` (gzapp #875: eleven work commits
  from five lanes, merged 2026-09-18; #870, #883, InterWeave #114).
- **Assignments to one login** — the validator refuses a role-addressed
  `REQUEST` (agent-fabric #19, after gzapp #897 and #899 did one hunk
  twice).
- **Acknowledging by reference**, and closing a duplicate while naming
  where its content went (#899 into #897, #887 into #883).
- **Findings that diagnose and stop** (`VERIFIED`, `NOT-VERIFIED`,
  `IMPACT`), and undo requests that state the defect.
- **Blind review**, findings answered by sha, re-review on the new head.
- **Arming comments that state their basis**, and the owner's word
  carried verbatim.
- **Checking a delivery by sha reachability**, not by the message
  (db-admin, the 0058 thread, 2026-09-21).
- **Dated threads trackers** that name owner, blocker and message id and
  say "verify before acting" (devex-tooling's open threads; the 0058
  thread's dated STATE blocks).

## The five practices and their evidence

1. **Requests say what done looks like; receipt is not acceptance.**
   Failures: an assignment to a role executed by both holders (#897 and
   #899, 2026-09-19); two locale holders doing one deletion and answering
   it two ways (2026-09-19); a requested migration checked and then held
   for a permission nobody had withheld (db-admin, 0044, 2026-09-16); on
   2026-09-26 a job assigned while it already sat on a pushed branch with
   no PR, withdrawn three minutes later (relay seq 5703). Successes on
   2026-09-26: replies that said "mine", verified the claim on origin, and
   said when against the work already in flight (seq 5378, 5414).
2. **The smallest dependency.** Success: InterWeave #125's dependency
   section — "land agent-fabric #46 first, or arm now and accept a short
   drift". Failures: work held behind a whole PR for a migration number
   (0049 → 0050 → 0051, each move a re-fold); 0058 unable to land while
   its reader's branch had no PR (2026-09-25).
3. **Renegotiate where the agreement changes, and only there.** Successes:
   db-admin reopening an assumption the ADR had not settled, decided
   fresh by architect-cto (2026-09-21); the supply rule rewritten and the
   work moved with it (#887 into #883). Failures: a hold kept after the
   plan was approved "until asked twice" (2026-09-15); a request re-sent
   twice for work already open as #598. The coordinator's own case: a
   snippet line copied verbatim into four project PRs, then reworded in
   all four (agent-fabric #46, 2026-09-26) — handled by telling each
   holder, `TO` its login, what changed.
4. **Deliveries that can be checked where they land.** Failures: "folded"
   announced before the push, twice (#844, #849), five agents reading a
   stale head; "verified" without running it, caught four times by blind
   review (#551, #555). Successes: #897 mapping each finding to a sha;
   language-culture-ge's delivery of agent-fabric #44 naming the commit,
   the checks and the one unrelated red (seq 5326).
5. **The agreement survives the session.** Failures: a request owed by a
   session that ended, "owed by nobody until a new session starts, and
   that session will not know it exists" (2026-09-20, again 2026-09-23);
   a fan-out brief lost from a scratchpad on a restart, recovered only
   because the commits were descriptive; a stall read as the owner's
   indecision when nothing was merging at all (#926). Successes: the dated
   threads trackers above.

Most frequent first: the same work started twice (five cases), a state
announced before it was true (four), owed work lost with a session (three
or four), asking again inside an agreement (two), waiting on a whole PR
(two).

## What changed

- `MESSAGE-FORMAT.md` §Working on a request together: the five practices
  as professional practice, one place.
- `SEMANTICS.md`: a requested piece someone waits on is answered once by a
  `REPLY` naming it, beside the PR; what a sender undertakes is said in
  words, an agreement changed by saying so, never a lock.
- `identities/prompt/team.md`: one paragraph and the pointer, in every
  launch prompt.

No new message type, field or section; no state machine; no template;
no role widened; nothing scheduled.

## Left unchanged on purpose

- **`HANDOFF`** stays as SPEC §10 defines it; the new text only says that
  work someone undertook stays theirs until they hand it over or the owner
  reassigns it. Silence is not a release.
- **`REPLY-EXPECTED`** defaults: an undertaking is an ordinary `REPLY`.
- **The supply sections** (`DELIVER-TO`, `ACCEPTANCE`, `FACT`, `BY`,
  `FOLD-BY`): the long form stays where it is; the new text calls it that.
- **Project agreements** — ADRs, contracts, a project's arming rules —
  stay in each project; nothing project-specific entered a charter.
- **The skills**: `gzcoord-receive` step 7 already says to answer with
  where the work is; the launch prompt now points every session at the
  fuller text, and a skill edit waits until that proves insufficient.

## How to tell whether ambiguity and rework went down

Measured from the committed record and from message metadata (type,
`IN-REPLY-TO`, timestamps), never from bodies, before and two weeks after:

- duplicates: PRs closed as duplicates or superseded by a sibling's, and
  branches deleted within an hour of a withdrawal;
- rework: review-fix commits per merged PR, and PRs replaced by another
  (#938 → #940 is one);
- unanswered commitments: `REPLY-EXPECTED: yes` messages with no `REPLY`
  naming them, and the time to the first `REPLY`;
- re-asks: a second `REQUEST` from the same sender on the same subject
  while the first is open;
- lost work: threads slices recording work "owed by nobody" after a
  session ended;
- premature claims: blind-review findings that a "verified" or "folded"
  was false.

## Missing tools (reported, not built)

- **A thread view.** `gzcoord-inbox --replay` reads one message at a time;
  there is no way to see a request and every `REPLY` to it, which is
  what a resuming session needs first. (The coordinator's own queue
  records this as `--history`, not built.)
- **What is in flight, branches included.** `pr-gate.sh --all` lists open
  PRs; a job parked on a pushed branch with no PR — the normal state of a
  second piece of work under one-open-PR — shows nowhere but
  `git branch -r`, and the assigner on 2026-09-26 did not look there.
- **Owed requests across sessions.** Nothing lists the `REPLY-EXPECTED:
  yes` requests addressed to a login that no `REPLY` has answered, so a
  new session cannot see what its predecessor owed.
- **A link from a commit to the request it answers.** On gzapp's main
  since 2026-09-12, 163 of 1,751 non-merge commits cite a request in prose
  only — 78 by relay seq, which is channel-local, and 85 by `MESSAGE-ID`;
  the `Answers:` trailer covers review findings, not requests, so which
  request a delivery satisfies is joined by hand (devex-tooling, relay seq
  5742). An optional trailer naming the `MESSAGE-ID` was the candidate —
  a commit convention in every lane, not a wire change — and the owner
  declined it (2026-09-26): the delivery `REPLY` naming the artifact, and
  the PR body naming the request, stay the link.
- **The metrics above** need a counter over message metadata and the PR
  record; none exists.
