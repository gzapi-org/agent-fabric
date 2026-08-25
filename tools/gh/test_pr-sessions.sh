#!/usr/bin/env bash
# tools/gh/test_pr-sessions.sh
#
# Behavioural tests for pr-sessions.sh.
#
# The script shipped across five PRs (#393, #394, #396, #397, #398)
# with no automated coverage, and review found four defects that a test
# would have caught on the way in — the author comparison that always
# rendered "!", the `/unresolved` filter that reported "none" after a
# FAILED lookup, an argument parser that spun forever on a missing
# operand, and bot branches attributed to a session named after the
# bot. Everything here is driven through the real script with a mocked
# `gh` on PATH, so the assertions are about observable output, not
# internals.
#
# The mock is faithful where it matters: `gh api graphql --jq FILTER`
# applies FILTER with real jq to a fixture GraphQL response, so the
# aggregation the script actually depends on is exercised rather than
# stubbed past.
#
# Run from anywhere:
#   bash tools/gh/test_pr-sessions.sh
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/pr-sessions.sh"

if [[ ! -f "$UNDER_TEST" ]]; then
    echo "test: script under test not found at $UNDER_TEST" >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    echo "test: jq is required to run these tests." >&2; exit 1; }

failures=0
SANDBOX=""

cleanup() { [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ── sandbox ─────────────────────────────────────────────────────────
#
# The script derives "this clone" from `hostname -s` + the git toplevel
# basename, so the sandbox is a real git repo with a known directory
# name and the fixtures are written against that same identity.
CLONE_NAME="gzapp-testclone"
HOST="$(hostname -s)"
ME="$HOST/$CLONE_NAME"
OTHER="$HOST/gzapp-otherclone"

setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/$CLONE_NAME" "$SANDBOX/bin" "$SANDBOX/fixtures"
    git -C "$SANDBOX/$CLONE_NAME" init -q 2>/dev/null

    cat > "$SANDBOX/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh. Behaviour is steered entirely by GH_MOCK_* environment
# variables so each case can pick its own failure mode.
set -uo pipefail

case "${1:-}" in
  pr)
    [[ -n "${GH_MOCK_PRLIST_FAIL:-}" ]] && exit 1
    cat "$GH_MOCK_DIR/pr-list.json"
    ;;
  repo)
    [[ -n "${GH_MOCK_REPOVIEW_FAIL:-}" ]] && exit 1
    printf '%s\n' "${GH_MOCK_REPO:-gzapi-org/gzapp}"
    ;;
  api)
    [[ -n "${GH_MOCK_GRAPHQL_FAIL:-}" ]] && exit 1
    # Apply the caller's --jq filter to the fixture, exactly as gh does.
    filter=""; query=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --jq) filter="$2"; shift 2 ;;
        -f) [[ "$2" == query=* ]] && query="${2#query=}"; shift 2 ;;
        *) shift ;;
      esac
    done
    # GRAPHQL RETURNS ONLY WHAT THE QUERY ASKED FOR, and the mock has to
    # honour that or it hides missing selections. A fixture that
    # volunteers pageInfo the query never requested lets the script pass
    # while asking the real API for a field it then reads as absent — the
    # test goes green on a query that would answer "not truncated" to
    # everything.
    src="$GH_MOCK_DIR/graphql.json"
    if [[ "$query" != *hasNextPage* ]]; then
      jq '(.data.repository // {}) |= with_entries(
            .value |= (if has("reviewThreads")
                       then .reviewThreads |= del(.pageInfo) else . end))' \
         "$GH_MOCK_DIR/graphql.json" > "$GH_MOCK_DIR/.served.json"
      src="$GH_MOCK_DIR/.served.json"
    fi
    if [[ -n "$filter" ]]; then
      jq -r "$filter" "$src"
    else
      cat "$src"
    fi
    ;;
  *)
    echo "mock gh: unhandled '${1:-}'" >&2; exit 1 ;;
esac
MOCK
    chmod +x "$SANDBOX/bin/gh"
}

# Runs the script inside the sandbox clone with the mock on PATH.
# Captures stdout+stderr; sets RUN_OUT and RUN_RC.
run() {
    RUN_OUT="$(cd "$SANDBOX/$CLONE_NAME" && \
        PATH="$SANDBOX/bin:$PATH" GH_MOCK_DIR="$SANDBOX/fixtures" \
        timeout 20 bash "$UNDER_TEST" "$@" 2>&1)"
    RUN_RC=$?
}

