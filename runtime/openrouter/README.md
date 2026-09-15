# runtime/openrouter — the broker launch path

How a Claude Code session starts through OpenRouter, and which model each
capability class gets there. One decision per launch: the provider chosen
at launch applies to everything under the session, subagents included.

| | unlaunched vanilla (`claude`) | fabric vanilla (`launch --provider anthropic`) | broker (`launch`) |
|---|---|---|---|
| provider | Anthropic, by construction | Anthropic, plain `claude` | OpenRouter (`ori claude`) |
| who launches | the Linux login (`runtime/identity.py`) | the same login; the role comes from its binding | same |
| session model | harness default | `providers.anthropic.session` from the profile layers (an alias or a native id; a flat `anthropic/<id>` session serves too, `anthropic/` dropped; another vendor's id is refused) | `providers.openrouter.session` / flat `session` (+ family shim) |
| capability classes | harness aliases (`haiku`/`sonnet`/`opus`/`fable`) | each class rides an alias; an alias nothing binds is the harness's, an alias the profile binds (`providers.anthropic.aliases.<alias>` → native id) is exported as `ANTHROPIC_DEFAULT_<ALIAS>_MODEL` — the tier, session-wide | `openrouter` column, overridden per class by the layers → model → `routing/shims.json` → `ANTHROPIC_DEFAULT_*_MODEL` |
| review class | the `fable` alias, whatever the harness binds it to this week | pinned: `review` → `claude-opus-5[1m]` (the column, or `providers.anthropic.capabilities.review`) in `~/.claude/agents/blind-reviewer.md`; the dispatch checks `model: fable` and then hands the model to the file (architect-cto, 2026-09-15); never the `fable` export, so `/model fable` stays the hand's; gated by review-grade | `review` → `z-ai/glm-5.3` (+ shim), gated by review-grade |
| per-role / per-agent choice | none | `routing/profiles.json` layers + the agent's `model-profile.local.json`, the `providers.anthropic` part: session, the four aliases, the reviewer — `bin/fabric-model set --provider anthropic …` | the same layers, the `providers.openrouter` part: session and each class — `bin/fabric-model set --provider openrouter …` |
| review-grade floor | none — the harness's Fable tier | `routing/policies/review-grade.json`, checked at launch | same |
| refusals | none | no bound role, model pins in any settings scope, an ungraded review pin, a non-Anthropic session | the same, plus `ori` not authenticated from the environment |
| how to inspect | `bin/fabric-status` says "not launched by the fabric" | `bin/fabric-status` says "launched by the fabric" with the pins; `AGENT_FABRIC_LAUNCH_PROVIDER=anthropic` | same, plus `ori auth --json` |

**Every layer is per provider.** The two paths speak different
vocabularies — an OpenRouter id on the broker; a tier alias or a native
`claude-…` id on plain claude — so a layer names each provider's choices
under `providers.<provider>` and a choice made for one never reaches the
other (a GLM session on the broker says nothing about plain claude). The
repository holds the general default per provider (`routing/profiles.json`
`defaults`, over the column in `routing/capabilities.json`); the agent's
own layer is `$STATE_DIR/model-profile.local.json`, which `bin/fabric-model`
lists, sets, unsets and seeds — `list` shows every choice with the layer it
came from, `seed` copies the merged defaults in as explicit pins:

```sh
bin/fabric-model list --provider anthropic
bin/fabric-model set --provider anthropic session opus
bin/fabric-model set --provider anthropic opus claude-opus-5[1m]     # the alias, exported
bin/fabric-model set --provider anthropic review claude-opus-5       # the reviewer's file, at once
bin/fabric-model set --provider openrouter code-medium z-ai/glm-5.3
```

The middle column exists so that the fabric decides the review model on
the vanilla path too, without touching what the session itself calls
`fable`. Exporting `ANTHROPIC_DEFAULT_FABLE_MODEL` would do the first and
break the second (a hand `/model fable` would land on the review model),
so the vanilla pin takes the one route verified live on 2026-09-15: the
Agent tool's `model` accepts only the four aliases (a hook rewriting it to
a native id is rejected at schema validation); the dispatch's `model`
outranks the agent file's; and an agent file whose frontmatter names a
native id runs on it when the dispatch leaves `model` unset. Hence:
`runtime/claude-code/install-agent-files.sh` writes the pinned id into the
reviewer's agent file (`routing.py pins --me` is the one source, merged for
the login: bootstrap runs it at provisioning, `fabric-model` after a change
to the review pin), the dispatch guard — under
`AGENT_FABRIC_LAUNCH_PROVIDER=anthropic` only — checks `model: fable` and
then allows the dispatch with `model` removed, and the launcher exports
nothing under `fable` for it. The coding tiers are the opposite case: a
pin of `haiku`/`sonnet`/`opus` (or of `fable` itself, by hand) means that
tier session-wide, so it IS the export, and the class riding the alias
follows it with its dispatch untouched — which is also why the agent-file
route cannot serve them: the guard *asks* for code-high, and a hook's
`updatedInput` applies only on `allow`. Read-back: session `7052df73`, main on
`claude-sonnet-5`, the review subagent on `claude-opus-5`, `fable`
untouched. A tier alias in the column means "the harness's current model
of that tier", which is right for the coding classes; the review class is
a policy, so it is pinned.

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
review gate guards exactly that export. On unlaunched vanilla `claude`,
`fable` binds to the harness's current Fable tier; launched by the fabric
(`--provider anthropic`), the reviewer runs on `claude-opus-5[1m]` through
its agent file while `fable` itself stays the harness's — the review model
is the fabric's on both paths.

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
