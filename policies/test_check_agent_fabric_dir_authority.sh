#!/usr/bin/env bash
#
# policies/test_check_agent_fabric_dir_authority.sh
#
# Self-test for check_agent_fabric_dir_authority.sh, on a throwaway git
# repository: the guard's whole input is a COMMITTED diff against a base.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/check_agent_fabric_dir_authority.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }
failures=0
SANDBOX=""
cleanup() { [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; printf '%s\n' "${2:-}" | sed 's/^/      /' >&2; failures=$((failures+1)); }

# A managed-project repo: .agent-fabric/memory/<role>/ with a slice, and a
# holders file where $1 says ("project" -> .agent-fabric/authority.json,
# "fabric" -> policies/authority.json, "none" -> neither).
new_repo() {
  local where="${1:-project}"
  [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.agent-fabric/memory/backend-dev" "$SANDBOX/src"
  printf 'slice\n' > "$SANDBOX/.agent-fabric/memory/backend-dev/workflow.md"
  printf 'code\n' > "$SANDBOX/src/a.txt"
  local holders='{"role_definitions":{"role":"fabric-coordinator","holders":["gzcoord-coordinator"]}}'
  case "$where" in
    project) printf '%s\n' "$holders" > "$SANDBOX/.agent-fabric/authority.json" ;;
    fabric)  mkdir -p "$SANDBOX/policies"; printf '%s\n' "$holders" > "$SANDBOX/policies/authority.json" ;;
  esac
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email t@e; git -C "$SANDBOX" config user.name t
  git -C "$SANDBOX" add -A; git -C "$SANDBOX" commit -qm base
  git -C "$SANDBOX" branch -q base-ref
  git -C "$SANDBOX" branch -q -M sandbox-head
}
commit_change() {  # $1 = path relative to the sandbox
  mkdir -p "$SANDBOX/$(dirname "$1")"
  printf 'changed %s\n' "$RANDOM" >> "$SANDBOX/$1"
  git -C "$SANDBOX" add -A; git -C "$SANDBOX" commit -qm "touch $1"
}
run_guard() {  # $1 = branch name
  ( cd "$SANDBOX" && AGENT_FABRIC_ROOT=/nonexistent AGENT_FABRIC_CHARTER_BASE=base-ref \
      AGENT_FABRIC_CHARTER_BRANCH="$1" GITHUB_BASE_REF= bash "$UNDER_TEST" 2>&1 )
}
rc_of() { run_guard "$1" >/dev/null; echo $?; }

echo "nothing under .agent-fabric/ changed: passes regardless of branch"
new_repo project; commit_change src/a.txt
[[ "$(rc_of develop-qzapp/backend-dev-01/feat/x)" == 0 ]] && pass "a code change on any branch passes" || fail "code change refused"

echo "a slice changed on another role's branch: refused"
new_repo project; commit_change .agent-fabric/memory/backend-dev/workflow.md
[[ "$(rc_of develop-qzapp/backend-dev-01/feat/x)" == 1 ]] && pass "backend-dev's own branch cannot edit its slice" || fail "hand edit admitted"
[[ "$(rc_of develop-qzapp/architect-cto-01/feat/x)" == 1 ]] && pass "architect-cto is not the corpus owner either" || fail "architect admitted"
out="$(run_guard develop-qzapp/backend-dev-01/feat/x)"
grep -q "FAIL: .agent-fabric/ changed on a branch owned by agent 'backend-dev-01'" <<<"$out" && pass "the refusal names the agent" || fail "refusal wording" "$out"
grep -q "enters the corpus" <<<"$out" && pass "the refusal says how a correction enters" || fail "no remedy" "$out"

echo "a holder's branch: allowed, from each holders source"
new_repo project; commit_change .agent-fabric/memory/backend-dev/workflow.md
[[ "$(rc_of develop-qzapp/gzcoord-coordinator/chore/drain)" == 0 ]] && pass "listed holder, holders from .agent-fabric/authority.json" || fail "holder refused (project file)"
grep -q "holders from .agent-fabric/authority.json" <<<"$(run_guard develop-qzapp/gzcoord-coordinator/chore/drain)" && pass "says where the holders came from" || fail "source not named"
new_repo fabric; commit_change .agent-fabric/memory/backend-dev/workflow.md
[[ "$(rc_of develop-qzapp/gzcoord-coordinator/chore/drain)" == 0 ]] && pass "listed holder, holders from policies/authority.json (agent-fabric itself)" || fail "holder refused (fabric file)"
new_repo none; commit_change .agent-fabric/memory/backend-dev/workflow.md
[[ "$(rc_of develop-qzapp/fabric-coordinator/chore/drain)" == 0 ]] && pass "an account named for the role passes with no holders file at all" || fail "name convention ignored"
[[ "$(rc_of develop-qzapp/fabric-coordinator-02/chore/drain)" == 0 ]] && pass "…and so does its numbered sibling" || fail "numbered name refused"
[[ "$(rc_of develop-qzapp/gzcoord-coordinator/chore/drain)" == 1 ]] && pass "a listed-only holder is NOT recognised without a holders file" || fail "unlisted holder admitted"

echo "the sibling checkout supplies holders on a provisioned host"
new_repo none; commit_change .agent-fabric/memory/backend-dev/workflow.md
SIB="$(mktemp -d)"; mkdir -p "$SIB/policies"
printf '{"role_definitions":{"role":"fabric-coordinator","holders":["gzcoord-coordinator"]}}\n' > "$SIB/policies/authority.json"
rc="$( cd "$SANDBOX" && AGENT_FABRIC_ROOT="$SIB" AGENT_FABRIC_CHARTER_BASE=base-ref \
      AGENT_FABRIC_CHARTER_BRANCH=develop-qzapp/gzcoord-coordinator/chore/drain GITHUB_BASE_REF= bash "$UNDER_TEST" >/dev/null 2>&1; echo $? )"
[[ "$rc" == 0 ]] && pass "holders read from \$AGENT_FABRIC_ROOT/policies/authority.json" || fail "sibling holders ignored"
rm -rf "$SIB"

echo "a branch cannot appoint itself"
new_repo project
printf '{"role_definitions":{"role":"fabric-coordinator","holders":["backend-dev-01"]}}\n' > "$SANDBOX/.agent-fabric/authority.json"
git -C "$SANDBOX" add -A; git -C "$SANDBOX" commit -qm "appoint myself"
[[ "$(rc_of develop-qzapp/backend-dev-01/feat/x)" == 1 ]] && pass "holders are read from the base, not the branch" || fail "self-appointment admitted"

echo "where the head branch is not knowable, report and pass"
new_repo project; commit_change .agent-fabric/memory/backend-dev/workflow.md
[[ "$(rc_of gh-readonly-queue/main/pr-1-abc)" == 0 ]] && pass "merge-queue ref is not enforced" || fail "queue ref refused"
[[ "$(rc_of nobranchsegments)" == 0 ]] && pass "a branch with no agent segment is reported, not refused" || fail "segmentless refused"
rc="$( ( cd "$SANDBOX" && AGENT_FABRIC_CHARTER_BASE=no-such-ref GITHUB_BASE_REF= \
    AGENT_FABRIC_CHARTER_BRANCH=develop-qzapp/backend-dev-01/feat/x bash "$UNDER_TEST" >/dev/null 2>&1 ); echo $? )"
[[ "$rc" == 0 ]] && pass "no resolvable base: not enforced, not a failure" || fail "unresolvable base failed the build"

echo
if (( failures )); then echo "test_check_agent_fabric_dir_authority: $failures assertion(s) FAILED"; exit 1; fi
echo "all assertions passed"
