#!/usr/bin/env bash
# runtime/provisioning/test_new-agent.sh — new-agent.sh refuses what the
# fabric does not know, and its dry run names every step without touching
# the host. The real path needs root and Doppler and is exercised on a
# host, not here; what a sandbox can hold is the plan and the refusals.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
UNDER_TEST="$HERE/new-agent.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/      /'; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
# A fixture fabric: the real roles and registry, a fake claude to copy from.
FAB="$SANDBOX/fabric"; mkdir -p "$FAB/runtime/provisioning/secrets" "$FAB/identities" "$FAB/projects" "$SANDBOX/home/.local/bin"
cp -r "$ROOT/identities/roles" "$FAB/identities/"; cp "$ROOT/projects/registry.json" "$FAB/projects/"; cp "$UNDER_TEST" "$FAB/runtime/provisioning/"
printf '#!/bin/sh\necho fake\n' > "$SANDBOX/home/.local/bin/claude"; chmod +x "$SANDBOX/home/.local/bin/claude"
run() { HOME="$SANDBOX/home" bash "$FAB/runtime/provisioning/new-agent.sh" "$@" 2>&1; }

echo "new-agent: refusals"
out="$(run 2>&1)"; [[ $? -eq 2 ]] && grep -q "^usage:" <<<"$out" && ok "no arguments: usage, exit 2" || bad "usage" "$out"
out="$(run some-login no-such-role --dry-run)"; [[ $? -eq 1 ]] && grep -q "no role 'no-such-role'" <<<"$out" && ok "an unknown role is refused before anything runs" || bad "unknown role" "$out"
out="$(run some-login backend-dev --project not-registered --dry-run)"; [[ $? -eq 1 ]] && grep -q "not in projects/registry.json" <<<"$out" && ok "an unregistered project is refused" || bad "unregistered project" "$out"
out="$(run some-login backend-dev --bogus --dry-run)"; [[ $? -eq 2 ]] && ok "an unknown flag is a usage error" || bad "unknown flag" "$out"

echo "new-agent: the dry run names every step and touches nothing"
out="$(run zz-fixture-login backend-dev --project gzapp --project agent-fabric --dry-run)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0" || bad "rc=$rc" "$out"
for step in "useradd" "chmod 700" "mkdir -p" "ssh-keyscan github.com" "git clone -q https://github.com/gzapi-org/agent-fabric.git" "enroll.sh zz-fixture-login; fill-from" "issue-openrouter-keys and issue-openai-keys" "git clone -q 'git@github.com:gzapi-org/gzapp.git'" "bootstrap.sh" "fabric-role bind 'backend-dev'"; do
    grep -qF "$step" <<<"$out" && ok "plans: $step" || bad "missing step: $step" "$out"
done
grep -q "dry run: nothing verified" <<<"$out" && ok "…and verifies nothing" || bad "verified in dry run" "$out"
! getent passwd zz-fixture-login >/dev/null && ok "no account was created" || bad "an account was created by a dry run"
grep -q "git@github.com" <<<"$out" && ok "a project clone uses the registry's SSH remote" || bad "remote" "$out"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_new-agent: OK — $PASS assertion(s) passed."; else echo "test_new-agent: FAILED — $FAIL assertion(s) failed."; exit 1; fi
