#!/usr/bin/env bash
# tests/test_fabric-usage.sh — the sudo fallback's per-account read, run
# against a scratch home: a login on a Claude-account template is
# `setup-token` (its own sign-in is another account's; the template cannot
# read usage), and neither token is ever printed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -6; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
# The READ heredoc, exactly as bin/fabric-usage hands it to the executor.
READ="$(awk "/^read -r -d '' READ <<'EOF'/{f=1;next} f&&/^EOF\$/{exit} f" "$ROOT/bin/fabric-usage")"
[[ -n "$READ" ]] && ok "the per-account read is found in bin/fabric-usage" || bad "READ not extracted"

H="$SANDBOX/h"; mkdir -p "$H/.claude" "$H/.config/agent-fabric"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-OWN-SIGNIN"}}' > "$H/.claude/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"old@example.org"}}' > "$H/.claude.json"
printf "export CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-TEMPLATE'\n" > "$H/.config/agent-fabric/secrets.env"
# curl must never run for a template login: a fake that records it.
mkdir -p "$SANDBOX/bin"; printf '#!/bin/sh\ntouch "%s/curl-ran"\nexit 7\n' "$SANDBOX" > "$SANDBOX/bin/curl"; chmod +x "$SANDBOX/bin/curl"
out="$(HOME="$H" PATH="$SANDBOX/bin:$PATH" sh -c "$READ" 2>&1)"
[[ "$out" == "setup-token" && ! -e "$SANDBOX/curl-ran" ]] && ok "a login on a template reads as setup-token, not as its old account" || bad "template login" "$out"
! grep -q "old@example.org\|sk-ant-" <<<"$out" && ok "…with neither its old email nor any token in the output" || bad "leak" "$out"

rm -f "$H/.config/agent-fabric/secrets.env"
out="$(HOME="$H" PATH="$SANDBOX/bin:$PATH" sh -c "$READ" 2>&1)"
[[ -e "$SANDBOX/curl-ran" ]] && grep -q "^read-failed	old@example.org$" <<<"$out" && ok "no template: the login's own sign-in is read, as before" || bad "own sign-in path" "$out"
! grep -q "sk-ant-" <<<"$out" && ok "…and its token stays out of the output" || bad "leak" "$out"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_fabric-usage: OK — $PASS assertion(s) passed."; else echo "test_fabric-usage: FAILED — $FAIL assertion(s) failed."; exit 1; fi
