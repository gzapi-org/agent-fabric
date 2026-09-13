---
name: subagent-dispatch
description: "Why every writing subagent dispatch in this repo pins `model` and `isolation: \"worktree\"`, why the REVIEW CLASS (blind-reviewer, description beginning review/re-review, opus, NO isolation) is a standing authorisation the dispatch guard enforces rather than asks about, what the PreToolUse hook cannot see (a Workflow script's agent() calls), how worktree isolation actually behaves — what an agent sees, what survives, and why collection is a copy — and the review brief (base..head, revert test, quoted hunks, pre-existing section, re-review scoped to new hunks). Load it before dispatching agents or writing a Workflow script, when an agent reports files that \"do not exist\", when a worktree or worktree-agent branch is left behind, or when tempted to merge an agent's branch."
---

# Why dispatch looks like this

The root `CLAUDE.md` §Subagent dispatch and §Concurrent contributors
carry the rules. This file carries the incidents — each rule was written
after one, and the rule reads as ceremony until you know which.

## Dispatch is opt-in, and that is deliberate

The isolation machinery below makes fan-out *safe*; it does not make it
*wanted*. The user opts in per task when they judge the parallelism
worth its cost. A task that looks parallelisable is not an invitation,
and this was re-opened as a "gap" more than once — it is not one.

Two standing exceptions exist, both named in the root file, both
review: step 26 of the canonical lifecycle (judging an automated review
claim with a subagent, added after two findings were dismissed by hand
in a row and both dismissals were wrong), and the substitute review
dispatched when `pr-review-status.sh` reports a DECLINE. Nothing else.

## The `model` field — the ~40-agent bill

Omitting `model` is not a neutral default: the agent **inherits the
session model**. On 2026-08-05 the ADR-075 fold dispatched a wave of
roughly forty agents with the field unset, from a session running a
premium model — every one of them ran premium, for work that was mostly
mechanical. Fan-out multiplies the per-agent cost by the count, so the
tier decision is where the bill is actually made:

| tier | for |
|---|---|
| `haiku` | mechanical, well-specified work: pattern-following edits, extraction, formatting, single-file lookups, structured search |
| `sonnet` | judgement work: multi-file reasoning, reviews, prose that must hold a convention |
| `opus` / `fable` | only on the user's explicit instruction for that dispatch |

Pinning the tier on every call is also what keeps a campaign
reproducible: if the session model changes while a batch is in flight,
unset-field agents change with it. The hook in `.claude/settings.json`
denies an unset `model` and prompts on a premium one.

### Review is the standing `opus` exception

One role escapes the premium ban without a per-dispatch ask: a
**substitute reviewer**, dispatched either at step 26 (judging an
automated review claim) or when `pr-review-status.sh` reports a
DECLINE and no automated review is coming at all.

