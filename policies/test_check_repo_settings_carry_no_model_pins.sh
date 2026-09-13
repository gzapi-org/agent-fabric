#!/usr/bin/env bash
# policies/test_check_repo_settings_carry_no_model_pins.sh
#
# Self-test: every way a model pin can sneak into the committed settings
# scope, and the case where the file is absent.
set -uo pipefail
GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_repo_settings_carry_no_model_pins.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -4; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
F="$SANDBOX/settings.json"
run() { GZAPP_SETTINGS_FILE="$F" bash "$GUARD" 2>&1; }

echo "check_repo_settings_carry_no_model_pins: a clean file passes"
printf '%s\n' '{"env":{"GZAPP_ACTIONS_INCLUDED_MINUTES":"50000"},"enabledMcpjsonServers":["dart"]}' > "$F"
[[ "$(GZAPP_SETTINGS_FILE=$F bash "$GUARD"; echo $?)" == *0 ]] && ok "clean settings: exit 0" || bad "rejected a clean file"

echo "check_repo_settings_carry_no_model_pins: each pin shape is caught"
for case in '{"model":"claude-opus-5"}' '{"modelOverrides":{"claude-opus-5":"z-ai/glm-5.3"}}' \
            '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"x"}}' '{"env":{"ANTHROPIC_API_KEY":"x"}}' \
            '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"x"}}' '{"env":{"ANTHROPIC_BASE_URL":"http://x"}}'; do
    printf '%s' "$case" > "$F"
    out="$(GZAPP_SETTINGS_FILE=$F bash "$GUARD" 2>&1)"; rc=$?
    [[ $rc -ne 0 ]] && ok "$(python3 -c "import json;print(sorted(json.load(open('$F')).keys()) or json.load(open('$F')).get('env',{}))" | head -c 40) rejected" || bad "green on $case" "$out"
done

echo "check_repo_settings_carry_no_model_pins: unparseable JSON fails loudly"
printf '%s' '{broken' > "$F"
out="$(GZAPP_SETTINGS_FILE=$F bash "$GUARD" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "exit non-zero" || bad "green on broken json" "$out"

echo "check_repo_settings_carry_no_model_pins: a missing file is OK"
[[ "$(GZAPP_SETTINGS_FILE=$SANDBOX/absent bash "$GUARD"; echo $?)" == *0 ]] && ok "absent file: exit 0" || bad "failed on absence"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_check_repo_settings_carry_no_model_pins: OK — $PASS assertion(s)."
else echo "test_check_repo_settings_carry_no_model_pins: FAILED — $FAIL."; exit 1; fi
