# tools/launch — how a session starts, and which provider it gets

Two launch paths, one decision per launch (owner decision 2026-09-12,
Shape D from architect-cto-01-0060/0062):

| | vanilla (`claude`) | broker (`tools/launch/ori`) |
|---|---|---|
| provider | Anthropic, by construction | OpenRouter (`ori claude`) |
| session model | harness default | `session` from the profile |
| subagent tiers | harness defaults | `ANTHROPIC_DEFAULT_*_MODEL` exported by the launcher |
| per-role/instance choice | none | `.roles/registry/model-profiles.json` (+ gitignored local override) |
| review-class floor | harness opus | `review_grade` in the registry, checked at launch |
| how to inspect | `tools/launch/model-audit.sh` | same, plus `ori auth --json` |

## The invariant

**The repo pins harness ALIASES only.** No committed settings scope may
carry a model pin (`check_repo_settings_carry_no_model_pins.sh`), and the
launcher refuses to run when any settings scope — user, user-local,
`$CLAUDE_CONFIG_DIR`, project, or the gitignored project-local one the
guard cannot see — or the caller's `CLAUDE_CODE_SUBAGENT_MODEL` would
race its pins. Every merged model is validated against the registry
schema's `model_id` pattern before it is exported. Anything that resolves
an alias to a concrete model happens in exactly one place: the launcher,
from the committed profile, before exec.

## Files

- `ori` — the launcher. `--print` resolves without spawning — it is the
  launcher's flag, not claude's: for a headless run use claude's short
  form, `-p "prompt"`, which passes through.
- `model-audit.sh` — what is the current session actually routed through,
  and how to read back the served model.
- `test_ori.sh` — the behavioural suite for the launcher and the audit (the run prints its assertion count).

## The profile registry

`.roles/registry/model-profiles.json`, schema in
`.roles/schema/model-profiles.schema.json`, linted by `tools/roles/lint.py`
(every merged opus must be in `review_grade`; every roles key must be a
taxonomy role). Merge order, later wins: `defaults` <- `roles.<role>` <-
`instances.<dir_basename>` <- `.roles/.instance/model-profile.local.json`.
Owned by architect-cto; `review_grade` is policy, not a cost dial.
