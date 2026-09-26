# shellcheck shell=bash
# runtime/github/pr-gate-inflight.sh — sourced by pr-gate.sh for
# --in-flight and --overlap (its help says what they answer). Not
# executable on its own: it reads pr-gate.sh's REPO, JSON, OVERLAP and
# PATHS.
#
# Every branch on origin is read from git, so a pushed branch with no PR
# is a row like any other; GitHub only adds which branches have one. The
# owner is the branch's <host>/<login> prefix, because every agent pushes
# as one GitHub user and the author says nothing about who did the work.
# Nothing here writes but the fetch, which pr-gate already does.

INFLIGHT_PATHS_CAP=200   # a row's paths as data; the total is always given

in_flight() {
    local base fetch_ok=true prs_ok=true
    if ! git fetch -q --prune origin 2>/dev/null; then
        fetch_ok=false
        local seen; seen="$(date -u -r "$(git rev-parse --git-path FETCH_HEAD)" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo never)"
        echo "pr-gate: git fetch origin failed — the rows below are what origin showed this clone at its last fetch ($seen)" >&2
    fi
    base="${AGENT_FABRIC_PR_BASE:-}"
    if [[ -z "$base" ]]; then
        base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
        [[ -n "$base" ]] || base="origin/main"
    fi
    git rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "pr-gate: the base $base is not in this clone" >&2; return 2; }

    local prmap
    prmap="$(gh pr list --repo "$REPO" --state open --limit 500 --json number,headRefName 2>/dev/null)" \
        || { prs_ok=false; prmap="[]"; echo "pr-gate: could not list pull requests — the PR column reads unavailable, never \"no PR\"" >&2; }
    [[ "$(jq 'length' <<<"$prmap")" -ge 500 ]] && echo "pr-gate: 500 open pull requests read — the list is capped there." >&2

    local rows="" ref sha when epoch name owner pr ahead paths
    # The full ref name: a short one is ambiguous beside a local branch
    # called origin/<x>, and origin/HEAD shortens to a bare "origin".
    while IFS=$'\t' read -r ref sha when epoch; do
        [[ -n "$ref" ]] || continue
        name="${ref#refs/remotes/origin/}"
        [[ "$name" == "HEAD" || "origin/$name" == "$base" ]] && continue
        git merge-base --is-ancestor "$sha" "$base" 2>/dev/null && continue   # merged: not in flight
        if [[ "$name" =~ ^([^/]+/[^/]+)/.+ ]]; then owner="${BASH_REMATCH[1]}"; else owner="unattributed"; fi
        if [[ "$prs_ok" == true ]]; then
            pr="$(jq -r --arg b "$name" '[.[] | select(.headRefName == $b) | .number][0] // "none"' <<<"$prmap")"
        else pr="unavailable"; fi
        ahead="$(git rev-list --count "$base..$sha" 2>/dev/null)" || ahead=null
        paths="$(git diff --name-only "$base...$sha" 2>/dev/null)" || { echo "pr-gate: $name could not be diffed (deleted meanwhile?) — skipped" >&2; continue; }
        rows+="$(jq -cn --arg branch "$name" --arg owner "$owner" --arg pr "$pr" --arg sha "$sha" --arg when "$when" \
                    --argjson ahead "${ahead:-null}" --argjson epoch "${epoch:-0}" --arg paths "$paths" \
                    '{branch:$branch, owner:$owner, pr:(if ($pr|test("^[0-9]+$")) then ($pr|tonumber) else $pr end),
                      sha:$sha, last_commit:$when, epoch:$epoch, ahead:$ahead,
                      paths:($paths | split("\n") | map(select(length > 0)))}')"$'\n'
    done < <(git for-each-ref --format=$'%(refname)\t%(objectname)\t%(committerdate:iso8601-strict)\t%(committerdate:unix)' refs/remotes/origin/)

    local all
    all="$(printf '%s' "$rows" | jq -s '.')"

    # The target is found among ALL rows, before --path narrows them: a
    # target changing nothing under the prefix is still in flight.
    local target=""
    if [[ -n "$OVERLAP" ]]; then
        if [[ "$OVERLAP" =~ ^[0-9]+$ ]]; then
            [[ "$prs_ok" == true ]] || { echo "pr-gate: #$OVERLAP cannot be resolved to a branch — the PR list is unavailable; name the branch instead" >&2; return 2; }
            target="$(jq -r --argjson n "$OVERLAP" '[.[] | select(.pr == $n) | .branch][0] // empty' <<<"$all")"
            [[ -n "$target" ]] || { echo "pr-gate: #$OVERLAP is not an open PR with a branch in flight on origin" >&2; return 2; }
        else
            target="$OVERLAP"
            jq -e --arg b "$target" 'any(.[]; .branch == $b)' <<<"$all" >/dev/null \
                || { echo "pr-gate: $target is not a branch in flight on origin (merged, deleted, or not pushed)" >&2; return 2; }
        fi
        all="$(jq --arg t "$target" '(.[] | select(.branch == $t) | .paths) as $tp
            | [.[] | select(.branch != $t) | .shared = [.paths[] | select(. as $p | $tp | index($p))] | select(.shared | length > 0)]' <<<"$all")"
    fi

    if (( ${#PATHS[@]} > 0 )); then
        local pj; pj="$(printf '%s\n' "${PATHS[@]}" | jq -R . | jq -s .)"
        all="$(jq --argjson pre "$pj" '[.[] | select(any(.paths[]; . as $p | any($pre[]; . as $x | $p == $x or ($p | startswith(($x | rtrimstr("/")) + "/")))))]' <<<"$all")"
    fi

    all="$(jq --argjson cap "$INFLIGHT_PATHS_CAP" '[.[] | .paths_total = (.paths | length) | .paths = .paths[:$cap]
        | if .shared then .shared_total = (.shared | length) | .shared = .shared[:$cap] else . end] | sort_by(.epoch) | reverse | map(del(.epoch))' <<<"$all")"

    if (( JSON )); then
        jq -n --argjson rows "$all" --arg base "$base" --argjson fetch_ok "$fetch_ok" --argjson prs_ok "$prs_ok" \
              --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg overlap "$target" \
              '{base:$base, fetched_at:$fetched_at, fetch_ok:$fetch_ok, prs_ok:$prs_ok} + (if $overlap != "" then {overlap_with:$overlap} else {} end) + {rows:$rows}'
    else
        local n; n="$(jq 'length' <<<"$all")"
        if [[ -n "$target" ]]; then echo "in flight on $REPO sharing a path with $target (against $base): $n — no shared path is not the same as compatible: two changes can clash in meaning without sharing a file"
        else echo "in flight on $REPO (not merged into $base): $n"; fi
        jq -r '.[] | "\(.owner)  \(.branch)  \(if (.pr|type) == "number" then "#\(.pr)" elif .pr == "none" then "no PR" else "PR unavailable" end)  ahead=\(.ahead)  last=\(.last_commit[0:16])  paths=\(.paths_total)"
                    + (if .shared then "\n    shares \(.shared_total): \(.shared[:8] | join(", "))\(if .shared_total > 8 then ", …" else "" end)" else "" end)' <<<"$all"
    fi
    [[ "$fetch_ok" == true && "$prs_ok" == true ]] || return 2
    return 0
}
