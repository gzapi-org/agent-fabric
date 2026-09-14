# runtime/openrouter — the broker launch path

How a Claude Code session starts through OpenRouter, and which model each
capability class gets there. One decision per launch: the provider chosen
at launch applies to everything under the session, subagents included.

| | vanilla (`claude`) | broker (`runtime/openrouter/launch`) |
|---|---|---|
| provider | Anthropic, by construction | OpenRouter (`ori claude`) |
| who launches | the Linux login (`runtime/identity.py`) | the same login; the role comes from its binding |
| session model | harness default | `session` from `routing/profiles.json` (+ family shim) |
| capability classes | harness aliases (`haiku`/`sonnet`/`opus`/`fable`) | `routing/capabilities.json` → model → `routing/shims.json` → `ANTHROPIC_DEFAULT_*_MODEL` |
| review class | the `fable` alias, bound by the harness to its Fable tier | `review` → `z-ai/glm-5.3` (+ shim) → `ANTHROPIC_DEFAULT_FABLE_MODEL`; the launcher refuses a profile that resolves review outside review-grade |
| per-role / per-agent choice | none | `routing/profiles.json` (`roles.<role>`, `agents.<login>`) + the agent's gitignored `model-profile.local.json` |
| review-grade floor | the harness's Fable tier | `routing/policies/review-grade.json`, checked at launch |
| how to inspect | `model-audit.sh` | same, plus `ori auth --json` |

## The three steps, and where each lives

```text
capability class  --routing/capabilities.json-->  concrete model
concrete model    --routing/shims.json-------->  family shim (or none)
model + shim      --tools/fabric/routing.py--->  model@preset/slug   (runtime only)
```

Today's OpenRouter policy resolves to:

```text
code-low     z-ai/glm-5.3-flash  + @preset/glm2claude-shim  -> ANTHROPIC_DEFAULT_HAIKU_MODEL
code-medium  z-ai/glm-5.2        + @preset/glm2claude-shim  -> ANTHROPIC_DEFAULT_SONNET_MODEL
code-high    z-ai/glm-5.3        + @preset/glm2claude-shim  -> ANTHROPIC_DEFAULT_OPUS_MODEL
review       z-ai/glm-5.3        + @preset/glm2claude-shim  -> ANTHROPIC_DEFAULT_FABLE_MODEL   (review-grade.json admits it; Opus 5 stays admitted)
```

Only the Z.ai/GLM family has a shim. A model of any other family gets none
(`tools/fabric/routing.py table` shows it). Do not add a family until a live
test has shown it works.

## The invariant

**Canonical files hold classes, models and shims separately; the composite
exists only in the child's environment.** No committed settings scope may
carry a model pin (`policies/check_repo_settings_carry_no_model_pins.sh`),
and the launcher refuses to run when any settings scope — user, user-local,
`$CLAUDE_CONFIG_DIR`, the launch working copy's, or the gitignored local one
the guard cannot see — or the caller's `CLAUDE_CODE_SUBAGENT_MODEL` would
race its pins. `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is refused outright: it
discards every dispatch's own model, and capability classes would stop
meaning anything.

The main agent's GLM compatibility is the same shim applied to the
`session` model and passed as `--model` — separate from, and unaffected by,
how the capability classes resolve.

**A hand `/model` inside the session cannot drop the shim.** The launch
binds a family to its shim once, in the child's environment; `/model
<bare id>` afterwards would run that family with none, and what follows
reads as a model defect rather than a routing one. The `PreModelSwitch`
hook `runtime/claude-code/hooks/model-switch-guard.sh` — armed only when
`AGENT_FABRIC_LAUNCH_PROFILE` is set, so a vanilla `claude` never sees
it — refuses a bare target whose family `routing/shims.json` gives a shim
and names the composite to switch to instead; a composite, a tier alias
(the launcher's own export) and a family with no shim pass. It asks
`tools/fabric/routing.py shim <model>` rather than matching families
itself, so a family added to `shims.json` is guarded from that moment
with nothing else to update.

## Who is launching

The agent is the Linux login; the launcher asks `runtime/identity.py` and
reads the role from that agent's runtime binding (`/role`). The launch
directory decides which settings scopes are fenced and which working copy
the child starts in. It never decides who the agent is: `test_launch.sh`
launches from a directory named for another agent with `USER` forged and
checks the label still reads this login.

## Files

- `launch` — the launcher. `--print` resolves without spawning — it is the
  launcher's flag, not claude's: for a headless run use claude's short
  form, `-p "prompt"`, which passes through.
- `model-audit.sh` — what is the current session actually routed through,
  and how to read back the served model.
- `test_launch.sh` — the behavioural suite for the launcher and the audit
  (`bash policies/run_suite.sh runtime/openrouter/test_launch.sh`).

## Why the review class rides `fable` (verified live 2026-09-13; read-backs in `docs/live-checks/2026-09-13-openrouter-routing.md`)

The Agent tool's `model` field accepts **only the four tier aliases**
(`haiku`, `sonnet`, `opus`, `fable`); a full id such as `claude-opus-5[1m]`
is rejected as an invalid parameter. So a class cannot be "declared" by
full id in its agent file and named at dispatch — the first design tried
exactly that, the dispatch guard refused the unset model, the session fell
back to `opus`, and OpenRouter's `/generation` record showed the reviewer
served as `z-ai/glm-5.3` (Modal, GLM preset applied): code-high's export.

Every class therefore rides an alias, and one alias carries one export.
`fable` is the alias no coding class uses, so the review class rides it;
the launcher exports the review model under
`ANTHROPIC_DEFAULT_FABLE_MODEL`, the dispatch guard requires `model: fable`
on a review dispatch (and denies `opus`, which is code-high's), and the
review gate guards exactly that export. On vanilla `claude`, `fable`
binds to the harness's current Fable tier.

Which model rides the export is `routing/capabilities.json`, gated by
`routing/policies/review-grade.json`. The read-back on the new binding
(a `model: fable` reviewer from a GLM 5.3 session served as
`anthropic/claude-opus-5` on every generation) proved the export is the
reviewer's own; architect-cto then admitted `z-ai/glm-5.3` to
review-grade and made it the broker review model (2026-09-13), so today
the reviewer is GLM 5.3 with the family shim, and Opus 5 remains an
admitted choice for a profile that wants it. The separation still
matters: review and code-high can be given different models, and the
review model can be raised without touching the coding classes.

Also verified the same day: `ori` forwards an unprefixed Anthropic id
untouched (`--model claude-opus-5[1m]` was served as
`anthropic/claude-opus-5-20260723` by "Claude Platform on AWS"), so the
composite in the fable export needs no vendor rewriting. `ori` prints
"not in the OpenRouter catalog, passing it through untouched" for that id
and for every `@preset/` composite; the public catalog lists neither
form, and the warning is cosmetic.
