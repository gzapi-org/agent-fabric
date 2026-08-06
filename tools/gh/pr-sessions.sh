#!/usr/bin/env bash
# tools/gh/pr-sessions.sh
#
# Which SESSION owns which PR, newest first.
#
# Every PR in this repo carries the same GitHub author, because every
# session pushes with the same credentials. `gh pr list` therefore shows
# one name against all of them and answers nothing about who is doing
# what. The session identity lives in the BRANCH NAME instead — the
# repo-root CLAUDE.md mandates
#
#     <hostname -s>/<clone-dir-basename>/<type>/<short-desc>
#
# so the first two segments are the session, and everything after is the
# work. This script reads that, and marks the rows belonging to THIS
# clone so "mine vs theirs" is visible at a glance — which is what the
# stay-in-your-own-lane rules turn on: never push to, rebase, delete or
# answer reviews on another session's branch.
#
# DEFAULT SCOPE: run inside a clone, and it shows THAT clone's PRs.
# Asking "which PRs are mine" from inside a working tree is the common
# case, and the clone you are standing in already answers it — so that
# is the default rather than something to remember a flag for. Pass
# /all to see every session.
#
# (There is no unscoped-outside-a-repo case to describe: `gh pr list`
# needs a repo context and fails first, so the script never gets that
# far. The empty-ME branch below is belt-and-braces for a future
# --repo flag, not a path you can reach today.)
#
# Usage:
#   tools/gh/pr-sessions.sh                 # THIS clone's PRs (default)
#   tools/gh/pr-sessions.sh /all            # every session
#   tools/gh/pr-sessions.sh -n 50           # last 50 rows
#   tools/gh/pr-sessions.sh --open          # open PRs only
#   tools/gh/pr-sessions.sh --session gzapp-claude3
#   tools/gh/pr-sessions.sh /all --by-session   # grouped, all sessions
#   tools/gh/pr-sessions.sh /unresolved     # only PRs with an open thread
#   tools/gh/pr-sessions.sh /all /unresolved # ...across every session
#   tools/gh/pr-sessions.sh --no-threads    # skip the review-thread lookup
#
# The THR column counts UNRESOLVED review threads — the ones that
# actually gate a merge under required_review_thread_resolution. A
# trailing "!" means the last word in at least one of them is NOT the
# PR author's, i.e. somebody is waiting on a reply. "2" without the
# bang means you answered and simply have not resolved the threads.
#
# Exit codes:
#   0  listed (even if the result is empty)
#   2  invocation problem (no gh/jq, not authenticated, bad flag)

set -uo pipefail

LIMIT=20
STATE=all
FILTER=""
GROUPED=0
THREADS=1
UNRESOLVED_ONLY=0
SCOPE_EXPLICIT=0    # did the caller choose a scope, overriding the default?

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--limit)   LIMIT="${2:-}"; shift 2 ;;
        --open)       STATE=open; shift ;;
        --merged)     STATE=merged; shift ;;
        /all|--all)   FILTER=""; SCOPE_EXPLICIT=1; shift ;;
        --mine)       FILTER="__MINE__"; SCOPE_EXPLICIT=1; shift ;;
        --session)    FILTER="${2:-}"; SCOPE_EXPLICIT=1; shift 2 ;;
        --by-session) GROUPED=1; shift ;;
        --no-threads) THREADS=0; shift ;;
        /unresolved|--unresolved) UNRESOLVED_ONLY=1; shift ;;
        -h|--help)    sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "pr-sessions: unknown option '$1' (try --help)" >&2; exit 2 ;;
    esac
done

if [[ "$UNRESOLVED_ONLY" -eq 1 && "$THREADS" -eq 0 ]]; then
    echo "pr-sessions: /unresolved needs the thread lookup — drop --no-threads." >&2
    exit 2
fi

for bin in gh jq; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "pr-sessions: $bin is required but not installed." >&2; exit 2; }
done

# This clone's session, derived the same way the branch prefix is built.
ME=""
if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    ME="$(hostname -s)/$(basename "$root")"
fi

# Inside a clone with no explicit scope: show that clone's PRs. If ME
# cannot be resolved there is nothing to infer, so fall through to
# everything — unreachable today (gh needs a repo and fails earlier),
# kept so the default cannot silently become "someone else's session"
# if a --repo flag is ever added.
DEFAULTED_TO_MINE=0
if [[ "$SCOPE_EXPLICIT" -eq 0 && -n "$ME" ]]; then
    FILTER="__MINE__"
    DEFAULTED_TO_MINE=1
