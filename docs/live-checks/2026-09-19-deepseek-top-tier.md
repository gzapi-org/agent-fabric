# 2026-09-19 — DeepSeek V4 Pro on the broker's top tier, read back

The owner's decision, in the coordinator's session: the broker path's
session model, `code-high`, `code-plan` and the review class move to
`deepseek/deepseek-v4-pro-0813`; `code-low` and `code-medium` stay GLM.
The reason for the review class is independence — a reviewer on a
different model family from the coding classes it reviews. Admissibility
rests on `2026-09-14-deepseek.md`; this note is the read-back of the
routing change itself.

## Resolution

From the branch checkout, `tools/fabric/routing.resolve` per class:

```
code-low     z-ai/glm-5.3-flash@preset/glm2claude-shim
code-medium  z-ai/glm-5.2@preset/glm2claude-shim
code-high    deepseek/deepseek-v4-pro-0813@preset/deepseek2claude-shim
code-plan    deepseek/deepseek-v4-pro-0813@preset/deepseek2claude-shim
code-review  deepseek/deepseek-v4-pro-0813@preset/deepseek2claude-shim
session      deepseek/deepseek-v4-pro-0813@preset/deepseek2claude-shim  (defaults)
```

`runtime/openrouter/launch --print` as `user` agrees; the review class is
pinned in the agent file, never exported (the fable export is
`code-plan`'s — the same composite today, by coincidence of the column,
not by sharing).

## Served

Headless, `launch -p …`, session `86f4cbd3`: a two-step task (one shell
command, one line of answer, read nothing else). Three turns, the command
run, the count right, the answer written unprompted and naming the model;
`modelUsage` carries one key, the DeepSeek composite; `is_error: false`.
The harness logs `unrecognized_model` for the non-Anthropic id, as it
does for every broker model.

## Two overrides removed

Both coordinator-side local layers that would have masked the default
were unset: `p2p-network-dev-01`'s session (GLM 5.3, set that morning
so the account could run GLM before this decision) and `user`'s (GLM
5.3, older). With the default now the top tier, neither is needed; an
account that wants another session model sets its own layer again.

## What it decides

`routing/profiles.json` defaults, `routing/capabilities.json` broker
column, `routing/policies/review-grade.json` (Pro admitted with the
decision recorded; v4-flash still refused). architect-cto informed: the
review model is its call by charter, and the owner's word is above it.