# Same, with extra environment (KEY=VALUE ...) before the script args,
# separated by `--`.
run_env() {
    local env=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do env+=("$1"); shift; done
    shift
    RUN_OUT="$(cd "$SANDBOX/$CLONE_NAME" && \
        PATH="$SANDBOX/bin:$PATH" GH_MOCK_DIR="$SANDBOX/fixtures" \
        env "${env[@]}" timeout 20 bash "$UNDER_TEST" "$@" 2>&1)"
    RUN_RC=$?
}

# ── assertions ──────────────────────────────────────────────────────

pass() { echo "  ✓ $1"; }
fail() {
    echo "  ✗ $1" >&2
    printf '%s\n' "${2:-}" | sed 's/^/      /' >&2
    failures=$((failures + 1))
}

assert_rc() {
    local label="$1" want="$2"
    if [[ "$RUN_RC" -eq "$want" ]]; then pass "$label"
    else fail "$label — expected exit $want, got $RUN_RC" "$RUN_OUT"; fi
}

assert_contains() {
    local label="$1" needle="$2"
    if [[ "$RUN_OUT" == *"$needle"* ]]; then pass "$label"
    else fail "$label — output did not contain '$needle'" "$RUN_OUT"; fi
}

assert_not_contains() {
    local label="$1" needle="$2"
    if [[ "$RUN_OUT" != *"$needle"* ]]; then pass "$label"
    else fail "$label — output unexpectedly contained '$needle'" "$RUN_OUT"; fi
}

# ── fixtures ────────────────────────────────────────────────────────

# Fixture timestamps are RELATIVE to now, never literal dates.
#
# `pr-sessions.sh` derives a /lastDate cutoff from the real wall clock,
# and nothing here mocks `date`. Pinned fixtures therefore age: the
# original 2026-08-06 rows sat inside `/lastDate:99d` when they were
# written and would have fallen outside it on 2026-11-13, failing a
# required check that also runs on merge_group — i.e. blocking every
# queued PR in the repo, on a date certain, with nothing in the diff to
# explain why. Relative fixtures cannot expire.
ago() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ; }

write_pr_list() { printf '%s\n' "$1" > "$SANDBOX/fixtures/pr-list.json"; }
write_graphql() { printf '%s\n' "$1" > "$SANDBOX/fixtures/graphql.json"; }

# Three PRs: two this clone's, one another session's.
default_pr_list() {
    write_pr_list "$(jq -n --arg me "$ME" --arg other "$OTHER" \
      --arg t30 "$(ago '1 hour')" --arg t29 "$(ago '2 hours')" \
      --arg t28 "$(ago '3 hours')" '[
      {number: 30, state: "OPEN",   headRefName: ($me    + "/feat/alpha"),
       title: "alpha", updatedAt: $t30, isDraft: false, mergedAt: null},
      {number: 29, state: "MERGED", headRefName: ($other + "/fix/beta"),
       title: "beta",  updatedAt: $t29, isDraft: false,
       mergedAt: $t29},
      {number: 28, state: "MERGED", headRefName: ($me    + "/docs/gamma"),
       title: "gamma", updatedAt: $t28, isDraft: false,
       mergedAt: $t28}
    ]')"
}

# #30 — one unresolved thread, reviewer spoke last  → "1!"
# #29 — one unresolved thread, PR AUTHOR spoke last → "1"  (no bang)
# #28 — threads exist but all resolved              → "-"
default_graphql() {
    write_graphql "$(jq -n '{
      data: {repository: {
        p30: {number: 30, author: {login: "andreabenetton"},
              reviewThreads: {nodes: [
                {isResolved: false, comments: {nodes: [{author: {login: "some-reviewer"}}]}}
              ]}},
        p29: {number: 29, author: {login: "andreabenetton"},
              reviewThreads: {nodes: [
                {isResolved: false, comments: {nodes: [{author: {login: "andreabenetton"}}]}}
              ]}},
        p28: {number: 28, author: {login: "andreabenetton"},
              reviewThreads: {nodes: [
                {isResolved: true, comments: {nodes: [{author: {login: "some-reviewer"}}]}}
              ]}}
      }}
    }')"
}

