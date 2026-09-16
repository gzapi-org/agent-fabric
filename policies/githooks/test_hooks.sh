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
  printf '{"agent":"%s","host":"%s","role":%s,"project":"demo","working_copy":null,"updated_at":"x"}\n' \
    "$LOGIN" "$(hostname -s)" "$( [[ -n "$1" ]] && printf '"%s"' "$1" || printf null )" > "$TMP/state/agents/$LOGIN/binding.json"
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

echo "a commit outside .agent-fabric/ is untouched by the fence, and declares the role that made it"
bind backend-dev; new_repo
[[ "$(try_commit src/a.txt 'code')" == 0 ]] && pass "commits with any role" || fail "refused" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q '^Fabric-Role: backend-dev$' && pass "…and declares Fabric-Role: backend-dev (every account commits under one author; the trailer names the lane)" || fail "no trailer on a code commit" "$(git -C "$TMP/repo" log -1 --format=%B)"
[[ "$(try_commit src/a.txt $'typed\n\nFabric-Role: architect-cto')" == 0 ]] && pass "a typed trailer on a code commit is left as typed (a claim, not the binding)" || fail "refused" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -c '^Fabric-Role:' | grep -q '^1$' && pass "…and not doubled" || fail "trailer doubled" "$(git -C "$TMP/repo" log -1 --format=%B)"
rm -f "$TMP/state/agents/"*/binding.json
[[ "$(try_commit src/a.txt 'unbound')" == 0 ]] && pass "no binding: the commit is admitted" || fail "refused without a binding" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q 'Fabric-Role' && fail "a trailer with no binding to back it" || pass "…and declares nothing (a fact about the account, never a claim it cannot make)"

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

echo "in agent-fabric itself, every commit needs the role"
bind backend-dev; new_repo
mkdir -p "$TMP/repo/policies"; printf '{"role_definitions":{"role":"fabric-coordinator","holders":[]}}\n' > "$TMP/repo/policies/authority.json"
# The hooks recognise the fabric by their own location: point them at a copy living inside this repo.
mkdir -p "$TMP/repo/policies/githooks" "$TMP/repo/runtime"; cp "$HOOKS"/pre-commit "$HOOKS"/commit-msg "$HOOKS"/guarded-change.sh "$TMP/repo/policies/githooks/"
cp "$HOOKS/../../runtime/identity.py" "$TMP/repo/runtime/"   # the hooks read the binding through their own fabric's resolver
git -C "$TMP/repo" config core.hooksPath "$TMP/repo/policies/githooks"
git -C "$TMP/repo" add -A; git -C "$TMP/repo" -c core.hooksPath=/dev/null commit -qm "hooks in place"
[[ "$(try_commit src/a.txt 'code')" == 1 ]] && pass "backend-dev bound: a code change in the fabric is refused" || fail "fabric code change committed" "$(cat "$TMP/err")"
grep -q "agent-fabric itself" "$TMP/err" && pass "the refusal names the whole repository" || fail "wording" "$(cat "$TMP/err")"
bind fabric-coordinator
[[ "$(try_commit src/a.txt 'code')" == 0 ]] && pass "fabric-coordinator bound: allowed" || fail "coordinator refused in fabric" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q '^Fabric-Role: fabric-coordinator$' && pass "…and every fabric commit declares the role" || fail "no trailer on a fabric commit"

echo "in agent-fabric itself an amend is a guarded change too"
bind backend-dev
( cd "$TMP/repo" && AGENT_FABRIC_STATE_DIR="$TMP/state" git commit -q --amend --no-edit >/dev/null 2>"$TMP/err" ); rc=$?
[[ $rc == 1 ]] && pass "backend-dev bound: an amend in the fabric is refused" || fail "amend admitted under backend-dev" "$(cat "$TMP/err")"
bind fabric-coordinator
( cd "$TMP/repo" && git commit -q --amend -m 'rewritten' >/dev/null 2>"$TMP/err" ); rc=$?   # message without a trailer
( cd "$TMP/repo" && AGENT_FABRIC_STATE_DIR="$TMP/state" git commit -q --amend --no-edit >/dev/null 2>"$TMP/err" ); rc=$?
[[ $rc == 0 ]] && pass "fabric-coordinator bound: the amend commits" || fail "amend refused" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q '^Fabric-Role: fabric-coordinator$' && pass "…and the amend carries the trailer (git am + amend is the handover route)" || fail "no trailer on an amend" "$(git -C "$TMP/repo" log -1 --format=%B)"

echo "a merge that only folds main's .agent-fabric/ changes is no change of its own"
# main gets a drain (coordinator); a backend-dev branch then folds main.
bind fabric-coordinator; new_repo
git -C "$TMP/repo" checkout -q -b feature; printf 'feature\n' >> "$TMP/repo/src/a.txt"; git -C "$TMP/repo" add -A
( cd "$TMP/repo" && AGENT_FABRIC_STATE_DIR="$TMP/state" git commit -qm feature )
git -C "$TMP/repo" checkout -q master 2>/dev/null || git -C "$TMP/repo" checkout -q main
[[ "$(try_commit .agent-fabric/memory/backend-dev/workflow.md 'drain on main')" == 0 ]] || fail "setup: drain on main" "$(cat "$TMP/err")"
git -C "$TMP/repo" checkout -q feature; bind backend-dev
( cd "$TMP/repo" && AGENT_FABRIC_STATE_DIR="$TMP/state" git merge -q --no-ff --no-edit "$(git rev-parse --abbrev-ref @{-1})" >/dev/null 2>"$TMP/err" ); rc=$?
[[ $rc == 0 ]] && pass "backend-dev bound: the fold commits" || fail "the fold was refused" "$(cat "$TMP/err")"
git -C "$TMP/repo" log -1 --format=%B | grep -q '^Fabric-Role: backend-dev$' && pass "…and declares the role that folded it, as every commit does" || fail "no trailer on the fold" "$(git -C "$TMP/repo" log -1 --format=%B)"
[[ -z "$(git -C "$TMP/repo" diff HEAD^2 HEAD -- .agent-fabric/)" ]] && pass "…and .agent-fabric/ equals main's" || fail "fold altered .agent-fabric/"

echo "a merge that also hand-edits a slice is refused"
git -C "$TMP/repo" reset -q --hard HEAD^ ; bind backend-dev
( cd "$TMP/repo" && AGENT_FABRIC_STATE_DIR="$TMP/state" git merge -q --no-ff --no-commit "$(git rev-parse --abbrev-ref @{-1})" >/dev/null 2>&1; printf 'by hand\n' >> .agent-fabric/memory/backend-dev/workflow.md; git add -A; AGENT_FABRIC_STATE_DIR="$TMP/state" git commit -qm 'fold plus edit' >/dev/null 2>"$TMP/err" ); rc=$?
[[ $rc == 1 ]] && pass "backend-dev bound: refused" || fail "a merge carrying a hand edit was admitted"
grep -q "this agent's binding holds: backend-dev" "$TMP/err" && pass "…by the fence" || fail "wording" "$(cat "$TMP/err")"
( cd "$TMP/repo" && git merge --abort 2>/dev/null; git reset -q --hard )

echo "the attribution ban still holds on the same hook"
bind fabric-coordinator; new_repo
[[ "$(try_commit src/a.txt $'x\n\nCo-authored-by: Someone <s@e>')" == 1 ]] && pass "Co-authored-by is still refused" || fail "ban lost"

echo
if (( failures )); then echo "test_hooks: $failures assertion(s) FAILED"; exit 1; fi
echo "all assertions passed"
