# Effort is routed, beside the model

*2026-09-23. What changed meaning: a capability class used to decide one
thing about a task — which model runs it. It now decides two.*

## Why there is a second dimension

The fabric pinned models per class and said nothing about how hard those
models think. That was invisible for exactly as long as every model it
pinned happened to default to the same level.

Measured through one launcher and one profile, changing one thing
(`docs/live-checks/2026-09-23-opus-5-5.md`, corroborated against the
harness's own model registry in `2026-09-23-effort-registry.md`):

```
claude-opus-5     default effort high
claude-opus-5-5   default effort medium     ← its successor, and cheaper
```

So moving `code-high` to Opus 5.5 would have dropped every session a
level of thinking: no commit, nothing to review, and a symptom that reads
as a worse model rather than a changed default. **A model id is not the
whole routing decision.** A vendor's default is the vendor's; what a
class gets is the fabric's, or it is nobody's.

## Where each thing is decided

One file per decision, as the other dimensions already are:

```
CLASS -> MODEL     routing/capabilities.json          per provider — models differ per provider
CLASS -> EFFORT    routing/effort.json                one vocabulary — the intent does not
FAMILY -> SHIM     routing/shims.json
CLASS -> ALIAS     runtime/claude-code/aliases.json   this harness's spelling of a tier
```

`effort.json` says what each class asks for. It does **not** say what any
provider spells or admits: that is the provider's adapter in
`tools/fabric/routing.py`, per model, because the level set is a property
of the *(provider, model)* pair and not of the provider — Haiku 4.5 takes
no effort at all while the rest of the Claude line does, and OpenAI's own
set moved three times inside one model family.

## The vocabulary is an ordinal, and the clamp is ours

Seven levels, the union of the vendors', ordered least to most:

```
none < minimal < low < medium < high < xhigh < max
```

No vendor claims its `high` means another's, and neither does this file.
A level is a position, never a quantity.

What a class asks for is clamped **by the fabric, before the request
leaves**, to the nearest level its model admits — including *upward*
where a vendor documents that (GLM-5.2 maps `medium` to `high`, so
clamping only downward would have asked it for less thinking than sending
the level untouched).

The reason the clamp is ours is that the vendors disagree about what an
unsupported level means: OpenAI answers HTTP 400, xAI and Claude Code
quietly drop a level, GLM-5.3-Flash errors, DeepSeek remaps. Both failure
modes live inside one provider column. One routing decision must not mean
two different things depending on who serves it.

## A downgrade is a commit, never a computation

An adapter may *compute* the nearest expressible level. It never
*applies* one silently: `routing.py check()` refuses until the clamped
value is written into `providers.<p>.classes.<klass>` with a note saying
why.

That is the whole point. The thing the Opus 5.5 measurement found missing
was a commit and something to review. Now a lossy path cannot be clean
without one.

## How a level reaches a model

Per class, the agent file's frontmatter — the same channel the review
class's `model:` already uses, and for the same reason: **the Agent tool
takes no effort on a dispatch**, exactly as it takes no full model id.
`install-agent-files.sh` writes it; a hand-written `effort:` in a
committed source is a lint finding, so there is one writer.

Per session, `--effort`, which the launcher passes and stamps as
`AGENT_FABRIC_LAUNCH_EFFORT`. A caller's own `--effort` wins and is what
gets stamped — the stamp records what the child applies, never what the
fabric wanted.

**Never `CLAUDE_CODE_EFFORT_LEVEL`.** Read out of the harness: it
outranks `--effort`, `/effort` *and* an agent file's `effort:`, and
process environment reaches every subagent — so one value there flattens
every per-class decision at once. `unset` and `auto` are not neutral
either; both mean "ignore the configured level, use the model's default".
The launcher refuses all of it, beside `CLAUDE_CODE_SUBAGENT_MODEL`,
which is the same bug in the other dimension. The committed-settings
guard refuses `effortLevel`, `maxEffortLevel` and `modelSettings` for the
same reason — and `maxEffortLevel` especially, because the *lowest* value
across scopes wins, so a committed cap cannot be raised back by a launch.

## What you can see, and where

A subagent's effort is **recorded in its own transcript**: every entry of
`~/.claude/projects/<cwd>/<session>/subagents/agent-<id>.jsonl` carries an
`"effort"` field with the level that subagent resolved to — absent for a
model with no effort capability. Measured with the channel isolated: a
`code-medium` dispatch whose agent file says `medium`, from a session
running at `high`, recorded `medium` (`2026-09-23-effort-registry.md`).
So the per-class level is checkable after the fact, per dispatch.

It is not in the subagent's *environment*: `CLAUDE_EFFORT` is exported to
the session's tools only, and `bin/fabric-status` reports that one against
the launcher's stamp.

An earlier version of this note said the opposite, from one control
dispatch on Haiku — the one model with no effort to record. The clamp and
the refusal-until-written-down still matter, but as the first line of
defence rather than the only one: a drift check comparing the asked level
with the recorded one can now be built.

## One model, one level (2026-09-25)

The owner moved every class on plain claude to Opus 5.5 and every class
and every session to `medium`. Two things change meaning with that. On
plain claude a class no longer picks a model or a level of thinking,
because all five resolve to the same pair. It still picks the alias
the Agent tool accepts, the worktree rule and whether a dispatch asks.
And the review class is no longer a stronger reader than the code it
reviews: its independence is the blind brief and a fresh context, as it
already was on the broker. The machinery stays whole, so a later split
is one edit per file: the per-class columns, the clamp, the
refusal-until-written-down and the reviewer's own pin. Tests of that
machinery run on the column of 2026-09-24
(`tests/fixtures/routing-distinct/`), where the classes still differ.
