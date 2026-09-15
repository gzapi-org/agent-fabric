#!/usr/bin/env bash
# tests/test_fabric-status.sh — bin/fabric-status says what this session was
# launched as, and says DRIFT when the binding, the session default or the
# prompt file moved under it. Runs the real script against a throwaway
# state dir; the stamps a launch exports are forged in the environment.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; ROOT="$(dirname "$HERE")"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/      /'; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
STATE="$SANDBOX/state"; LOGIN="$(id -un)"
mkdir -p "$STATE/agents/$LOGIN"
printf '{"agent":"%s","host":"h","role":"db-admin","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
printf 'prompt text\n' > "$STATE/agents/$LOGIN/launch-prompt.md"
DIGEST="sha256:$(sha256sum "$STATE/agents/$LOGIN/launch-prompt.md" | cut -d' ' -f1)"

# Nothing a real session exported may leak into the forged one.
status() { env -u AGENT_FABRIC_LAUNCH_ROLE -u AGENT_FABRIC_LAUNCH_PROMPT_DIGEST -u AGENT_FABRIC_LAUNCH_SESSION_MODEL \
               -u AGENT_FABRIC_LAUNCH_PROVIDER -u AGENT_FABRIC_LAUNCH_PROFILE -u ANTHROPIC_BASE_URL \
               AGENT_FABRIC_STATE_DIR="$STATE" "$@" bash "$ROOT/bin/fabric-status" "${MODE[@]}"; }
MODE=()

echo "fabric-status: unlaunched — nothing to drift from"
out="$(status 2>&1)"
grep -q "^role         db-admin" <<<"$out" && ok "the bound role" || bad "role missing" "$out"
! grep -q "DRIFT\|launched as" <<<"$out" && ok "no launch stamp: no drift line, no 'launched as'" || bad "drift without a stamp" "$out"

echo "fabric-status: launched as the bound role, prompt intact"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROMPT_DIGEST="$DIGEST" AGENT_FABRIC_LAUNCH_PROVIDER=anthropic 2>&1)"
grep -q "^launched as  db-admin    prompt $DIGEST" <<<"$out" && ok "says what it was launched as, with the prompt digest" || bad "no launched-as line" "$out"
! grep -q "DRIFT" <<<"$out" && ok "…and no drift" || bad "false drift" "$out"

echo "fabric-status: the binding moved under the session"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=backend-dev AGENT_FABRIC_LAUNCH_PROMPT_DIGEST="$DIGEST" 2>&1)"
grep -q "^DRIFT        launched as backend-dev, binding now db-admin" <<<"$out" && grep -q "relaunch to hold db-admin" <<<"$out" && ok "role drift is one DRIFT line naming both and the fix" || bad "role drift not said" "$out"
MODE=(--json); out="$(status AGENT_FABRIC_LAUNCH_ROLE=backend-dev 2>&1)"; MODE=()
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["launched_role"]=="backend-dev" and any("binding now db-admin" in x for x in d["drift"])' <<<"$out" && ok "…and in the JSON report" || bad "json report lacks drift" "$out"

echo "fabric-status: the prompt file moved under the session"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROMPT_DIGEST=sha256:0000 2>&1)"
grep -q "^DRIFT        the prompt file was rewritten since launch" <<<"$out" && ok "a digest mismatch is said" || bad "prompt drift not said" "$out"
rm "$STATE/agents/$LOGIN/launch-prompt.md"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROMPT_DIGEST="$DIGEST" 2>&1)"
grep -q "^DRIFT        the launched prompt file is gone" <<<"$out" && ok "a missing file is said, not a crash" || bad "missing prompt file" "$out"

echo "fabric-status: the session default moved under the session"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROVIDER=anthropic AGENT_FABRIC_LAUNCH_SESSION_MODEL=claude-sonnet-5 2>&1)"
grep -q "^DRIFT        launched on claude-sonnet-5, the anthropic session now resolves to" <<<"$out" && grep -q "relaunch to apply" <<<"$out" && ok "a changed session default is said with the current resolution" || bad "session drift not said" "$out"
current="$(grep "the anthropic session now resolves to" <<<"$out" | sed 's/.*resolves to \([^ ]*\) .*/\1/')"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROVIDER=anthropic AGENT_FABRIC_LAUNCH_SESSION_MODEL="$current" 2>&1)"
! grep -q "launched on" <<<"$out" && ok "launched on what now resolves: no drift" || bad "false session drift" "$out"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_fabric-status: OK — $PASS assertion(s) passed."; else echo "test_fabric-status: FAILED — $FAIL assertion(s) failed."; exit 1; fi
