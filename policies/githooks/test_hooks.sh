#!/usr/bin/env bash
# policies/githooks/test_hooks.sh — the .agent-fabric/ fence at the keyboard.
#
# pre-commit refuses a commit staging anything under .agent-fabric/ unless
# the agent's runtime binding holds the fabric-coordinator role; commit-msg
# then records that role as the Fabric-Role trailer. The binding is read
# through runtime/identity.py, so a throwaway AGENT_FABRIC_STATE_DIR is the
# whole fixture. Exit 0 = all assertions passed.
set -uo pipefail
HOOKS="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
failures=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; printf '%s\n' "${2:-}" | sed 's/^/      /' >&2; failures=$((failures+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOGIN="$(id -un)"

bind() {  # $1 = role or "" for none
  mkdir -p "$TMP/state/agents/$LOGIN"
  printf '{"agent":"%s","host":"h","role":%s,"project":"demo","working_copy":null,"updated_at":"x"}\n' \
    "$LOGIN" "$( [[ -n "$1" ]] && printf '"%s"' "$1" || printf null )" > "$TMP/state/agents/$LOGIN/binding.json"
}
new_repo() {
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo/.agent-fabric/memory/backend-dev" "$TMP/repo/src"
  git -C "$TMP/repo" init -q
  git -C "$TMP/repo" config user.email t@e; git -C "$TMP/repo" config user.name t
  git -C "$TMP/repo" config core.hooksPath "$HOOKS"
  printf 'code\n' > "$TMP/repo/src/a.txt"; printf 'slice\n' > "$TMP/repo/.agent-fabric/memory/backend-dev/workflow.md"
  git -C "$TMP/repo" add -A; git -C "$TMP/repo" -c core.hooksPath=/dev/null commit -qm base
}
try_commit() {  # $1 = path to touch, $2 = message; prints rc
  printf 'more\n' >> "$TMP/repo/$1"; git -C "$TMP/repo" add -A
  ( cd "$TMP/repo" && AGENT_FABRIC_STATE_DIR="$TMP/state" git commit -q -m "$2" >/dev/null 2>"$TMP/err" ); echo $?
}

echo "a commit outside .agent-fabric/ is untouched by the fence"
bind backend-dev; new_repo
[[ "$(try_commit src/a.txt 'code')" == 0 ]] && pass "commits with any role" || fail "refused" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q 'Fabric-Role' && fail "trailer added to an unrelated commit" || pass "no trailer added"

echo "a commit under .agent-fabric/ needs the role bound"
bind backend-dev; new_repo
[[ "$(try_commit .agent-fabric/memory/backend-dev/workflow.md 'hand edit')" == 1 ]] && pass "backend-dev bound: refused" || fail "hand edit committed"
grep -q "this agent's binding holds: backend-dev" "$TMP/err" && pass "the refusal says what is bound" || fail "wording" "$(cat "$TMP/err")"
bind ""; new_repo
[[ "$(try_commit .agent-fabric/memory/backend-dev/workflow.md 'hand edit')" == 1 ]] && pass "no role bound: refused" || fail "unbound commit admitted"
bind fabric-coordinator; new_repo
[[ "$(try_commit .agent-fabric/memory/backend-dev/workflow.md 'drain')" == 0 ]] && pass "fabric-coordinator bound: allowed" || fail "coordinator refused" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q '^Fabric-Role: fabric-coordinator$' && pass "…and the commit declares Fabric-Role: fabric-coordinator" || fail "no trailer" "$(git -C "$TMP/repo" log -1 --format=%B)"

echo "the declaration is the fact the fence checked, never a paste"
bind backend-dev; new_repo
[[ "$(try_commit .agent-fabric/memory/backend-dev/workflow.md $'x\n\nFabric-Role: fabric-coordinator')" == 1 ]] && pass "a typed trailer does not substitute for the binding" || fail "pasted trailer admitted"

echo "the attribution ban still holds on the same hook"
bind fabric-coordinator; new_repo
[[ "$(try_commit src/a.txt $'x\n\nCo-authored-by: Someone <s@e>')" == 1 ]] && pass "Co-authored-by is still refused" || fail "ban lost"

echo
if (( failures )); then echo "test_hooks: $failures assertion(s) FAILED"; exit 1; fi
echo "all assertions passed"
