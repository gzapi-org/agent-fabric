# runtime/openrouter — the broker launch path

How a Claude Code session starts through OpenRouter, and which model each
capability class gets there. One decision per launch: the provider chosen
at launch applies to everything under the session, subagents included.

| | vanilla (`claude`) | broker (`runtime/openrouter/launch`) |
|---|---|---|
| provider | Anthropic, by construction | OpenRouter (`ori claude`) |
| who launches | the Linux login (`runtime/identity.py`) | the same login; the role comes from its binding |
| session model | harness default | `session` from `routing/profiles.json` (+ family shim) |
| capability classes | harness aliases (`haiku`/`sonnet`/`opus`) | `routing/capabilities.json` → model → `routing/shims.json` → `ANTHROPIC_DEFAULT_*_MODEL` |
| review class | `claude-opus-5[1m]`, declared in the agent file | the same declared id; the launcher refuses a profile that resolves review elsewhere |
| per-role / per-agent choice | none | `routing/profiles.json` (`roles.<role>`, `agents.<login>`) + the agent's gitignored `model-profile.local.json` |
| review-grade floor | Opus, by the declared id | `routing/policies/review-grade.json`, checked at launch |
| how to inspect | `model-audit.sh` | same, plus `ori auth --json` |

## The three steps, and where each lives

```text
capability class  --routing/capabilities.json-->  concrete model
concrete model    --routing/shims.json-------->  family shim (or none)
model + shim      --tools/fabric/routing.py--->  model@preset/slug   (runtime only)
```

Today's OpenRouter policy resolves to:

```text
code-low     z-ai/glm-5.3-flash  + @preset/glm-claude-compat  -> ANTHROPIC_DEFAULT_HAIKU_MODEL
code-medium  z-ai/glm-5.2        + @preset/glm-claude-compat  -> ANTHROPIC_DEFAULT_SONNET_MODEL
code-high    z-ai/glm-5.3        + @preset/glm-claude-compat  -> ANTHROPIC_DEFAULT_OPUS_MODEL
review       anthropic/claude-opus-5[1m]   (no shim)           declared in agents/blind-reviewer.md, not exported
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

## Not yet verified live

The review class rides a declared full id (`claude-opus-5[1m]`) rather
than a tier alias so that, on the broker path, it never follows code-high
onto the GLM export. Whether the `ori` broker forwards that unprefixed id
to OpenRouter as `anthropic/claude-opus-5[1m]` has not been exercised in a
live session yet; `model-audit.sh` describes how to read back what was
served.
