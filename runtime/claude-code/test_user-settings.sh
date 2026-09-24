#!/usr/bin/env bash
# runtime/claude-code/test_user-settings.sh
#
# The fabric's keys in a login's user settings: user-settings.py writes
# attribution {commit "", pr "", sessionUrl false}, showThinkingSummaries
# true and verbose true, keeps every other key, replaces the deprecated
# includeCoAuthoredBy, is idempotent, and bootstrap.sh runs it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -6; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
S="$SANDBOX/.claude/settings.json"
run() { python3 "$HERE/user-settings.py" "$@" 2>&1; }
check() { python3 -c "import json,sys; d=json.load(open('$S')); a=d['attribution']; assert (a['commit'],a['pr'],a['sessionUrl'])==('','',False), d; assert d['showThinkingSummaries'] is True and d['verbose'] is True, d; $1" 2>&1; }

echo "a login with no settings file"
out="$(run "$S" --dry-run)"; [[ "$out" == "  +  $S fabric user settings (would write)" && ! -e "$S" ]] && ok "dry run names it and writes nothing" || bad "dry run" "$out"
out="$(run "$S")"; [[ "$out" == "  +  $S fabric user settings" ]] && check "" >/dev/null && ok "written, the directory created, every key present" || bad "write" "$out $(cat "$S" 2>&1)"
out="$(run "$S")"; [[ "$out" == "  =  $S fabric user settings" ]] && ok "a second run changes nothing" || bad "idempotence" "$out"

echo "a login with settings of its own"
printf '{"theme": "dark", "includeCoAuthoredBy": false, "attribution": {"commit": "Co-Authored-By: x", "extra": 1}, "permissions": {"deny": ["WebSearch"]}}\n' > "$S"
out="$(run "$S")"
[[ "$out" == "  +  "* ]] && msg="$(check "assert d['theme']=='dark' and d['permissions']['deny']==['WebSearch'] and d['attribution']['extra']==1 and 'includeCoAuthoredBy' not in d, d")" && ok "the keys set, the deprecated switch removed, everything else kept" || bad "merge" "$out ${msg:-} $(cat "$S")"
printf '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}, "includeCoAuthoredBy": true, "showThinkingSummaries": true, "verbose": true}\n' > "$S"
out="$(run "$S")"; [[ "$out" == "  +  "* ]] && check "assert 'includeCoAuthoredBy' not in d" >/dev/null && ok "a deprecated switch beside the keys is still removed" || bad "deprecated switch" "$out"
# The display keys are what an account bootstrapped before 2026-09-20
# lacks: attribution already off, nothing else set. That account is
# rewritten, not reported settled.
printf '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}, "verbose": false}\n' > "$S"
out="$(run "$S")"; [[ "$out" == "  +  "* ]] && check "" >/dev/null && ok "attribution already off, the display keys still written (verbose false overridden)" || bad "display keys" "$out $(cat "$S")"
printf 'not json\n' > "$S"; out="$(run "$S" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == "  !  "*"NOT written"* && "$(cat "$S")" == "not json" ]] && ok "an unreadable file is refused with one line, not a traceback, and not overwritten" || bad "unreadable file" "$out"
printf '[1]\n' > "$S"; out="$(run "$S" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$(cat "$S")" == "[1]" ]] && ok "a JSON file that is not an object is refused too" || bad "non-object" "$out"
out="$(run 2>&1)"; [[ $? -eq 2 ]] && ok "no path: usage, exit 2" || bad "usage" "$out"

echo "bootstrap runs it"
grep -q 'user-settings.py" "\$CLAUDE_HOME/settings.json"' "$HERE/bootstrap.sh" && ok "bootstrap.sh calls it on the login's user settings" || bad "bootstrap wiring"
echo "a flag is never a path"
cd "$SANDBOX" || exit 1
for flag in --help -h; do
    out="$(run "$flag")"; rc=$?
    [[ $rc -eq 0 && "$out" == *"user-settings.py <settings.json> [--dry-run]"* && -z "$(ls -A "$SANDBOX" | grep -v '^\.claude$')" ]] \
        && ok "$flag prints the usage and writes nothing" || bad "$flag" "rc=$rc $out $(ls -A "$SANDBOX")"
done
out="$(run --verbose)"; rc=$?
[[ $rc -eq 2 && ! -e "$SANDBOX/--verbose" ]] && ok "an unknown flag is refused, not written as a file" || bad "unknown flag" "rc=$rc $out"
out="$(run --dry-run --bogus)"; rc=$?
[[ $rc -eq 2 && ! -e "$SANDBOX/--bogus" ]] && ok "…beside --dry-run too" || bad "unknown flag with --dry-run" "rc=$rc $out"
cd "$HERE" || exit 1
grep -q 'attribution-off' "$HERE/bootstrap.sh" && bad "bootstrap.sh still names the retired writer" || ok "the retired name is gone from bootstrap.sh"
grep -q 'failed=\$((failed+1))' "$HERE/bootstrap.sh" && ok "a refused write is counted, not read as already current" || bad "bootstrap accounting"

echo; echo "user-settings: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
