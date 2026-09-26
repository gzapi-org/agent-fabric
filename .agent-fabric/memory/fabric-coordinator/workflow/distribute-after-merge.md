---
role: "fabric-coordinator"
class: workflow
topic: "distribute-after-merge"
description: After a fabric PR merges, distribute it to every account yourself — pull + bootstrap via hostexec — a broadcast alone is not distribution
tier: 1
knowledge_scope: full
distilled_at: "2026-09-26"
origin:
  - agent: user
    host: "develop-qzapp"
    project: "agent-fabric"
    working_copy: "agent-fabric"
  - agent: user
    host: "develop-qzapp"
    project: "agent-fabric"
    working_copy: "fabric-na"
derived_from:
  - c1a54fb163856f15
---

## After a fabric PR merges, distribute it to every account yourself — pull + bootstrap via hostexec — a broadcast alone is not distribution

On 2026-09-23 I merged #31 and sent a GZCoord broadcast telling every
agent to relaunch, reasoning that the launcher pulls `main` itself at the
next launch. The owner: "still you haven't distributed the upgrade to all
agents — now it is merged." A broadcast is news; distribution is the
upgrade actually on every account.

**Why:** an agent that doesn't relaunch for a day runs a day on the old
fabric, and some can't relaunch at all (language-culture-ru's checkout sat
on its PR branch; the launcher's ff-only pull refused, so it could not
start). Only the coordinator can see and fix that across the fleet.

**How to apply:** after a merge, for every account in `fabric-ctl all`,
through `runtime/hostexec/hostexec develop-qzapp --as <login> -- …`:
`git pull --ff-only origin main`, then `runtime/claude-code/bootstrap.sh`
— in that order; a bare pull under a live session gets its reviews
refused (routing moves, the agent files don't). Before bootstrap, check
each account's provider from its installed `code-review.md` model line:
bootstrap under `sudo env -i` installs for anthropic by default, and a
broker session would get the wrong reviewer pin. A checkout that cannot
fast-forward is never forced: find out whose work it is, confirm it is on
the remote, and only then move the checkout to `main`, leaving the branch.
Verify with `fabric-ctl all fabric`; a silent row right after bootstrap is
usually its control agent restarting — ask it alone before re-bootstrapping
([[control-plane-daemon]]). Then announce, naming what each agent must do.

*References: control-plane-daemon*

*Observed 2026-09-23 (fabric-coordinator)*
