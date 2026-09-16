#!/usr/bin/env bash
# Behavioural tests for runtime/claude-code/hooks/model-fallback-note.sh:
# the PostModelSwitch hook that tells a session its model fell back.
#
# What this holds still: on source "auto" the hook emits additionalContext
# naming both models and the contagion rule, and writes a marker naming
# the harness pid; on every other source, and on PreModelSwitch, it is
# silent and writes nothing; a dead session's marker is swept; the hook
# is silent and exits 0 on malformed input.
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/model-fallback-note.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }
command -v jq >/dev/null || { echo "test: jq required" >&2; exit 1; }

failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2; failures=$((failures + 1)); }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export AGENT_FABRIC_FALLBACK_DIR="$SANDBOX/fallback"
# The transcript the harness names: the fallback line carries the category (shape read back 2026-09-15).
TRANSCRIPT="$SANDBOX/transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"x"}}' '{"type":"system","subtype":"model_refusal_fallback","trigger":"refusal","scope":"session","originalModel":"claude-opus-5[1m]","fallbackModel":"claude-opus-4-8","apiRefusalCategory":"cyber"}' '{"type":"assistant"}' > "$TRANSCRIPT"

fire() {  # fire <event> <source> [pid] -> stdout
  local event="$1" source="$2" pid="${3:-$$}"
  jq -nc --arg e "$event" --arg s "$source" --arg tp "$TRANSCRIPT" '{hook_event_name:$e, session_id:"sess-1", source:$s, from_model:"claude-opus-5[1m]", to_model:"claude-opus-4-8", requested_model:null, cwd:"/", transcript_path:$tp}' \
    | CLAUDE_PID="$pid" CLAUDE_CODE_SESSION_ID="sess-1" bash "$UNDER_TEST"
  echo "rc=$?"
}

echo "fallback note: an automatic switch is announced to the session"
out="$(fire PostModelSwitch auto)"
if [[ "$out" == *"rc=0" ]]; then pass "exit 0"; else fail "exit 0" "$out"; fi
ctx="$(printf '%s' "${out%rc=0}" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
if [[ "$ctx" == *"claude-opus-5[1m]"* && "$ctx" == *"claude-opus-4-8"* ]]; then pass "the note names both models"; else fail "the note names both models" "$ctx"; fi
if [[ "$ctx" == *"flagged your last request as a cybersecurity issue"* ]]; then pass "the note names the flagged category, read from the transcript"; else fail "the category" "$ctx"; fi
if [[ "$ctx" == *"filter out of everything you send"* && "$ctx" == *"GZCoord messages, commit messages, PR bodies, memories"* && "$ctx" == *"anything that could be read as a cybersecurity issue"* && "$ctx" == *"never its content"* ]]; then pass "the note asks to filter the category out of everything that follows"; else fail "the filter rule" "$ctx"; fi
if [[ "$ctx" == *"until /model"* && "$ctx" == *"Say in your next report"* ]]; then pass "the note says the switch is sticky and asks for it to be reported"; else fail "sticky and reported" "$ctx"; fi
if [[ "$(printf '%s' "${out%rc=0}" | jq -r '.hookSpecificOutput.hookEventName')" == "PostModelSwitch" ]]; then pass "the output names its event"; else fail "the output names its event"; fi
M="$AGENT_FABRIC_FALLBACK_DIR/$$.json"
if [[ -f "$M" && "$(jq -r .pid "$M")" == "$$" && "$(jq -r .to_model "$M")" == "claude-opus-4-8" && "$(jq -r .session_id "$M")" == "sess-1" && "$(jq -r .category "$M")" == "cyber" ]]; then pass "a marker names the harness pid, the session, the fallback model and the category"; else fail "the marker" "$(cat "$M" 2>/dev/null)"; fi
if [[ "$(stat -c %a "$AGENT_FABRIC_FALLBACK_DIR")" == "700" ]]; then pass "the marker directory is 700"; else fail "the marker directory is 700"; fi
# no transcript, or one without the line: the category is unnamed, the rule the same
out2="$(jq -nc '{hook_event_name:"PostModelSwitch", session_id:"s", source:"auto", from_model:"a", to_model:"b", transcript_path:"/nonexistent"}' | CLAUDE_PID=$$ bash "$UNDER_TEST")"
if [[ "$(printf '%s' "$out2" | jq -r .hookSpecificOutput.additionalContext)" == *"as the category the safeguard flagged"* ]]; then pass "without a transcript the category is unnamed"; else fail "without a transcript" "$out2"; fi

echo "fallback note: silent on every switch the session asked for"
rm -f "$M"
for src in command picker sdk resume; do
  out="$(fire PostModelSwitch "$src")"
  if [[ "$out" == "rc=0" ]]; then pass "PostModelSwitch $src: nothing"; else fail "PostModelSwitch $src: nothing" "$out"; fi
done
out="$(fire PreModelSwitch auto)"
if [[ "$out" == "rc=0" ]]; then pass "PreModelSwitch: nothing (the harness never sends auto there)"; else fail "PreModelSwitch: nothing" "$out"; fi
if [[ ! -f "$M" ]]; then pass "no marker written by any of them"; else fail "no marker written by any of them"; fi

echo "fallback note: a dead session's marker is swept"
printf '{"pid":4194304000,"session_id":"gone"}\n' > "$AGENT_FABRIC_FALLBACK_DIR/4194304000.json"
fire PostModelSwitch auto >/dev/null
if [[ ! -f "$AGENT_FABRIC_FALLBACK_DIR/4194304000.json" && -f "$M" ]]; then pass "dead swept, ours written"; else fail "dead swept, ours written" "$(ls "$AGENT_FABRIC_FALLBACK_DIR")"; fi

echo "fallback note: never loud"
out="$(printf 'not json' | bash "$UNDER_TEST"; echo "rc=$?")"; [[ "$out" == "rc=0" ]] && pass "malformed input is silent" || fail "malformed input is silent" "$out"
out="$(printf '' | bash "$UNDER_TEST"; echo "rc=$?")"; [[ "$out" == "rc=0" ]] && pass "empty input is silent" || fail "empty input is silent" "$out"

if (( failures )); then echo "fallback note: $failures failure(s)" >&2; exit 1; fi
echo "fallback note: OK — all assertions passed."
