#!/usr/bin/env bash
#
# policies/test_ban_generated_by_attribution.sh
#
# Self-test for ban_generated_by_attribution.sh.
#
# The thing this holds still is the RANGE. The guard must fail on a trailer
# the branch adds and stay silent about one already on the base -- a batch of
# those is already on main, and a guard that fails forever gets disabled,
# which is the same as no guard at all. Half of these cases exist to pin that
# asymmetry rather than the matching.
#
# The second thing is that PROSE IS NOT A TRAILER. This guard has to be
# describable in the commit message that introduces it, or the first person
# to explain it in a commit body is blocked by it.
#
# Every case builds a throwaway repo and runs the REAL guard against it.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed
set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/ban_generated_by_attribution.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: not found: $UNDER_TEST" >&2; exit 1; }

failures=0
SANDBOX="$(mktemp -d)"
cleanup() { [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; shift; [[ $# -gt 0 ]] && printf '       %s\n' "$@" >&2; failures=$((failures + 1)); }

setup() { "$@" || { echo "test: fixture setup failed: $*" >&2; exit 1; }; }

# A repo whose `main` already carries a banned trailer, so every case also
# proves the guard is not auditing landed history.
new_repo() {
    repo="$SANDBOX/r$RANDOM$RANDOM"
    setup mkdir -p "$repo"
    setup git -C "$repo" -c init.defaultBranch=main init -q
    setup git -C "$repo" config user.email t@example.invalid
    setup git -C "$repo" config user.name test
    setup git -C "$repo" config commit.gpgsign false
    setup git -C "$repo" commit -q --allow-empty -m "base work

Co-authored-by: Someone <someone@example.invalid>"
    setup git -C "$repo" checkout -q -b topic
}

# Runs the guard with the fixture's own main as the base.
# env -u, and it is load-bearing. GITHUB_EVENT_PATH is always set in
# Actions, so without this every "must pass" case below reads the
# description of whatever PR is running CI: a PR whose own body carries the
# footer turned three fixture assertions red, naming the description rather
# than the fixture. A self-test must not read the ambient event.
ISOLATE=(env -u GITHUB_EVENT_PATH -u GITHUB_BASE_REF -u GITHUB_HEAD_REF)
run_guard() { ( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main bash "$UNDER_TEST" 2>&1 ); }
guard_rc()  { ( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main bash "$UNDER_TEST" >/dev/null 2>&1; echo $? ); }

expect_rc() {
    local label="$1" want="$2" got
    got="$(guard_rc)"
    if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want rc=$want" "got  rc=$got" "$(run_guard | head -4)"; fi
}

echo "clean branches"

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: an ordinary commit"
expect_rc "an ordinary commit passes" 0

# The asymmetry this guard lives or dies by.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: adds nothing banned"
expect_rc "a trailer already on the BASE is not this branch's problem" 0

# The guard must be describable in the commit that introduces it.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat(checks): ban the Co-authored-by trailer

The harness keeps asking for a Co-Authored-By line and a Generated with
Claude Code footer. Prose naming them is not a trailer and must pass, or
this guard cannot be explained in the commit that adds it."
expect_rc "prose naming the banned strings is not a trailer" 0

# The killer for an UNANCHORED pattern: the key AND its colon, mid-sentence.
# The case above has no colon after the key, so it passed for a reason
# unrelated to anchoring and an unanchored regex survived it.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "docs: describe the ban

Do not add a Co-authored-by: trailer to a commit, and never a
session line: Claude-Session: is banned the same way."
expect_rc "the key mid-sentence, colon and all, is not a trailer" 0

echo "branches that must fail"

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

Co-authored-by: Claude <noreply@anthropic.invalid>"
expect_rc "a Co-authored-by trailer fails" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

co-AUTHORED-by: Claude <noreply@anthropic.invalid>"
expect_rc "the trailer match is case-insensitive" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

Co-authored-by:Claude <noreply@anthropic.invalid>"
expect_rc "a trailer with no space after the colon fails" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

An indented paste is still the line, not prose:

    Co-authored-by: Claude <noreply@anthropic.invalid>"
expect_rc "an INDENTED trailer is still a trailer" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

Generated with
[Claude Code](https://example.invalid)"
expect_rc "a hard-wrapped generated-with footer fails" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

Claude-Session: https://example.invalid/x"
expect_rc "a Claude-Session trailer fails" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

Generated with [Claude Code](https://example.invalid)"
expect_rc "a generated-with footer fails" 1

new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

https://claude.ai/code/session_0123456789"
expect_rc "a session URL fails" 1

# Only the SECOND of three commits offends: a guard that stops at the tip
# would pass this.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: first"
setup git -C "$repo" commit -q --allow-empty -m "feat: second

Co-authored-by: Claude <noreply@anthropic.invalid>"
setup git -C "$repo" commit -q --allow-empty -m "feat: third"
expect_rc "an offending commit in the MIDDLE of the range is found" 1
out="$(run_guard)"
if grep -q "feat: second" <<<"$out"; then
    pass "the failure names the offending commit"
else
    fail "the failure names the offending commit" "$out"
fi

echo "the pull-request description"

# The payload half needs no token: the body is in the event JSON.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: clean commit"
ev="$SANDBOX/event.json"
printf '{"pull_request":{"body":"Some description.\\n\\nGenerated with [Claude Code](https://example.invalid)\\n"}}' > "$ev"
rc="$( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main GITHUB_EVENT_PATH="$ev" bash "$UNDER_TEST" >/dev/null 2>&1; echo $? )"
if [[ "$rc" == "1" ]]; then
    pass "a PR description carrying the footer fails"
else
    fail "a PR description carrying the footer fails" "got rc=$rc"
fi

printf '{"pull_request":{"body":"An ordinary description with no attribution.\\n"}}' > "$ev"
rc="$( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main GITHUB_EVENT_PATH="$ev" bash "$UNDER_TEST" >/dev/null 2>&1; echo $? )"
if [[ "$rc" == "0" ]]; then
    pass "an ordinary PR description passes"
else
    fail "an ordinary PR description passes" "got rc=$rc"
fi

# A merge_group payload has no pull_request key; that must not be an error.
printf '{"merge_group":{"head_sha":"deadbeef"}}' > "$ev"
rc="$( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main GITHUB_EVENT_PATH="$ev" bash "$UNDER_TEST" >/dev/null 2>&1; echo $? )"
if [[ "$rc" == "0" ]]; then
    pass "a payload with no PR body is not an error"
else
    fail "a payload with no PR body is not an error" "got rc=$rc"
fi

echo "what cannot be checked must say so, never OK"

# An environment that cannot show a range must not fail every PR.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: work

Co-authored-by: Claude <noreply@anthropic.invalid>"
out="$( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=refs/nope bash "$UNDER_TEST" 2>&1 )"
rc=$?
if [[ "$rc" == "1" ]] && grep -q "FAIL" <<<"$out"; then
    pass "a bad override is not used unverified — the chain falls through"
else
    fail "a bad override is not used unverified — the chain falls through" "rc=$rc" "$out"
fi

# THE PATH THAT SILENTLY PASSED EVERYTHING. When no range resolves the guard
# must exit 0 -- an environment that cannot show a range is not a violation
# -- but it must NOT say OK, or a no-op reads as coverage. This is the line
# that made the first version green while enforcing nothing on every event,
# and it had no test at all.
orphan="$SANDBOX/orphan"
setup mkdir -p "$orphan"
setup git -C "$orphan" -c init.defaultBranch=solo init -q
setup git -C "$orphan" config user.email t@example.invalid
setup git -C "$orphan" config user.name test
setup git -C "$orphan" config commit.gpgsign false
setup git -C "$orphan" commit -q --allow-empty -m "work

Co-authored-by: Claude <noreply@anthropic.invalid>"
out="$( cd "$orphan" && "${ISOLATE[@]}" env -u GZAPP_ATTRIBUTION_BASE bash "$UNDER_TEST" 2>&1 )"
rc=$?
if [[ "$rc" == "0" ]] && grep -q "NOT ENFORCED" <<<"$out" && ! grep -q "OK —" <<<"$out"; then
    pass "no resolvable range: exits 0, says NOT ENFORCED, never says OK"
else
    fail "no resolvable range: exits 0, says NOT ENFORCED, never says OK" "rc=$rc" "$out"
fi

# Same rule for the description half: a payload it cannot read is not a pass.
new_repo
setup git -C "$repo" commit -q --allow-empty -m "feat: clean commit"
out="$( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main \
        GITHUB_EVENT_PATH="$SANDBOX/not-a-file.json" bash "$UNDER_TEST" 2>&1 )"
rc=$?
if [[ "$rc" == "0" ]] && grep -q "NOT ENFORCED" <<<"$out"; then
    pass "an unreadable payload says NOT ENFORCED rather than OK"
else
    fail "an unreadable payload says NOT ENFORCED rather than OK" "rc=$rc" "$out"
fi

printf 'this is not json{' > "$ev"
out="$( cd "$repo" && "${ISOLATE[@]}" GZAPP_ATTRIBUTION_BASE=main \
        GITHUB_EVENT_PATH="$ev" bash "$UNDER_TEST" 2>&1 )"
rc=$?
if [[ "$rc" == "0" ]] && grep -q "NOT ENFORCED" <<<"$out"; then
    pass "a malformed payload says NOT ENFORCED rather than OK"
else
    fail "a malformed payload says NOT ENFORCED rather than OK" "rc=$rc" "$out"
fi

echo
if [[ "$failures" -eq 0 ]]; then
    echo "all assertions passed"
    exit 0
fi
echo "$failures assertion(s) failed" >&2
exit 1
