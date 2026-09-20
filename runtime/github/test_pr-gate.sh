#!/usr/bin/env bash
# runtime/github/test_pr-gate.sh (lifted from the first managed project's tools/gh/ on 2026-09-19 — the commit names it; general to every managed project, whose own tools/gh/ copy is a forwarder through projects/<id>/integration/gh/)
#
# Tests for pr-gate.sh with gh and pr-review-status.sh mocked on PATH and
# a throwaway git repository for the commit classification: the work /
# fix / merge split, each verdict (ask the owner, arm, split, blocked by
# red checks, pending checks, no review, threads, a conflict; armed;
# queued), the session filter, --all, numbers, --json, and the empty
# states.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed

set -u

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/pr-gate.sh"
[[ -f "$UNDER_TEST" ]] || { echo "test: script under test not found at $UNDER_TEST" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test: jq is required" >&2; exit 1; }

failures=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; printf '%s\n' "${2:-}" | sed 's/^/      /' >&2; failures=$((failures + 1)); }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/state"
STATE="$SANDBOX/state"

# ── a repository with an origin: main, and a branch of 2 work + 1 fix + 1 merge ──
git init -q --bare "$SANDBOX/origin.git"
git init -q -b main "$SANDBOX/repo"; cd "$SANDBOX/repo" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false; git config tag.gpgSign false
git remote add origin "$SANDBOX/origin.git"
c() { printf '%s\n' "$1" >> f.txt; git add -A; git commit -q -m "$1"; }
c "base"; git push -q origin main
git checkout -q -b develop-qzapp/me/feat/thing
c "work one"; c "work two"
git checkout -q -b side main; printf 'side\n' > g.txt; git add -A; git commit -q -m "side change"; git checkout -q develop-qzapp/me/feat/thing; git merge -q --no-ff side -m "Merge origin/main"
c "fix: the review's F1 and F2"
c "admin driver review: approving a stranded applicant gets its own 409"
c "fix(passenger): the debounce still fired the wrong query"
c "geocode: address the blind review of the entrypoint"
c "third-round review: four P3s, the .env pin and the dropped spellings"
c "feat(contracts): the review decision's reason reaches the merchant"
# A fix whose subject names no review at all, carrying the trailer.
printf 'trailer\n' >> f.txt; git add -A; git commit -q -m "db: 0055's guard was too broad and stopped the file re-applying" -m "Answers: PE-6"
# A FOLDED trailer value (RFC-822 continuation): one record, one fix —
# never a phantom work commit from the continuation line (#894 review F2).
printf 'folded\n' >> f.txt; git add -A; git commit -q -m "docs(adr): the backfilled row keeps its updated_at" -m "$(printf 'Answers: PE-6,\n  PR-1')"
HEAD_SHA="$(git rev-parse HEAD)"
git push -q origin develop-qzapp/me/feat/thing

# ── the mocks ──
cat > "$SANDBOX/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
S="$MOCK_STATE"; args="$*"
case "$args" in
  "repo view"*) echo "testorg/testrepo"; exit 0 ;;
  "pr list"*) cat "$S/prs.json"; exit 0 ;;
  "pr view"*) n="$3"; r="$(jq -c --argjson n "$n" '.[] | select(.number == $n)' "$S/prs.json" "$S/closed.json" 2>/dev/null | head -1)"; [[ -n "$r" ]] || exit 1; printf '%s\n' "$r"; exit 0 ;;
  *graphql*) [[ -f "$S/graphql_fail" ]] && exit 1; cat "$S/graphql.json"; exit 0 ;;
esac
echo "mock gh: unhandled $args" >&2; exit 1
GHMOCK
cat > "$SANDBOX/bin/pr-review-status.sh" <<'RS'
#!/usr/bin/env bash
S="$MOCK_STATE"
echo "PR #$1  state=OPEN"
echo "  independent reviews : $(cat "$S/reviews" 2>/dev/null || echo 0)"
echo "  blind reviews       : 0"
echo "  verdict comments    : $(cat "$S/verdicts" 2>/dev/null || echo 0)"
echo "  head reviewed?      : $(cat "$S/head_reviewed" 2>/dev/null || echo no)"
echo "  unresolved threads  : 0"
exit 0
RS
chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/pr-review-status.sh"

