#!/usr/bin/env bash
# runtime/claude-code/hooks/model-switch-guard.sh
#
# Claude Code PreModelSwitch hook: in a broker session, a bare /model to
# a family that needs a shim is refused.
#
# WHY. The broker launcher (runtime/openrouter/launch) exports every
# class, and the session model, as a COMPOSITE — <model>@<shim> — so a
# model family that cannot speak Claude Code's wire protocol on its own
# gets its compatibility preset attached (routing/shims.json). That
# binding is made once, at launch, in the child's environment. A hand
# `/model <bare id>` inside the session bypasses it: the harness would
# run the bare model with no shim, and every symptom of that — invented
# turns, native tool markup in the output — looks like a model defect
# rather than a routing one. This was the one idea of the retired
# per-account wrapper worth keeping; it is rewritten here against
# routing/ so that "which families need a shim" has one implementation
# (tools/fabric/routing.py shim) and no vendor name lives in a hook.
#
# DECISION, read from the hook input's to_model (the resolved id the
# session would run after the switch), with requested_model as a second
# witness when the resolved id is spelled differently:
#   not a broker session (no AGENT_FABRIC_LAUNCH_PROFILE)  -> nothing
#   target already a composite (names its @preset)          -> allow
#   target's family has no shim                              -> allow
#   target's family has a shim, target is bare               -> DENY,
#     naming the composite to switch to instead
#   routing cannot be consulted                              -> ASK
# A tier alias (haiku, sonnet, opus, fable) resolves to the launcher's
# own export, which is a composite, so it passes as one.
#
# Output: a deny or ask decision, or nothing. Exit 0 always; a hook that
# cannot parse its input allows.
set -uo pipefail

[[ -n "${AGENT_FABRIC_LAUNCH_PROFILE:-}" ]] || exit 0   # vanilla claude: nothing to protect

HERE="${BASH_SOURCE[0]%/*}"; [[ "$HERE" != "${BASH_SOURCE[0]}" ]] || HERE=.
FABRIC_ROOT="${AGENT_FABRIC_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd)}"
ROUTING="$FABRIC_ROOT/tools/fabric/routing.py"

ask()  { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreModelSwitch",permissionDecision:"ask",permissionDecisionReason:$r}}'; }
deny() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreModelSwitch",permissionDecision:"deny",permissionDecisionReason:$r}}'; }

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreModelSwitch","permissionDecision":"ask","permissionDecisionReason":"The model-switch guard could not run (jq is not installed). In a broker session a bare model id runs without its family shim; approve only if the target is a composite or a family that needs none."}}'
  exit 0
fi

input="$(cat)"
to="$(printf '%s' "$input" | jq -r '.to_model // ""' 2>/dev/null)" || exit 0
[[ -n "$to" ]] || exit 0
requested="$(printf '%s' "$input" | jq -r '.requested_model // ""' 2>/dev/null)" || requested=""

# Judge the RESOLVED id; a request spelled as a composite counts as one too.
target="$to"
[[ "$requested" == *@preset/* ]] && target="$requested"
[[ "$target" == *@preset/* ]] && exit 0                  # names its shim already

[[ -f "$ROUTING" ]] || { ask "The model-switch guard cannot consult routing ($ROUTING not found). In a broker session a bare model id runs without its family shim; approve only if '$target' needs none."; exit 0; }
shim="$(python3 "$ROUTING" --fabric "$FABRIC_ROOT" shim "$target" 2>/dev/null)" \
  || { ask "The model-switch guard could not run routing.py shim for '$target'. Approve only if the target needs no family shim."; exit 0; }
[[ -n "$shim" ]] || exit 0                               # a family with no shim rides bare

deny "This session was launched through the broker (profile ${AGENT_FABRIC_LAUNCH_PROFILE}); '$target' belongs to a family that needs the $shim compatibility preset, and a bare /model would run it with none — the failures that follow look like model defects and are not. Switch to '${target%%@*}$shim' instead, or relaunch with the model in the profile (routing/profiles.json, or the local override)."
