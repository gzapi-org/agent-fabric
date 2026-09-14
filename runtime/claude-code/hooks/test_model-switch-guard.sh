#!/usr/bin/env bash
# runtime/claude-code/hooks/test_model-switch-guard.sh
#
# Behavioural tests for model-switch-guard.sh.
#
# What this holds still: in a broker session a bare /model to a family
# that needs a shim is denied and the composite is named; a composite, a
# family with no shim, and a vanilla session pass; a guard that cannot
# consult routing asks. Every case pipes a PreModelSwitch payload through
# the REAL script against THIS checkout's routing files, so the shimmed
# families are whatever routing/shims.json says today.
#
# Exit codes: 0 all assertions passed; 1 one or more failed
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/model-switch-guard.sh"
FABRIC="$( cd -- "$SCRIPT_DIR/../../.." && pwd )"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }
failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2; failures=$((failures + 1)); }

# A shimmed family and its shim, read from the routing file rather than
# hard-coded, so the test follows the policy instead of naming a vendor.
SHIMMED="$(jq -r '.shims[0].family' "$FABRIC/routing/shims.json" | sed 's/\*$/5.3/; s/\*/x/g')"
SHIM="$(jq -r '.shims[0].shim' "$FABRIC/routing/shims.json")"
UNSHIMMED="example/no-shim-model"
[[ -z "$(python3 "$FABRIC/tools/fabric/routing.py" --fabric "$FABRIC" shim "$UNSHIMMED")" ]] || { echo "test: fixture $UNSHIMMED unexpectedly has a shim" >&2; exit 1; }

# decision <to_model> [requested_model] [profile|-] -> allow | deny | ask | malformed
decision() {
  local to="$1" req="${2:-}" profile="${3:-broker-test}" out payload
  payload=$(jq -nc --arg t "$to" --arg r "$req" '{to_model:$t} + (if $r == "" then {} else {requested_model:$r} end)')
  if [[ "$profile" == "-" ]]; then
    out="$(printf '%s' "$payload" | env -u AGENT_FABRIC_LAUNCH_PROFILE AGENT_FABRIC_ROOT="$FABRIC" bash "$UNDER_TEST" 2>/dev/null)"
  else
    out="$(printf '%s' "$payload" | env AGENT_FABRIC_LAUNCH_PROFILE="$profile" AGENT_FABRIC_ROOT="$FABRIC" bash "$UNDER_TEST" 2>/dev/null)"
  fi
  if [[ -z "$out" ]]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"'; fi
}
expect() {
  local label="$1" want="$2"; shift 2
  local got; got="$(decision "$@")"
  if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want $want, got $got"; fi
}

echo "model-switch guard: a vanilla session is never touched"
expect "bare shimmed id, no launch profile: allowed" allow "$SHIMMED" "" -
expect "anything at all, no launch profile: allowed" allow "$UNSHIMMED" "" -

echo "model-switch guard: in a broker session a bare shimmed id is refused"
expect "bare $SHIMMED is denied" deny "$SHIMMED"
expect "the composite of the same model is allowed" allow "$SHIMMED$SHIM"
expect "a request spelled as the composite is allowed even if to_model is bare" allow "$SHIMMED" "$SHIMMED$SHIM"
expect "a family with no shim rides bare" allow "$UNSHIMMED"
expect "a bare preset is allowed (it already is one)" allow "@preset/reviewer"

echo "model-switch guard: the denial names the composite to use instead"
out="$(printf '{"to_model":"%s"}' "$SHIMMED" | env AGENT_FABRIC_LAUNCH_PROFILE=p1 AGENT_FABRIC_ROOT="$FABRIC" bash "$UNDER_TEST")"
if grep -qF "$SHIMMED$SHIM" <<<"$out"; then pass "names the composite"; else fail "names the composite" "$out"; fi
if grep -q "profile p1" <<<"$out"; then pass "names the launch profile"; else fail "names the launch profile" "$out"; fi
if grep -q "PreModelSwitch" <<<"$out"; then pass "answers on the PreModelSwitch event"; else fail "answers on the PreModelSwitch event" "$out"; fi

echo "model-switch guard: when routing cannot be consulted it asks, never allows"
out="$(printf '{"to_model":"%s"}' "$SHIMMED" | env AGENT_FABRIC_LAUNCH_PROFILE=p1 AGENT_FABRIC_ROOT=/nonexistent bash "$UNDER_TEST" 2>/dev/null)"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then pass "routing.py missing: asks"; else fail "routing.py missing: asks" "[$out]"; fi
out="$(printf '{"to_model":"%s"}' "$SHIMMED" | env AGENT_FABRIC_LAUNCH_PROFILE=p1 AGENT_FABRIC_ROOT="$FABRIC" PATH=/nonexistent /bin/bash "$UNDER_TEST" 2>/dev/null)"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then pass "jq unavailable: asks"; else fail "jq unavailable: asks" "[$out]"; fi

echo "model-switch guard: malformed input never exits 2"
for payload in '{}' 'not json' '' '{"to_model":""}'; do
  out="$(printf '%s' "$payload" | env AGENT_FABRIC_LAUNCH_PROFILE=p1 AGENT_FABRIC_ROOT="$FABRIC" bash "$UNDER_TEST" 2>/dev/null)"; rc=$?
  if [[ "$rc" -ne 2 ]]; then pass "payload (${payload:-empty}) rc=$rc"; else fail "payload (${payload:-empty}) exited 2" "$out"; fi
done

echo
if [[ "$failures" -eq 0 ]]; then echo "test_model-switch-guard: OK — all assertions passed."; exit 0; fi
echo "test_model-switch-guard: FAILED — $failures assertion(s) failed." >&2; exit 1