prs() { printf '%s' "$1" > "$STATE/prs.json"; }
graphql() {  # graphql <mergeable> <unresolved> <armed yes|no> <queue pos|""> <check nodes json>
    jq -n --arg m "$1" --argjson u "$2" --arg a "$3" --arg q "$4" --argjson nodes "$5" '{data:{repository:{pullRequest:{
      mergeStateStatus:"CLEAN", mergeable:$m,
      reviewThreads:{nodes:([range(0;$u)] | map({isResolved:false}))},
      mergeQueueEntry:(if $q == "" then null else {position:($q|tonumber), state:"AWAITING_CHECKS"} end),
      autoMergeRequest:(if $a == "yes" then {enabledAt:"x"} else null end),
      statusCheckRollup:{contexts:{nodes:$nodes}}}}}}' > "$STATE/graphql.json"
}
review() { printf '%s\n' "$1" > "$STATE/head_reviewed"; printf '%s\n' "${2:-1}" > "$STATE/reviews"; printf '%s\n' "${3:-0}" > "$STATE/verdicts"; }
printf '[]' > "$STATE/closed.json"
GREEN='[{"name":"ci / a","status":"COMPLETED","conclusion":"SUCCESS"}]'
RED='[{"name":"ci / a","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"backend / shard","status":"COMPLETED","conclusion":"FAILURE"}]'
PENDING='[{"name":"ci / a","status":"IN_PROGRESS","conclusion":null}]'
run() { (cd "$SANDBOX/repo" && MOCK_STATE="$STATE" PATH="$SANDBOX/bin:$PATH" AGENT_FABRIC_PR_REVIEW_STATUS="$SANDBOX/bin/pr-review-status.sh" AGENT_FABRIC_PR_SESSION="develop-qzapp/me" bash "$UNDER_TEST" "$@" 2>&1); }

ONE="$(jq -nc --arg h "$HEAD_SHA" '[{number:42,title:"the thing",headRefName:"develop-qzapp/me/feat/thing",headRefOid:$h,baseRefName:"main",state:"OPEN"},{number:43,title:"someone else",headRefName:"develop-qzapp/other/fix/x",headRefOid:$h,baseRefName:"main",state:"OPEN"}]')"

echo "commits are split into work, review fixes and merges"
prs "$ONE"; graphql MERGEABLE 0 no "" "$GREEN"; review yes
out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "^#42  develop-qzapp/me (me)  commits=12 (6 work, 5 fix, 1 merge)" <<<"$out" && pass "12 commits: 6 work (two own, one merged in, a domain 'driver review:', a fix(scope): bug fix, a 'review decision' feature), 5 fix (F1/F2 labels; 'address the blind review'; 'third-round review: four P3s'; two review-less subjects with an Answers: trailer, one of them folded), 1 merge" || fail "commit split wrong (rc=$rc)" "$out"
fixline="$(grep 'counted as fix:' <<<"$out")"
[[ "$fixline" == *'"fix: the review'"'"'s F1 and F2"'* && "$fixline" == *'"geocode: address the blind review of the entrypoint"'* && "$fixline" == *'"third-round review: four P3s'* && "$fixline" != *'fix(passenger)'* && "$fixline" != *'driver review'* ]] && pass "the subjects counted as fix are printed (and only those), so the split can be checked" || fail "fix subjects not printed" "$out"
! grep -q "^#43" <<<"$out" && pass "another session's PR is not listed by default" || fail "other session listed" "$out"

