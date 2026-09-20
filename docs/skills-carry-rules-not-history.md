# A skill carries the rule and its reason, not the incident — 2026-09-19

The owner's rule, applied across every skill the fabric ships: a skill
is procedure for the session that loads it — on any account, in any
project, for as long as the rule holds. A date, a pull-request number,
an incident's project or login narrows it to the one occasion that
prompted it, and reads as history to a session that needs an
instruction. The skill-creator's own guidance says the same: general,
imperative, the *why* explained without the specific example the rule
was learned from. The reason stays in the skill; the evidence lives
here, in `docs/live-checks/` and in the commits.

The sweep of 2026-09-19 found the pattern in five of six skills, 22
lines. What each passage cited, removed from the skill and recorded
here so nothing is lost:

## `policies/subagent-dispatch/SKILL.md`

- The forty-agent bill: the ADR-075 fold of 2026-08-05 dispatched ~40
  agents with `model` unset from a premium session.
- The alias guard checks rather than infers: decided 2026-09-13.
- The reviewer following the export: a reviewer dispatched on `opus`
  on the broker path ran on GLM, 2026-09-13.
- Broker pricing verified against OpenRouter's docs and live catalog
  2026-09-12; the launcher and registry shipped 2026-09-12 (Shape D).
- The read-only harness types' exemption: added 2026-09-16 after every
  Explore dispatch of a planning session was denied.
- `tools: TaskStop` for the locale worker: read back 2026-09-17.
- `worktree.baseRef` defaults to `fresh`: two agents dispatched
  2026-08-04 found neither the ADR nor its source; reproduced
  2026-08-07.
- `head` is the committed HEAD: verified 2026-08-07, re-verified
  2026-09-11 with a haiku probe; a devex-tooling thread slice recording
  the opposite is the stale record.
- The embedded-repository gitlink: observed 2026-08-07.
- Parallel worktree creation: verified 2026-08-07, eight simultaneous
  adds.
- The review class's trigger named gzapp's
  `tools/gh/pr-review-status.sh`; the tool is the fabric's since
  2026-09-19 (`runtime/github/`), reached through the project's
  forwarder.

## `communication/gzcoord/skills/gzcoord-receive/SKILL.md`

- Every session watches its inbox from its first turn: the owner,
  2026-09-13.
- Reply only to add something useful: the owner, 2026-09-15.
- The notification cut landing inside REQUEST or VERIFIED: four
  deliveries to architect-cto, 2026-09-16.
- An assignment reaching a role is claimed by the first REPLY: gzapp
  #897 and #899, both holders of backend-dev, 2026-09-19
  (`docs/assignment-to-one-login.md`).

## `communication/gzcoord/skills/gzcoord-send/SKILL.md`

- An assignment goes TO one login: the owner, 2026-09-19; the same
  incident.

## `identities/roles/flutter-dev/skills/flutter-client-capture/SKILL.md`

- Written from flutter-dev-01's Linux desktop build, 2026-09-16.

## `identities/roles/db-admin/skills/pg-probe/SKILL.md`

- The "ship it commented out" pattern existed for `runtime_events` in
  June 2026 and was folded into `0001_baseline.sql` by the 2026-07-20
  re-baseline.

## Left as it is, and why

`pg-probe` cites `ADR-018` and `ADR-022 §5 rule 9`: those are the rules
the skill applies, and a pointer to a rule's home is not an incident.
They are, though, one project's decision records inside a role's skill
under `identities/roles/` — project truth the fabric holds. Whether the
project-bound half of that skill belongs in gzapp's `.agent-fabric/`
remit for `db-admin` is a separate question, not settled here.

## The rule for the next skill

Before writing or changing a `SKILL.md`, load the skill-creator skill
and follow it. State the rule and why it holds; put what happened, when
and to whom in a note under `docs/` or `docs/live-checks/` and in the
commit that made the change. Where a skill needs a pointer to the
evidence, point to the note.
