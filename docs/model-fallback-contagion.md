# A flagged request is contagious — 2026-09-16

**What changed in meaning.** A session whose request a model's
safeguards flagged is no longer only a session running on another tier.
It is a session holding text that will flag every other session it
reaches, and the fabric now tells it so at the moment it happens.

**The harness fact** (code.claude.com/docs: hooks, model-config; read
2026-09-16). Fable and Opus 5 run with safety classifiers that most
often flag cybersecurity and biology content. When one flags a request
and the category has a fallback model, the harness re-runs the request
there, shows "…safeguards flagged this message. Switched to …", and the
session **stays on the fallback model until `/model`**. PreModelSwitch
is not run for a switch the harness makes itself; PostModelSwitch is,
with `source: "auto"` and `requested_model: null`, and what that hook
prints reaches the model with the next request. `switchModelsOnFlag:
false` in settings turns the automatic switch into a pause with a
choice. The transcript records the event as a `model_refusal_fallback`
system line with both model ids and the category.

**Why it matters here.** A finding that tripped one session's
safeguards trips every session it is sent to, and a broadcast lands in
all of them at once; each of those sessions then also falls back. The
CEO named this on 2026-09-16 after seeing the notice: the first agent
has to be told, or the finding spreads.

**What the fabric does.**

- `runtime/claude-code/hooks/model-fallback-note.sh`, on
  `PostModelSwitch` with `source: "auto"`: tells the session, as context
  for its next request, that it fell back, from which model to which,
  that the switch is sticky, which category was flagged (read from the
  transcript's `model_refusal_fallback` line), and that from then on it
  filters anything that could be read as that category out of
  everything it sends — GZCoord messages, commit messages, PR bodies,
  memories — naming where a finding is and what class of problem it is,
  never its content; and that its next report says so. It leaves a marker
  per harness pid under `~/.cache/agent-fabric/fallback/`, swept like
  the plan-hold markers.
- `send.mjs` repeats the reminder on stderr while the marker is live.
  A reminder, never a content check: nothing can tell flagged text from
  any other, only the session can.
- `bin/fabric-status` reports the fallback as drift, with the models
  and the time.
- The `gzcoord-send` skill carries the writer's rule beside "never a
  secret value"; the `gzcoord-receive` skill carries the reader's: a
  delivery that flags your session is answered by locator, quoting
  nothing.

**Wiring.** The workspace template carries the hook; a session started
inside a clone takes its hooks from the clone's settings, so each
project's `.claude/settings.json` adds the `PostModelSwitch` group
(`projects/gzapp/integration/gzcoord/INSTALL.md`).

**Not measured.** A safeguard flag cannot be provoked on purpose, so the
hook firing with `source: "auto"` rests on the documentation and on the
recorded transcript event, not on a live read-back. The hook's own
behaviour on that input is tested; the first real fallback under it is
the read-back, and its session's report should say what it saw.