echo "the verdicts"
grep -q "MERGEABLE — ask the owner (6 work commits < 8), then arm" <<<"$out" && pass "green, reviewed head, 0 threads, under 8: ask the owner" || fail "under-8 verdict wrong" "$out"
review no 1
out="$(run)"; grep -q "BLOCKED: no review of the head (NOT on head)" <<<"$out" && pass "a review not on the head: BLOCKED, says NOT on head" || fail "stale review verdict wrong" "$out"
review no 0
out="$(run)"; grep -q "no review of the head (none)" <<<"$out" && pass "no review at all: says none" || fail "no-review verdict wrong" "$out"
review no 0 1
out="$(run)"; grep -q "no review of the head (NOT on head)" <<<"$out" && pass "a clean verdict comment on an earlier head counts as a review NOT on head, not none" || fail "verdict comment ignored" "$out"
review yes; graphql MERGEABLE 0 no "" "$RED"
out="$(run)"; grep -q "checks=red:backend / shard" <<<"$out" && grep -q "BLOCKED: red checks: backend / shard" <<<"$out" && pass "a failed check: named, BLOCKED" || fail "red check verdict wrong" "$out"
graphql MERGEABLE 0 no "" "$PENDING"
out="$(run)"; grep -q "checks=pending:1" <<<"$out" && grep -q "1 check(s) pending" <<<"$out" && pass "a running check: pending, BLOCKED" || fail "pending verdict wrong" "$out"
graphql MERGEABLE 2 no "" "$GREEN"
out="$(run)"; grep -q "threads=2" <<<"$out" && grep -q "2 unresolved thread(s)" <<<"$out" && pass "unresolved threads block" || fail "threads verdict wrong" "$out"
graphql CONFLICTING 0 no "" "$GREEN"
out="$(run)"; grep -q "BLOCKED: conflicts with main" <<<"$out" && pass "a conflict blocks" || fail "conflict verdict wrong" "$out"
graphql MERGEABLE 0 yes "" "$GREEN"
out="$(run)"; grep -q "armed=yes" <<<"$out" && grep -q "ARMED and clear" <<<"$out" && pass "armed and clear" || fail "armed verdict wrong" "$out"
graphql MERGEABLE 0 yes "" "$RED"
out="$(run)"; grep -q "ARMED but held: red checks" <<<"$out" && pass "armed but red: says what holds it" || fail "armed-held verdict wrong" "$out"
graphql MERGEABLE 0 no 3 "$GREEN"
out="$(run)"; grep -q "queue=3" <<<"$out" && grep -q "QUEUED (position 3)" <<<"$out" && pass "queued: position, nothing to do" || fail "queued verdict wrong" "$out"
graphql MERGEABLE 0 no "" "[]"
out="$(run)"; grep -q "checks=none-yet" <<<"$out" && grep -q "no check has reported yet" <<<"$out" && pass "no check reported at all (seconds after a push): not green" || fail "empty rollup read as green" "$out"
graphql MERGEABLE 0 no "" "$GREEN"; prs "$(jq -c '.[0].isDraft = true' <<<"$ONE")"
out="$(run)"; grep -q "BLOCKED: a draft" <<<"$out" && pass "a draft is never told to arm" || fail "draft verdict wrong" "$out"
prs "$ONE"; : > "$STATE/graphql_fail"
out="$(run)"; rc=$?
[[ $rc -eq 2 ]] && grep -q "could not read pull request #42 from GitHub" <<<"$out" && pass "a failed graphql read: exit 2, no invented BLOCKED row" || fail "graphql failure rendered as a verdict (rc=$rc)" "$out"
rm -f "$STATE/graphql_fail"

echo "the count rule's other bands"
graphql MERGEABLE 0 no "" "$GREEN"; review yes
for i in $(seq 7 9); do c "work $i"; done; git push -q origin develop-qzapp/me/feat/thing
prs "$(jq -c --arg h "$(git rev-parse HEAD)" 'map(.headRefOid=$h)' <<<"$ONE")"
out="$(run)"; grep -q "(9 work, " <<<"$out" && grep -q "MERGEABLE — arm: post the basis (9 work commits" <<<"$out" && pass "8-16 work commits at the gate: arm" || fail "arm band wrong" "$out"
for i in $(seq 10 17); do c "work $i"; done; git push -q origin develop-qzapp/me/feat/thing
prs "$(jq -c --arg h "$(git rev-parse HEAD)" 'map(.headRefOid=$h)' <<<"$ONE")"
out="$(run)"; grep -q "(17 work, " <<<"$out" && grep -q "17 work commits, over 16: smaller batches next time" <<<"$out" && pass "over 16: MERGEABLE, smaller batches next time, never blocked for it" || fail "over-16 verdict wrong" "$out"