# ── cases ───────────────────────────────────────────────────────────

setup_sandbox

echo "pr-sessions: default scope"
default_pr_list; default_graphql
run
assert_rc        "exits 0" 0
assert_contains  "shows this clone's PR"          "#30"
assert_contains  "shows this clone's other PR"    "#28"
assert_not_contains "hides another session's PR"  "#29"
assert_contains  "says it defaulted to this clone" "Scoped to this clone"

echo "pr-sessions: /all"
run /all
assert_rc       "exits 0" 0
assert_contains "includes the other session's PR" "#29"
assert_contains "still includes this clone's"     "#30"

echo "pr-sessions: explicit session filter"
run --session gzapp-otherclone
assert_rc           "exits 0" 0
assert_contains     "matches the named session"     "#29"
assert_not_contains "excludes the other session"    "#30"

echo "pr-sessions: state filter is chosen at fetch time"
run /OPEN
assert_rc       "exits 0" 0

echo "pr-sessions: conflicting state flags are refused"
run /OPEN /MERGED
assert_rc       "exits 2" 2
assert_contains "names the conflict" "conflict"

echo "pr-sessions: grouped output"
run /all --by-session
assert_rc       "exits 0" 0
assert_contains "groups under this clone" "$ME"
assert_contains "marks this clone"        "this clone"

echo "pr-sessions: empty result is a clean exit, not an error"
write_pr_list '[]'
run
assert_rc       "exits 0" 0
assert_contains "says nothing matched" "no PRs"
default_pr_list

echo "pr-sessions: THR column reflects the thread lookup"
run /all
assert_rc       "exits 0" 0
# "1!" — a reviewer spoke last on #30, so a reply is owed.
assert_contains "flags a thread awaiting a reply" "1!"
# #29's unresolved thread was last answered by the PR AUTHOR, so the
# count stands alone: answered, merely not resolved. This is the case
# the broken comparison could not express — `.author` was read off the
# thread node, which has no such field, so every unresolved thread
# compared against null and every row wore a bang.
row_29="$(printf '%s\n' "$RUN_OUT" | grep -- '#29')"
if [[ "$row_29" == *"1!"* ]]; then
    fail "no bang when the author answered last" "$row_29"
else
    pass "no bang when the author answered last"
fi
# #28's threads are all resolved → "-"; if the resolved filter broke,
# this would read "1".
assert_contains "shows resolved-only PRs as a dash" "-"

echo "pr-sessions: --no-threads skips the lookup"
run /all --no-threads
assert_rc           "exits 0" 0
assert_not_contains "no bang without the lookup" "1!"

echo "pr-sessions: /unresolved needs the lookup"
run /unresolved --no-threads
assert_rc       "exits 2" 2
assert_contains "explains the conflict" "drop --no-threads"

echo "pr-sessions: /unresolved keeps only PRs with open threads"
run /all /unresolved
assert_rc           "exits 0" 0
assert_contains     "keeps #30"            "#30"
assert_contains     "keeps #29"            "#29"
assert_not_contains "drops the resolved-only PR" "#28"

echo "pr-sessions: a truncated thread page reads UNKNOWN, not zero"
# Only the first 100 threads arrive. A pr whose early threads are all
# resolved and whose open one sits on page two therefore looks clean —
# "-" in the column, dropped from /unresolved — which hides precisely the
# outstanding work this command exists to surface. #28's visible thread
# is resolved, so without the hasNextPage read it renders "-".
# #30 and #29 keep their ordinary counts so the "?" below can only have
# come from the truncated pr — otherwise a pr simply MISSING from the
# response would satisfy the same assertion.
write_graphql "$(jq -n '{
  data: {repository: {
    p30: {number: 30, author: {login: "andreabenetton"},
          reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [
            {isResolved: false, comments: {nodes: [{author: {login: "some-reviewer"}}]}}
          ]}},
    p29: {number: 29, author: {login: "andreabenetton"},
          reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [
            {isResolved: false, comments: {nodes: [{author: {login: "andreabenetton"}}]}}
          ]}},
    p28: {number: 28, author: {login: "andreabenetton"},
          reviewThreads: {pageInfo: {hasNextPage: true}, nodes: [
            {isResolved: true, comments: {nodes: [{author: {login: "some-reviewer"}}]}}
          ]}}
  }}
}')"
run /all
assert_rc           "exits 0" 0
assert_contains     "renders the truncated count as unknown" "?"
assert_not_contains "does not claim zero open threads" " -  "