fi
[[ -z "$ME" ]] && ME="unknown/unknown"

# -n bounds the ROWS SHOWN, not how far back we look. With a filter the
# two differ sharply: `--mine -n 8` fetching only the newest 8 PRs
# returned NOTHING here, because all 8 belonged to parallel sessions —
# an empty list that reads as "you have no PRs" rather than "your PRs
# are older than the window". So widen the fetch and trim after
# filtering.
FETCH="$LIMIT"
if [[ -n "$FILTER" || "$UNRESOLVED_ONLY" -eq 1 ]]; then
    FETCH=$(( LIMIT * 20 )); (( FETCH < 200 )) && FETCH=200
    (( FETCH > 500 )) && FETCH=500
fi

# /unresolved filters on data that only exists AFTER the thread lookup,
# so the candidate set has to be wider than the page — otherwise a PR
# with an open thread just past row -n would be invisible, which is the
# same window trap `--mine -n 8` fell into. Capped so the aliased
# GraphQL query stays one sane request.
CANDIDATES="$LIMIT"
if [[ "$UNRESOLVED_ONLY" -eq 1 ]]; then
    CANDIDATES=100
    (( CANDIDATES > FETCH )) && CANDIDATES="$FETCH"
fi

rows="$(gh pr list --state "$STATE" --limit "$FETCH" \
        --json number,state,headRefName,title,updatedAt,isDraft,mergedAt 2>/dev/null)" || {
    echo "pr-sessions: could not list PRs (gh not authenticated, or not in a repo)." >&2
    exit 2
}

# Session = first two path segments of the branch. A branch that does
# not follow the convention (dependabot, a hand-made name) is reported
# as "(unconventional)" rather than silently mis-attributed — a wrong
# owner is worse than a visible unknown.
selected="$(printf '%s' "$rows" | jq --arg me "$ME" --arg filter "$FILTER" \
        --argjson limit "$CANDIDATES" '
  def session:
    (.headRefName | split("/")) as $p
    | if ($p | length) >= 3 then ($p[0] + "/" + $p[1]) else "(unconventional)" end;
  def work:
    (.headRefName | split("/")) as $p
    | if ($p | length) >= 3 then ($p[2:] | join("/")) else .headRefName end;
  def mark: if (. == $me) then "*" else " " end;
  def pad($n): . + (" " * ($n - length));
  def st:
    if .isDraft then "DRAFT"
    elif .state == "OPEN" then "OPEN"
    elif .state == "MERGED" then "MERGED"
    else "CLOSED" end;

  [ .[] | . + {_s: session, _w: work} ]
  | ( if $filter == "__MINE__" then map(select(._s == $me))
      elif $filter != "" then map(select(._s | test($filter; "i")))
      else . end )
  | sort_by(-.number) | .[:$limit]
')"

if [[ "$(printf '%s' "$selected" | jq 'length')" -eq 0 ]]; then
    what="PRs"
    [[ "$FILTER" == "__MINE__" ]] && what="PRs for this clone ($ME)"
    [[ -n "$FILTER" && "$FILTER" != "__MINE__" ]] && what="PRs for a session matching '$FILTER'"
    echo "pr-sessions: no $what in the last $FETCH ${STATE} PR(s)."
    [[ "$DEFAULTED_TO_MINE" -eq 1 ]] && \
        echo "  (scoped to this clone by default — pass /all to see every session)"
    exit 0
fi