echo "selection and shapes"
out="$(run --all)"; grep -q "^#43  develop-qzapp/other  commits=" <<<"$out" && grep -q "^#42  develop-qzapp/me (me)  commits=" <<<"$out" && pass "--all lists every open PR with its owner from the branch prefix, mine marked (me)" || fail "--all / owner wrong" "$out"
out="$(run --all --json)"; [[ "$(jq -r '.[] | select(.number==43) | .owner' <<<"$out")" == "develop-qzapp/other" ]] && [[ "$(jq -r '.[] | select(.number==43) | .mine' <<<"$out")" == "false" ]] && [[ "$(jq -r '.[] | select(.number==42) | .mine' <<<"$out")" == "true" ]] && pass "--json carries owner and mine" || fail "--json owner wrong" "$out"
out="$(run 43)"; grep -q "^#43" <<<"$out" && ! grep -q "^#42" <<<"$out" && pass "a number lists that PR whoever opened it" || fail "number selection wrong" "$out"
printf '[{"number":40,"title":"old","headRefName":"develop-qzapp/me/fix/old","headRefOid":"0000000000000000000000000000000000000000","baseRefName":"main","state":"MERGED"}]' > "$STATE/closed.json"
out="$(run 40 43)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "#40 is MERGED — not at any gate; skipped" <<<"$out" && ! grep -q "^#40" <<<"$out" && grep -q "^#43" <<<"$out" && pass "a merged PR given by number is said and skipped, never gated" || fail "non-open number gated (rc=$rc)" "$out"
out="$(run 42abc)"; rc=$?
[[ $rc -eq 2 ]] && pass "a non-numeric argument is a usage error, not a silently dropped PR" || fail "42abc accepted (rc=$rc)" "$out"
out="$(run 999)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "#999 is not a pull request" <<<"$out" && pass "a number that is no PR is said" || fail "unknown number silent (rc=$rc)" "$out"
out="$(run --json)"; [[ "$(jq -r 'length' <<<"$out")" == "1" ]] && [[ "$(jq -r '.[0].work_commits' <<<"$out")" == "17" ]] && [[ "$(jq -r '.[0].fix_subjects | length' <<<"$out")" == "5" ]] && [[ "$(jq -r '.[0].verdict' <<<"$out")" == MERGEABLE* ]] && pass "--json carries the row as data, fix_subjects included" || fail "--json wrong" "$out"
prs '[]'
out="$(run)"; grep -q "no open pull request from develop-qzapp/me" <<<"$out" && pass "none of mine: said" || fail "empty state wrong" "$out"
out="$(run --json)"; [[ "$(tr -d '[:space:]' <<<"$out")" == "[]" ]] && pass "…and --json prints an empty list" || fail "--json empty wrong" "$out"

echo "pr-gate: a head the clone does not have is 'unknown', never a zero (review F2 on #886)"
prs "$(jq -c 'map(.headRefOid="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")' <<<"$ONE")"
out="$(run --json)"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(jq -r '.[0] | "\(.commits_known) \(.work_commits) \(.fix_commits) \(.merge_commits)"' <<<"$out")" == "false null null null" ]] && pass "--json: commits_known false and the three counts null" || fail "unknown count not null in --json (rc=$rc)" "$out"
out="$(run)"; grep -q "commits=unknown (fetch)" <<<"$out" && pass "the row says unknown (fetch)" || fail "unknown count row wrong" "$out"
grep -q "commits unknown" <<<"$out" && pass "…and the verdict says to apply the rule by hand" || fail "unknown verdict missing" "$out"
prs "$ONE"
out="$(run --json)"; [[ "$(jq -r '.[0].commits_known' <<<"$out")" == "true" ]] && pass "a counted head: commits_known true" || fail "commits_known missing on a counted head" "$out"