run /all /unresolved
assert_rc       "exits 0" 0
assert_contains "keeps the pr rather than dropping it" "#28"

default_graphql

echo "pr-sessions: pool filters"
run /all /lastItem:1
assert_rc           "exits 0" 0
assert_contains     "keeps the newest PR"     "#30"
assert_not_contains "drops everything older"  "#29"

run /all /lastDate:99d
assert_rc       "/lastDate accepts <N>d" 0
assert_contains "keeps PRs in the window" "#30"

# A TIGHT window, which is what keeps the fixtures honest.
#
# /lastDate:99d passes for ~99 days after any pinned fixture is written,
# so it cannot tell a relative fixture from one that is quietly ageing
# out — the original rows sat inside it for three months before they
# would have started failing a required check on merge_group. A one-day
# window is outside a pinned fixture's reach almost immediately, so this
# fails within a day of anyone reintroducing a literal date.
run /all /lastDate:1d
assert_rc       "/lastDate:1d exits 0" 0
assert_contains "fixtures are recent enough for a tight window" "#30"

echo "pr-sessions: /unresolved honours an explicit /lastItem"
# The candidate cap of 100 was applied as the FINAL slice, after
# /lastItem had already narrowed the pool — so `/lastItem:150 /unresolved`
# queried the newest 100 and never asked about rows 101-150. The caller
# named a number and silently got a different one.
#
# 150 rows; every one has a RESOLVED thread except the oldest, #151. If
# the cap still won, #151 is never queried and never reported.
write_pr_list "$(jq -n --arg me "$ME" --arg t "$(ago '1 hour')" '[range(150) | {
  number: (300 - .), state: "MERGED", headRefName: ($me + "/feat/p" + (. | tostring)),
  title: "p", updatedAt: $t, isDraft: false, mergedAt: $t}]')"
write_graphql "$(jq -n '{data: {repository: (
  [range(150) | {key: ("p" + ((300 - .) | tostring)),
                 value: {number: (300 - .), author: {login: "andreabenetton"},
                         reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [
                           {isResolved: ((300 - .) != 151),
                            comments: {nodes: [{author: {login: "some-reviewer"}}]}}
                         ]}}}] | from_entries)}}')"
run /all -n 200 /lastItem:150 /unresolved
assert_rc           "exits 0" 0
assert_contains     "queries past the 100-row cap" "#151"
assert_not_contains "and still drops the resolved ones" "#300"

default_pr_list; default_graphql

echo "pr-sessions: malformed pool filters are refused"
run /lastItem:0
assert_rc       "/lastItem:0 exits 2" 2
assert_contains "names the expectation" "positive integer"

run /lastItem:
assert_rc       "empty /lastItem exits 2" 2

run /lastDate:5
assert_rc       "unit-less /lastDate exits 2" 2
assert_contains "names the accepted units" "<N>d"

run /lastDate:
assert_rc       "empty /lastDate exits 2" 2

echo "pr-sessions: unknown options are refused"
run --nope
assert_rc       "exits 2" 2
assert_contains "points at --help" "--help"

echo "pr-sessions: --help lists every documented flag"
run --help
assert_rc       "exits 0" 0
assert_contains "documents /all"        "/all"
assert_contains "documents --by-session" "--by-session"
# These live below the old hard-coded line-36 cut-off. Their absence was
# the discoverability regression review flagged on #394 and #398.
assert_contains "documents /lastItem"   "/lastItem"
assert_contains "documents /lastDate"   "/lastDate"
assert_contains "documents /unresolved" "/unresolved"

echo "pr-sessions: a missing operand is refused, not looped on"
# `-n` last: `shift 2` cannot consume two arguments, and with `set -e`
# off the parser used to spin forever. `timeout` in run() turns a
# regression here into exit 124 rather than a hung suite.
run -n
assert_rc       "bare -n exits 2" 2
assert_contains "names the flag" "-n"

run --session
assert_rc       "bare --session exits 2" 2

