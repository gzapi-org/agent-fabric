#!/usr/bin/env bash
# runtime/claude-code/test_attribution-off.sh
#
# The harness's attribution reminder off at its source: attribution-off.py
# writes attribution {commit "", pr "", sessionUrl false} into a login's
# user settings, keeps every other key, replaces the deprecated
# includeCoAuthoredBy, is idempotent, and bootstrap.sh runs it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -6; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
S="$SANDBOX/.claude/settings.json"
run() { python3 "$HERE/attribution-off.py" "$@" 2>&1; }
check() { python3 -c "import json,sys; d=json.load(open('$S')); a=d['attribution']; assert (a['commit'],a['pr'],a['sessionUrl'])==('','',False), d; $1" 2>&1; }

echo "a login with no settings file"
out="$(run "$S" --dry-run)"; [[ "$out" == "  +  $S attribution off (would write)" && ! -e "$S" ]] && ok "dry run names it and writes nothing" || bad "dry run" "$out"
out="$(run "$S")"; [[ "$out" == "  +  $S attribution off" ]] && check "" >/dev/null && ok "written, the directory created" || bad "write" "$out $(cat "$S" 2>&1)"
out="$(run "$S")"; [[ "$out" == "  =  $S attribution off" ]] && ok "a second run changes nothing" || bad "idempotence" "$out"

echo "a login with settings of its own"
printf '{"theme": "dark", "includeCoAuthoredBy": false, "attribution": {"commit": "Co-Authored-By: x", "extra": 1}, "permissions": {"deny": ["WebSearch"]}}\n' > "$S"
out="$(run "$S")"
[[ "$out" == "  +  "* ]] && msg="$(check "assert d['theme']=='dark' and d['permissions']['deny']==['WebSearch'] and d['attribution']['extra']==1 and 'includeCoAuthoredBy' not in d, d")" && ok "the key set, the deprecated switch removed, everything else kept" || bad "merge" "$out ${msg:-} $(cat "$S")"
printf '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}, "includeCoAuthoredBy": true}\n' > "$S"
out="$(run "$S")"; [[ "$out" == "  +  "* ]] && check "assert 'includeCoAuthoredBy' not in d" >/dev/null && ok "a deprecated switch beside the key is still removed" || bad "deprecated switch" "$out"
printf 'not json\n' > "$S"; out="$(run "$S" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "an unreadable file is refused, not overwritten (exit $rc)" || bad "unreadable file" "$out"
out="$(run 2>&1)"; [[ $? -eq 2 ]] && ok "no path: usage, exit 2" || bad "usage" "$out"

echo "bootstrap runs it"
grep -q 'attribution-off.py" "\$CLAUDE_HOME/settings.json"' "$HERE/bootstrap.sh" && ok "bootstrap.sh calls it on the login's user settings" || bad "bootstrap wiring"

echo; echo "attribution-off: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