echo "pr-gate: an AWAITING-SUPPLY line with no range line blocks (review F3 on #886)"
prs "$(jq -c '.[0].body = "waiting\n\nAWAITING-SUPPLY: develop-qzapp/db-admin\nAWAITING-SUPPLY: web-dev-01\n\naaaaaaa1..bbbbbbb2: web-dev-01 (web-dev)"' <<<"$ONE")"
out="$(run)"; grep -q "awaiting supply from db-admin (AWAITING-SUPPLY" <<<"$out" && pass "the unmet login blocks, by its last address segment" || fail "awaiting not a block" "$out"
grep -q "awaiting supply from.*web-dev-01" <<<"$out" && fail "the login with a range line was listed" "$out" || pass "the met login does not block"
out="$(run --json)"; [[ "$(jq -c '.[0].awaiting_supply' <<<"$out")" == '["db-admin"]' ]] && pass "--json carries awaiting_supply" || fail "--json awaiting_supply wrong" "$out"
prs "$ONE"

echo "pr-gate: a failed fetch makes every count unknown, not stale (re-review risk on #886)"
prs "$ONE"
orig_url="$(git -C "$SANDBOX/repo" remote get-url origin)"
git -C "$SANDBOX/repo" remote set-url origin "$SANDBOX/no-such-remote.git"
out="$(run --json)"; grep -q "git fetch origin failed" <<<"$out" && pass "the failure is said" || fail "fetch failure silent" "$out"
[[ "$(grep -v '^pr-gate:' <<<"$out" | jq -r '.[0].commits_known')" == "false" ]] && pass "commits_known false when origin cannot be fetched" || fail "a stale base was counted" "$out"
git -C "$SANDBOX/repo" remote set-url origin "$orig_url"
out="$(run --json)"; [[ "$(jq -r '.[0].commits_known' <<<"$out")" == "true" ]] && pass "…and counted again once the remote is back" || fail "count did not recover" "$out"

echo "pr-gate: a revert and the commit it reverts net to zero work (gzapp #912: '9 work — arm' where the count was 7)"
# On the same branch: a work commit, then git's own revert of it (the
# body carries "This reverts commit <sha>."), then a revert of a commit
# that is already on main (not in the range: it changes the tree, so it
# is work), then a "Revert …" subject with no trailer line (prose: work).
prs "$(jq -nc --arg h "$(git -C "$SANDBOX/repo" rev-parse HEAD)" '[{number:42,title:"the thing",headRefName:"develop-qzapp/me/feat/thing",headRefOid:$h,baseRefName:"main",state:"OPEN"}]')"
graphql MERGEABLE 0 no "" "$GREEN"; review yes
before_work="$(run --json | jq -r '.[0].work_commits')"; before_fix="$(run --json | jq -r '.[0].fix_commits')"
(
  cd "$SANDBOX/repo" || exit 1
  c "feat: the used-by guard"; guard="$(git rev-parse HEAD)"
  git revert --no-edit "$guard" >/dev/null
  base_sha="$(git rev-parse origin/main)"
  git revert --no-edit "$base_sha" >/dev/null 2>&1 || { git revert --abort 2>/dev/null; printf 'revert-main\n' >> f.txt; git add -A; git commit -q -m "Revert \"base\"" -m "This reverts commit $base_sha."; }
  c "Revert the thing by hand"
  git push -q origin develop-qzapp/me/feat/thing
)
HEAD2="$(git -C "$SANDBOX/repo" rev-parse HEAD)"
prs "$(jq -nc --arg h "$HEAD2" '[{number:42,title:"the thing",headRefName:"develop-qzapp/me/feat/thing",headRefOid:$h,baseRefName:"main",state:"OPEN"}]')"
graphql MERGEABLE 0 no "" "$GREEN"; review yes
out="$(run --json)"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(jq -r '.[0] | "\(.work_commits) \(.fix_commits) \(.netted_commits)"' <<<"$out")" == "$((before_work + 2)) $before_fix 2" ]] \
  && pass "four commits added: the in-range pair is netted (2); the revert of a main commit and the trailer-less 'Revert' are work (+2); fixes unchanged" \
  || fail "revert netting wrong (rc=$rc; before: $before_work work, $before_fix fix)" "$out"
out="$(run)"
grep -q "work, $before_fix fix, 1 merge, 2 netted by a revert)" <<<"$out" && pass "the row says so" || fail "row text" "$out"

echo
if [[ $failures -eq 0 ]]; then echo "test_pr-gate: OK — all assertions passed."; else echo "test_pr-gate: FAILED — $failures assertion(s)."; exit 1; fi