echo "pr-sessions: a non-numeric limit is refused before arithmetic"
# `$(( LIMIT * 20 ))` re-evaluates the variable's CONTENT as an
# arithmetic expression, and bash evaluates command substitution inside
# an array subscript — so an unvalidated limit is code execution, not
# just a bad number.
run -n 'x[$(touch "'"$SANDBOX"'/pwned")]'
assert_rc "injected limit exits 2" 2
if [[ -e "$SANDBOX/pwned" ]]; then
    fail "arithmetic injection executed the payload" "$RUN_OUT"
    rm -f "$SANDBOX/pwned"
else
    pass "arithmetic injection did not execute"
fi

run -n abc
assert_rc       "non-numeric limit exits 2" 2
assert_contains "names the expectation" "positive integer"

echo "pr-sessions: bot branches are not attributed to a session"
write_pr_list "$(jq -n --arg me "$ME" \
  --arg t1 "$(ago '1 hour')" --arg t2 "$(ago '2 hours')" \
  --arg t3 "$(ago '3 hours')" '[
  {number: 40, state: "OPEN", headRefName: "dependabot/github_actions/actions-minor-patch-5c7bcdc794",
   title: "bump", updatedAt: $t1, isDraft: false, mergedAt: null},
  {number: 41, state: "OPEN", headRefName: "dependabot/nuget/apps/backend_dotnet/dotnet-minor-patch-04e2",
   title: "bump", updatedAt: $t2, isDraft: false, mergedAt: null},
  {number: 42, state: "OPEN", headRefName: ($me + "/feat/real"),
   title: "real", updatedAt: $t3, isDraft: false, mergedAt: null}
]')"
write_graphql "$(jq -n '{data: {repository: {
  p40: {number: 40, author: {login: "app/dependabot"}, reviewThreads: {nodes: []}},
  p41: {number: 41, author: {login: "app/dependabot"}, reviewThreads: {nodes: []}},
  p42: {number: 42, author: {login: "andreabenetton"}, reviewThreads: {nodes: []}}
}}}')"
run /all
assert_rc       "exits 0" 0
# The branch name itself still shows in the WORK column, so the claim
# has to be about the SESSION column of each bot row specifically.
for n in 40 41; do
    row="$(printf '%s\n' "$RUN_OUT" | grep -- "#$n")"
    if [[ "$row" == *"(unconventional)"* ]]; then
        pass "#$n is not attributed to a session"
    else
        fail "#$n was attributed to a session" "$row"
    fi
done
assert_contains "a real session branch still resolves" "$ME"
default_pr_list; default_graphql

echo "pr-sessions: a session branch is attributed by SHAPE, not a type vocabulary"
# The predicate used to require one of thirteen conventional-commit
# words in the <type> segment, so `spike-3/`, `hotfix/` and `stage-4/`
# branches were classified unconventional and then SILENTLY DROPPED by
# the default clone scope — the command whose job is surfacing
# outstanding work answering "none". CLAUDE.md puts no vocabulary on
# <type>; only the shape is specified, so only the shape is checked.
write_pr_list "$(jq -n --arg me "$ME" \
  --arg t1 "$(ago '1 hour')" --arg t2 "$(ago '2 hours')" \
  --arg t3 "$(ago '3 hours')" '[
  {number: 50, state: "OPEN", headRefName: ($me + "/spike-3/beacon-parse"),
   title: "spike", updatedAt: $t1, isDraft: false, mergedAt: null},
  {number: 51, state: "OPEN", headRefName: ($me + "/hotfix/regime-strip"),
   title: "hotfix", updatedAt: $t2, isDraft: false, mergedAt: null},
  {number: 52, state: "OPEN", headRefName: ($me + "/feat/known-type"),
   title: "feat", updatedAt: $t3, isDraft: false, mergedAt: null}
]')"
write_graphql "$(jq -n '{data: {repository: {
  p50: {number: 50, author: {login: "andreabenetton"}, reviewThreads: {nodes: []}},
  p51: {number: 51, author: {login: "andreabenetton"}, reviewThreads: {nodes: []}},
  p52: {number: 52, author: {login: "andreabenetton"}, reviewThreads: {nodes: []}}
}}}')"
# DEFAULT scope, not /all: the drop this guards against happens in the
# scope filter, so a run that scopes to nothing proves nothing.
run
assert_rc       "exits 0" 0
assert_contains "an unlisted <type> is still this clone's work" "#50"
assert_contains "  and so is another one"                       "#51"
assert_contains "a conventional type is unaffected"             "#52"
assert_not_contains "none of them read as unattributed" "(unconventional)"

