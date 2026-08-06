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
#
# Exit codes:
#   0  listed (even if the result is empty)
#   2  invocation problem (no gh/jq, not authenticated, bad flag)

set -uo pipefail

LIMIT=20
STATE=all
FILTER=""
GROUPED=0
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
        -h|--help)    sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "pr-sessions: unknown option '$1' (try --help)" >&2; exit 2 ;;
    esac
done

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
if [[ -n "$FILTER" ]]; then
    FETCH=$(( LIMIT * 20 )); (( FETCH < 200 )) && FETCH=200
    (( FETCH > 500 )) && FETCH=500
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
out="$(printf '%s' "$rows" | jq -r --arg me "$ME" --arg filter "$FILTER" \
        --argjson grouped "$GROUPED" --argjson limit "$LIMIT" '
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
  | if $grouped == 1 then
      ( group_by(._s) | sort_by(-(map(.number) | max))
        | map(
            "\n\(.[0]._s)\(if .[0]._s == $me then "   <- this clone" else "" end)"
            , ( sort_by(-.number)[]
                | "  #\(.number)  \(st | pad(6))  \(.updatedAt[0:10])  \(._w)" )
          ) | flatten | .[] )
    else
      ( sort_by(-.number)[]
        | "\(._s | mark) #\(.number | tostring | pad(4))  \(st | pad(6))  \(.updatedAt[0:10])  \(._s | pad(30))  \(._w)" )
    end
')"

if [[ -z "${out//[$' \t\n']/}" ]]; then
    what="PRs"
    [[ "$FILTER" == "__MINE__" ]] && what="PRs for this clone ($ME)"
    [[ -n "$FILTER" && "$FILTER" != "__MINE__" ]] && what="PRs for a session matching '$FILTER'"
    echo "pr-sessions: no $what in the last $FETCH ${STATE} PR(s)."
    [[ "$DEFAULTED_TO_MINE" -eq 1 ]] && \
        echo "  (scoped to this clone by default — pass /all to see every session)"
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
