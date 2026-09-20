#!/usr/bin/env bash
# tests/test_leak-check.sh — the leak check names what a run added and
# nothing else, whole names included.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leak-check.sh
. "$HERE/leak-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /'; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
mkdir "$SANDBOX/existing" "$SANDBOX/node-compile-cache"
snap="$(leak_snapshot "$SANDBOX")"

echo "nothing added"
out="$(leak_report "$SANDBOX" "$snap")"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "a run that added nothing passes silently" || bad "clean run" "$out"

echo "entries added"
mkdir "$SANDBOX/agentd-home-x1" "$SANDBOX/a b" "$SANDBOX/star*.py"
touch "$SANDBOX/a b/inner" "$SANDBOX/existing/inner-is-not-top-level"
out="$(cd "$HERE" && leak_report "$SANDBOX" "$snap")"; rc=$?
[[ $rc -eq 1 ]] && ok "a run that added entries fails" || bad "rc" "$out"
grep -qx '   agentd-home-x1' <<<"$out" && ok "the added directory is named" || bad "name" "$out"
grep -qx '   a b' <<<"$out" && ok "a name with a space is one entry" || bad "space" "$out"
grep -qx '   star\*.py' <<<"$out" && ok "a glob character is printed, not expanded" || bad "glob" "$out"
grep -q 'existing' <<<"$out" && bad "a pre-existing entry was reported" "$out" || ok "pre-existing entries are never reported"
[[ "$(grep -c '^   ' <<<"$out")" == 3 ]] && ok "exactly the three added entries" || bad "count" "$out"

echo "the directory"
[[ "$(TMPDIR=/x/y leak_dir)" == /x/y ]] && ok "TMPDIR first" || bad "TMPDIR"
[[ "$(env -u TMPDIR TMP=/t bash -c '. "'"$HERE"'/leak-check.sh"; leak_dir')" == /t ]] && ok "then TMP" || bad "TMP"
[[ "$(env -u TMPDIR -u TMP -u TEMP bash -c '. "'"$HERE"'/leak-check.sh"; leak_dir')" == /tmp ]] && ok "then /tmp" || bad "/tmp"

echo "run.sh uses it"
grep -q 'leak-check.sh' "$HERE/run.sh" && grep -q 'leak_report' "$HERE/run.sh" && ok "run.sh sources the check and reports with it" || bad "run.sh wiring"

echo; echo "leak-check: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
