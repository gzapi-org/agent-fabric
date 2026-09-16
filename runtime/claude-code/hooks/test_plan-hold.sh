#!/usr/bin/env bash
# Behavioural tests for runtime/claude-code/hooks/plan-hold.sh: the marker
# that holds this account's GZCoord inbox while the session plans.
#
# What this holds still: the marker appears on a plan-mode event and only
# then; it names the session's harness pid; it is written once per
# session; a subagent's event never touches it; a non-plan event clears
# the session's own marker and a dead session's, never another live
# session's; SessionEnd clears; the hook is silent and exits 0 on every
# input, malformed included. The reader side (inbox.mjs --held, and the
# watch not polling) is in communication/gzcoord/tests.
#
# Exit 0 all passed, 1 otherwise.
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/plan-hold.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }
command -v jq >/dev/null || { echo "test: jq required" >&2; exit 1; }

failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2; failures=$((failures + 1)); }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export AGENT_FABRIC_HOLD_DIR="$SANDBOX/hold"
MARKER="$AGENT_FABRIC_HOLD_DIR/$(id -un).json"

# fire <event> <mode|-> <agent_id|-> [pid] [session] -> stdout of the hook (must be empty)
fire() {
  local event="$1" mode="$2" agent="$3" pid="${4:-$$}" session="${5:-sess-1}" payload
  payload="$(jq -nc --arg e "$event" --arg m "$mode" --arg a "$agent" '{hook_event_name:$e} + (if $m != "-" then {permission_mode:$m} else {} end) + (if $a != "-" then {agent_id:$a, agent_type:"code-low"} else {} end)')"
  printf '%s' "$payload" | CLAUDE_PID="$pid" CLAUDE_CODE_SESSION_ID="$session" bash "$UNDER_TEST"
  echo "rc=$?"
}
expect_out() { local label="$1" got="$2"; if [[ "$got" == "rc=0" ]]; then pass "$label"; else fail "$label" "hook printed or failed: $got"; fi; }
expect_marker() { local label="$1" want="$2"; if [[ -f "$MARKER" ]]; then got=present; else got=absent; fi; if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want marker $want, got $got"; fi; }

echo "plan hold: the marker follows the permission mode"
expect_out "a default-mode tool call is silent" "$(fire PreToolUse default -)"
expect_marker "no marker outside plan mode" absent
expect_out "a plan-mode tool call is silent" "$(fire PreToolUse plan -)"
expect_marker "the marker appears on a plan-mode event" present
if [[ "$(jq -r .pid "$MARKER")" == "$$" && "$(jq -r .session_id "$MARKER")" == "sess-1" ]]; then pass "the marker names the harness pid and the session"; else fail "the marker names the harness pid and the session" "$(cat "$MARKER")"; fi
first="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER")"; sleep 1.1
fire UserPromptSubmit plan - >/dev/null
second="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER")"
if [[ "$first" == "$second" ]]; then pass "a marker naming this pid is written once, not per event"; else fail "a marker naming this pid is written once, not per event"; fi

echo "plan hold: leaving plan mode clears it"
expect_out "a default-mode prompt is silent" "$(fire UserPromptSubmit default -)"
expect_marker "the marker is gone after a non-plan event of the same session" absent

echo "plan hold: a subagent's event is not the session's mode"
fire PreToolUse plan sub-1 >/dev/null
expect_marker "a plan-mode event with agent_id writes nothing" absent
fire PreToolUse plan - >/dev/null
fire PreToolUse default sub-1 >/dev/null
expect_marker "a default-mode event with agent_id clears nothing" present

echo "plan hold: another live session's hold is left alone; a dead one is cleared"
fire PreToolUse default - 1 sess-other >/dev/null        # pid 1 is alive and not ours
expect_marker "a non-plan event from another live pid leaves the marker" present
# a marker whose pid is dead: pick a pid that cannot exist
jq --argjson p 4194304000 '.pid = $p' "$MARKER" > "$MARKER.tmp" && mv "$MARKER.tmp" "$MARKER"
fire PreToolUse default - 1 sess-other >/dev/null
expect_marker "a marker whose session is gone is cleared by anyone" absent

echo "plan hold: SessionEnd clears the session's own marker"
fire PreToolUse plan - >/dev/null
expect_marker "held" present
expect_out "SessionEnd is silent" "$(fire SessionEnd - -)"
expect_marker "cleared at session end" absent

echo "plan hold: never loud"
out="$(printf 'not json' | bash "$UNDER_TEST"; echo "rc=$?")"; expect_out "malformed input is silent" "$out"
out="$(printf '' | bash "$UNDER_TEST"; echo "rc=$?")"; expect_out "empty input is silent" "$out"
out="$(printf '{}' | bash "$UNDER_TEST"; echo "rc=$?")"; expect_out "an event without a name is silent" "$out"
expect_marker "and writes nothing" absent

if (( failures )); then echo "plan hold: $failures failure(s)" >&2; exit 1; fi
echo "plan hold: OK — all assertions passed."