**`opus` is a tier alias, and the target is the launch profile's job.**
The Agent tool's `model` field accepts only the four harness aliases —
a provider-qualified id is rejected by the schema itself, so a dispatch
literally cannot name a vendor model. The mapping lives in the LAUNCH
PROFILE, not settings: `tools/launch/ori` resolves this role instance's
row in `.roles/registry/model-profiles.json`, refuses an opus tier
outside `review_grade`, and exports
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` before
`exec ori claude` — process env, which every subagent inherits.
`modelOverrides` is NOT used: it is taken as the whole map from the
highest-precedence scope that sets it, so any scope both launch paths
share binds both, and it would beat the env pins anyway. The vanilla
`claude` launch stays Anthropic by construction. Committed settings
scopes carry no pins at all (guarded by
`check_repo_settings_carry_no_model_pins.sh`). The tier mechanisms on
OpenRouter: `openrouter/pareto-code` + a dashboard-default
`min_coding_score` is a quality tier (cheapest model above the bar —
the phase-2 opus target), `~vendor/family-latest` is a stable family
alias, `:floor` and `provider.sort: "price"` tune cost within one
model. Verified against OpenRouter's docs and live catalog on
2026-09-12; the launcher+registry shipped 2026-09-12 under Shape D.

The tier table above optimises for cost because, for ordinary work, a
cheaper agent that does the job is strictly better. Review inverts
that. The deliverable IS the quality of the read — there is no output
to inspect afterwards, only findings that either exist or do not — and
a reviewer that misses a defect produces a confident "looks fine" that
is worse than no review, because it manufactures assurance. The cost
of the miss lands in production; the cost of the tier is a few cents.

The scale of the miss is not hypothetical. On the strict-OTP-boundary
branch, four rounds of automated review found seven real defects, and
two of those rounds found defects introduced by the previous round's
own fix. Every one had passed a full green suite and mutation checks
first. That is the failure rate a substitute reviewer is being asked
to match.

It covers review only. "This task looks hard" is not review, and the
exception must not be read as a general licence — the ~40-agent bill
above is what happens when premium becomes the default rather than the
argued case.

#### The exception is a NAMED CLASS, not a promise to behave

For a while the root file declared the exception and then added "the
hook still prompts", which put the decision back in front of the person
at the keyboard on every review — a standing exception that still asks
is not one, and the ask arrived at the least useful moment, mid-review-
loop.

So the carve-out is structural, and it is a CLASS with four conditions,
enforced by `.claude/agent-dispatch-guard.sh` (the `PreToolUse` hook for
`Agent`; decision table in `.claude/test_agent-dispatch-guard.sh`):

1. `subagent_type: "blind-reviewer"` — a file in the repo
   (`.claude/agents/blind-reviewer.md`), reviewable like any other,
   whose charter is review-only;
2. `description` that BEGINS with `review` or `re-review`;
3. `model: "opus"`;
4. **no `isolation`** at all.

All four, or the dispatch is **denied** — never asked. These were
learned one at a time, and each was load-bearing on its own:

- **The model condition was missing when this first shipped.** Keyed on
  the type alone, the branch returned before the premium check for ANY
  model — `blind-reviewer` with `fable` skipped the prompt while the
  rule authorises `opus` only. The same hole runs the other way: a
  `sonnet` review would take the exemption and evade the rule beside
  it. So the class REQUIRES opus, and denies anything else rather than
  asking: a review is not a retryable step, its failure mode is a green
  PR that merges, and "this review looks small" is exactly the moment a
  cheaper tier is tempting and wrong.
- **The description prefix** stops a writing dispatch from wearing the
  review type. Another project's guard matched `review` ANYWHERE in the
  description and let "Address review feedback" through — a writing
  task that then ran unisolated in the session clone, because the
  review class has no worktree. `^(re-)?review\b` is a condition that
  can only NARROW the exemption; it is not a substitute for the type,
  and it is not the prompt-sniffing hole warned about below.
- **No worktree.** Isolation exists to keep an agent's WRITES out of
  the clone; a review writes nothing. It also actively hurts:
  `worktree.baseRef` is `head`, so a reviewer inside a worktree cannot
  see uncommitted work at all — precisely the work you most want read
  before it is committed. The reviewer runs in the clone, told in its
  brief that the tree is read-only and it runs no git writes — and,
  because a promise is not a fence and this clone auto-allows `git
  push`, an agent-scoped `PreToolUse` hook in the definition
  (`.claude/review-bash-guard.sh`, tested by its sibling) denies
  state-changing git and every install/restore for that agent only.

Keyed on the TYPE, deliberately, and not on prompt text alone. A hook
that GRANTED the exemption on review-ish words would be a string match
any dispatch could satisfy by phrasing, which is not an exception — it
is a hole. A named type is a file; the prefix only removes cases from
what the type would otherwise allow.

Two properties of the guard matter and are pinned by the test file:

- The review branch sits INSIDE the type check, so a `blind-reviewer`
  dispatch missing the prefix, the model or carrying an isolation is
  **denied** with a reason naming which; and a general agent whose
  description begins with `review` is denied too — reviews use the
  class.
- It is the ONLY type that passes without a prompt; `general-purpose`
  with `opus` or `fable` still asks exactly as before, and every
  writing agent still needs `model` and `isolation: "worktree"`.

Pass `model: "opus"` explicitly anyway, even though the agent
definition's frontmatter already pins it: the class REQUIRES that value
and every dispatch in this repo names its tier.

### The review brief

The agent definition carries the charter; the DISPATCH carries the
scope, and the scope is where independence is won or lost:

- **No session context.** Not the plan, not the rationale, not what
  you believe is correct. An agent told what the author expects
  confirms it; the whole value is that it does not know.
- **One agent per PR**, briefed on the exact `base..head` range (or a
  diff file in the scratchpad when the range is not yet pushed). Name
  the range in the prompt.
- **State the revert test**: "if this range were reverted, would the
  problem go away?" Findings that fail it are pre-existing and go in
  their own section — still reported, never mixed in.
- **Require each finding to quote its hunk.** A finding that cannot
  point at `+`/`-` lines is pre-existing or speculation.
- **On a re-review, say explicitly: verify only the new hunks against
  the previous findings; do not re-read or re-verify anything outside
  them.** Leaving that sentence out cost another project ~50k tokens
  per comment-only commit, and the re-reading manufactured the next
  round's findings. The description begins `re-review` so the guard
  and the agent both know which mode this is.

### The reviewer reads history; it changes nothing

§Concurrent contributors says a subagent runs no state-changing git, and
that is about worktree and commit hygiene — not about reading. A
reviewer needs `git log`: step 26 asks for a verdict *with evidence* and
names it first, because whether a defect was introduced by the change
under review or was already there decides who fixes it and when.

This was learned the expensive way. The charter originally said "run no
git at all", and an adjudicating reviewer duly reported that it "could
not determine" whether a finding was pre-existing — the exact question
it had been dispatched to answer. Read-only git is now explicit in the
agent definition.

## What the hook cannot see: `Workflow` scripts

The `PreToolUse` hook matches the tool name `Agent`. A `Workflow`
script's agents are created by `agent(prompt, opts)` inside the script,
and never reach it. Both fields are optional in that API and both
default the wrong way — `model` inherits the session, `isolation` runs
in the session's clone — and a workflow can be dozens of agents in one
call, so the 2026-08-05 failure recurs multiplied. A hook cannot close
this: `Workflow`'s tool input is the script *text*, so any guard would be
string-matching rather than a structural check. The rule in the root
file is the only place it exists.

## Isolation — what an agent actually sees

Every WRITING dispatch runs in its own worktree under `.claude/worktrees/`. Four
things about that were learned by probing, not by reading docs:

- **`worktree.baseRef` defaults to `fresh`, which branches from
  `origin/<default-branch>`.** Two agents dispatched on 2026-08-04 to
  extend an ADR and its source found neither, because the unmerged task
  branch was invisible to them; a probe on 2026-08-07 reproduced it
  unchanged. This repo pins `"baseRef": "head"` in
  `.claude/settings.json`, and a re-probe confirmed the agent then sees
  the full branch. Check it before diagnosing a "blind" agent.
- **`head` means the committed HEAD.** Verified 2026-08-07, and re-verified 2026-09-11 with a haiku probe (untracked file and unstaged edit both absent inside the worktree; the devex-tooling thread slice that records this as contradictory is the stale record): an untracked
  file and an unstaged edit to a tracked file both came back MISSING
  from the agent's view. An agent asked to extend uncommitted work
  silently reads the previous version and reports success against it.
  Each worktree also branches at *dispatch* time, so a wave sent either
  side of a commit is not one snapshot.
- **A worktree the agent CHANGED survives.** The harness auto-removes
  only an unchanged worktree, so every productive dispatch leaves a
  worktree plus a `worktree-agent-<id>` branch for the session to remove.
  `.claude/worktrees/` sits inside the repo and each entry holds a `.git`
  file; without the gitignore, `git add -A` staged one as an embedded
  repository and committed a broken gitlink (observed 2026-08-07).
- **Parallel worktree creation from one non-main branch is safe** —
  verified 2026-08-07 with eight simultaneous adds, each with an
  independent `HEAD`, index and tree. This is why the old "no builds in
  parallel" demand is gone: build artifacts were the shared state that
  disjoint source paths did not protect, and a worktree has its own.

## Collection is a copy, not a merge

Isolation removed the index race that first motivated "only the session
commits" — separate worktrees have separate indexes — but not the
reason: authorship and commit shape are the session's to own. An agent
committing in its own worktree produces commits on a throwaway branch
that nothing should merge, and merging `worktree-agent-<id>` back would
put history in `main` the session did not author.

So the session reads what the agent produced, applies it in the clone,
and commits there. That is also why **writes are partitioned by file
set** in every prompt: two agents that both rewrite `foo.ts` hand the
session two divergent versions and no merge. Reads overlap freely.