# ── unresolved review threads, one batched call ─────────────────────
#
# Only for the rows about to be PRINTED, and in a single aliased
# GraphQL query rather than one request per PR: ~0.7s for the whole
# page instead of N round trips.
#
# "Unresolved" is the right count because required_review_thread_
# resolution is what actually gates the merge. The "!" refinement asks
# a second question the raw count cannot: is the last comment in the
# thread the PR author's? If it is not, somebody is waiting on YOU.
THREAD_JSON='{}'
if [[ "$THREADS" -eq 1 ]]; then
    nums="$(printf '%s' "$selected" | jq -r '.[].number')"
    if [[ -n "$nums" ]]; then
        owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
        if [[ -n "$owner_repo" ]]; then
            q="{ repository(owner: \"${owner_repo%%/*}\", name: \"${owner_repo##*/}\") {"
            while read -r n; do
                [[ -z "$n" ]] && continue
                q+=" p${n}: pullRequest(number: ${n}) { number author { login }"
                q+=" reviewThreads(first: 100) { nodes { isResolved"
                q+=" comments(last: 1) { nodes { author { login } } } } } }"
            done <<< "$nums"
            q+=" } }"
            THREAD_JSON="$(gh api graphql -f query="$q" --jq '
                [ .data.repository | to_entries[] | .value
                  | { key: (.number | tostring),
                      value: {
                        unresolved: ([.reviewThreads.nodes[] | select(.isResolved == false)] | length),
                        awaiting:   ([.reviewThreads.nodes[]
                                      | select(.isResolved == false)
                                      | select((.comments.nodes[0].author.login // "") != .author.login)] | length)
                      } } ] | from_entries' 2>/dev/null)" || THREAD_JSON=""
            # A failed lookup must read as UNKNOWN, never as zero: "0
            # unresolved" is exactly the reassuring answer you would act
            # on, and it would be a guess.
            [[ -z "$THREAD_JSON" ]] && THREAD_JSON="null"
        fi
    fi
fi

out="$(printf '%s' "$selected" | jq -r --arg me "$ME" --argjson grouped "$GROUPED" \
        --argjson th "$THREAD_JSON" --argjson want "$THREADS" \
        --argjson unres "$UNRESOLVED_ONLY" --argjson limit "$LIMIT" '
  def mark: if (. == $me) then "*" else " " end;
  def pad($n): . + (" " * ($n - length));
  def lpad($n): (" " * ($n - length)) + .;
  def st:
    if .isDraft then "DRAFT"
    elif .state == "OPEN" then "OPEN"
    elif .state == "MERGED" then "MERGED"
    else "CLOSED" end;
  def threads:
    if $want == 0 then ""
    elif $th == null then "?"
    else ($th[(.number | tostring)] // null) as $t
      | if $t == null then "?"
        elif $t.unresolved == 0 then "-"
        else "\($t.unresolved)\(if $t.awaiting > 0 then "!" else "" end)"
        end
    end;

  ( if $unres == 1
      then map(select((($th // {})[(.number | tostring)].unresolved // 0) > 0))
      else . end )
  | sort_by(-.number) | .[:$limit]
  | if $grouped == 1 then
    ( group_by(._s) | sort_by(-(map(.number) | max))
      | map(
          "\n\(.[0]._s)\(if .[0]._s == $me then "   <- this clone" else "" end)"
          , ( sort_by(-.number)[]
              | "  #\(.number)  \(st | pad(6))  \(threads | lpad(3))  \(.updatedAt[0:10])  \(._w)" )
        ) | flatten | .[] )
  else
    ( sort_by(-.number)[]
      | "\(._s | mark) #\(.number | tostring | pad(4))  \(st | pad(6))  \(threads | lpad(3))  \(.updatedAt[0:10])  \(._s | pad(30))  \(._w)" )
  end
')"

if [[ "$GROUPED" -eq 0 ]]; then
    printf '  %-5s  %-6s  %3s  %-10s  %-30s  %s\n' \
        PR STATE THR UPDATED SESSION WORK
fi
if [[ -z "${out//[$' \t\n']/}" ]]; then
    scope="this clone ($ME)"
    [[ "$FILTER" == "" ]] && scope="any session"
    [[ -n "$FILTER" && "$FILTER" != "__MINE__" ]] && scope="sessions matching '$FILTER'"
    echo "pr-sessions: no PRs with unresolved review threads for $scope"
    echo "  (checked the newest $CANDIDATES of the last $FETCH ${STATE} PRs)"
    exit 0
fi

printf '%s\n' "$out"

echo
if [[ "$DEFAULTED_TO_MINE" -eq 1 ]]; then
    echo "  Scoped to this clone ($ME) — pass /all for every session."
elif [[ "$GROUPED" -eq 0 ]]; then
    echo "  * = this clone ($ME).  Others belong to parallel sessions:"
    echo "  do not push to, rebase, delete, or answer reviews on their branches."
fi