echo "pr-sessions: a branch with too few segments is still unattributed"
# Shape-matching is not "anything goes" — <host>/<clone>/<type>/<desc>
# needs four segments before $p[0]/$p[1] means a session at all.
write_pr_list "$(jq -n --arg me "$ME" --arg t1 "$(ago '1 hour')" '[
  {number: 53, state: "OPEN", headRefName: "agent/global-event-identity",
   title: "agent", updatedAt: $t1, isDraft: false, mergedAt: null}
]')"
write_graphql "$(jq -n '{data: {repository: {
  p53: {number: 53, author: {login: "andreabenetton"}, reviewThreads: {nodes: []}}
}}}')"
run /all
assert_rc       "exits 0" 0
row="$(printf '%s\n' "$RUN_OUT" | grep -- '#53')"
if [[ "$row" == *"(unconventional)"* ]]; then
    pass "#53 is not attributed to a session"
else
    fail "#53 was attributed to a session" "$row"
fi
default_pr_list; default_graphql

echo "pr-sessions: an invalid --session regex is an invocation error"
# `test()` with a bad pattern kills jq. Swallowing that printed "no
# matching PRs" and exited 0 — the same reassuring answer a genuinely
# empty result gives.
run --session '['
assert_rc       "exits 2" 2
assert_contains "says the filter was rejected" "session"
assert_not_contains "does not claim an empty result" "no PRs for a session"

echo "pr-sessions: a failed thread lookup reads as unknown, never zero"
run_env GH_MOCK_GRAPHQL_FAIL=1 -- /all
assert_rc       "listing still succeeds" 0
assert_contains "THR shows unknown" "?"

run_env GH_MOCK_GRAPHQL_FAIL=1 -- /all /unresolved
assert_rc           "/unresolved refuses to guess" 2
assert_contains     "says the lookup failed"       "could not"
assert_not_contains "never claims there are none"  "no PRs with unresolved review threads"

run_env GH_MOCK_REPOVIEW_FAIL=1 -- /all /unresolved
assert_rc       "/unresolved refuses to guess without a repo" 2

echo "pr-sessions: a failed pr list is an invocation error"
run_env GH_MOCK_PRLIST_FAIL=1 -- /all
assert_rc       "exits 2" 2
assert_contains "names the likely cause" "could not list PRs"

echo "pr-sessions: /lastItem beyond the derived cap is honoured, not clamped"
# The mock records the --limit it was handed, so the claim is about the
# fetch that actually went out rather than the rendered page.
cat > "$SANDBOX/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  pr)
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--limit" ]] && printf '%s\n' "$2" > "$GH_MOCK_DIR/last-limit"
      shift
    done
    cat "$GH_MOCK_DIR/pr-list.json" ;;
  repo) printf '%s\n' "gzapi-org/gzapp" ;;
  api)  printf '%s\n' '{}' ;;
  *)    exit 1 ;;
esac
MOCK
chmod +x "$SANDBOX/bin/gh"
run /all /lastItem:600 --no-threads
assert_rc "exits 0" 0
requested="$(cat "$SANDBOX/fixtures/last-limit" 2>/dev/null || echo missing)"
if [[ "$requested" == "600" ]]; then
    pass "fetches the full 600-PR pool"
else
    fail "silently clamped the pool" "gh pr list --limit was '$requested', wanted 600"
fi

echo "pr-sessions: a full /lastDate page warns that the window may be short"
# The warning fires when the fetch came back full, so the fixture has to
# fill the derived 200-row page.
write_pr_list "$(jq -n --arg me "$ME" --arg t "$(ago '1 hour')" '[range(200) | {
  number: (500 - .), state: "OPEN", headRefName: ($me + "/feat/w\(.)"),
  title: "w", updatedAt: $t, isDraft: false, mergedAt: null}]')"
# -n 10 puts the derived fetch at its 200 floor, which the fixture fills
# exactly.
run /all -n 10 /lastDate:99d --no-threads
assert_rc       "exits 0" 0
assert_contains "warns that the window may be truncated" "may be"
default_pr_list

echo
if [[ "$failures" -eq 0 ]]; then
    echo "test_pr-sessions: OK — all assertions passed."
    exit 0
fi
echo "test_pr-sessions: FAILED — $failures assertion(s) failed." >&2
exit 1
