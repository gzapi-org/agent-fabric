#!/usr/bin/env bash
# runtime/github/post-substitute-review.sh (lifted from gzapp's tools/gh/, 2026-09-19 — general to every managed project; gzapp's copy is a shim)
#
# >>> help
# Post a SUBSTITUTE blind review to a PR, marked so tooling can count it.
#
# WHY THIS EXISTS. When the recognised reviewer declines — a spent
# allowance, a missing environment — CLAUDE.md's standing authorisation
# says to dispatch a blind agent and treat its findings as the bot's.
# Sessions duly did that. Nothing could see it afterwards.
#
# Two reasons, and this script closes both:
#
#   1. NO MACHINE-READABLE MARKER. The guidance said to "attribute it in
#      the body", i.e. in prose. Prose drifts: three sessions wrote
#      "Substitute blind review…", "Findings from the second blind-review
#      round…" and "Second independent blind review…". Nothing can count
#      that reliably, and a coverage claim guessed from prose is worse
#      than none. Every review this script posts carries
#      SUBSTITUTE_REVIEW_MARKER (below) as its first line.
#
#   2. NO AGREED PLACE. Every session pushes as the SAME GitHub account,
#      so a substitute review is indistinguishable from a thread reply by
#      account alone — and pr-review-status.sh bucketed both as "self
#      reviews … not coverage". Some sessions posted review OBJECTS,
#      others posted issue comments, which are not reviews at all. This
#      always posts a review object.
#
# Measured on 2026-09-06, across the 29 PRs of a three-day reviewer
# blackout: 5 carried a substitute review as a review object, 2 as issue
# comments, and 22 had none. The tooling reported 0 for all 29.
#
# THIS DOES NOT MAKE A SUBSTITUTE EQUIVALENT TO A REAL REVIEW. It makes
# it VISIBLE. pr-review-status.sh reports substitutes on their own line,
# never merged into the reviewer's count, so a later reader can always
# tell which commits had which.
#
# Usage:
#   tools/gh/post-substitute-review.sh <pr> [options]   # body on stdin
#
#   tools/gh/post-substitute-review.sh 552 <<'EOF'
#   Found a P1 in the ownership guard: a four-segment branch typed
#   `Fix/` was classified unowned, so pr-reply.sh would post to it.
#   EOF
#
# Options:
#   --model <name>   record which model produced the review (default: unset)
#   --dry-run        show what would be posted, send nothing
#   -h, --help
#
# The body arrives on STDIN and is never interpolated into a command
# line — the same rule, and the same reason, as pr-reply.sh: a body
# quoting `backticks` or $vars passed through `-f body="…"` is expanded
# by the shell before gh sees it, and that has already posted a mangled
# comment in this repo.
#
# Exit codes:
#   0  posted
#   2  invocation problem, or the PR belongs to another session
# <<< help

set -uo pipefail

die() { echo "post-substitute-review: $*" >&2; exit 2; }

# THE CONTRACT, in one string. pr-review-status.sh greps for exactly
# this; test_post-substitute-review.sh and test_pr-review-status.sh both
# pin it, so changing it here without changing the reader is caught.
# Versioned because a later field addition must not silently reclassify
# older reviews.
SUBSTITUTE_REVIEW_MARKER='<!-- gzapp-substitute-review v1 -->'

PR=""
MODEL=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)   [[ $# -ge 2 ]] || die "--model needs a value"; MODEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '/^# >>> help$/,/^# <<< help$/p' "$0" \
                | sed '1d;$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) die "unknown option '$1' (try --help)" ;;
        *)  [[ -z "$PR" ]] || die "only one PR number, got '$PR' and '$1'"
            PR="$1"; shift ;;
    esac
done

[[ -n "$PR" ]] || die "a PR number is required (try --help)"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || die "'$PR' is not a PR number"

for bin in gh jq git hostname; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin is required but not installed."
done

# STDIN, never an argument. See the header.
[[ -t 0 ]] && die "the review body is read from stdin — pipe it, or use <<'EOF' … EOF"
BODY="$(cat; printf x)"
BODY="${BODY%x}"
[[ -n "${BODY//[$' \t\n']/}" ]] || die "the review body is empty."

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || die "could not resolve the repository (gh not authenticated?)."

PR_JSON="$(gh pr view "$PR" --json number,state,headRefName,headRefOid 2>/dev/null)" \
    || die "could not read PR #$PR."
PR_BRANCH="$(jq -r '.headRefName' <<<"$PR_JSON")"
PR_HEAD="$(jq -r '.headRefOid' <<<"$PR_JSON")"
PR_STATE="$(jq -r '.state' <<<"$PR_JSON")"

# FAILS CLOSED, and this is the line that makes the comment below true.
# `jq -r '.headRefName' <<<""` exits 0 printing nothing, and a payload
# missing the field prints the literal "null" — either then splits into
# fewer than four segments, so branch_names_a_session returns "names no
# session" and the guard takes the POSTING path. A `gh` that exits 0 with
# truncated output, or any future change to the --json field set, would
# have turned the ownership guard off entirely rather than stopping.
# pr-reply.sh has this check; this copy dropped it.
[[ -n "$PR_BRANCH" && "$PR_BRANCH" != "null" ]] \
    || die "could not read the head branch of PR #$PR — refusing, because ownership is unknown."
[[ -n "$PR_HEAD" && "$PR_HEAD" != "null" ]] \
    || die "could not read the head commit of PR #$PR — refusing."

# ── lane guard ──────────────────────────────────────────────────────
#
# Same rule as pr-reply.sh, and the same reason: a review cannot be
# unsent, and another session is mid-flight on work you cannot see.
# FAILS CLOSED — not knowing whose PR this is has to mean stop.
root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git worktree, so the session's working-copy identity is unknown — refusing."
# The session is the AGENT — the Linux login, as agent-fabric resolves it —
# on this host; branches are named <host>/<agent>/<type>/<desc>. Older
# branches carry the working-copy name in the second segment, so that is
# accepted as this session too while they last (as pr-reply.sh does).
FABRIC_ROOT="${AGENT_FABRIC_ROOT:-$root/../agent-fabric}"
AGENT="$(python3 "$FABRIC_ROOT/runtime/identity.py" 2>/dev/null || id -un)"
ME="$(hostname -s)/$AGENT"
ME_LEGACY="$(hostname -s)/$(basename "$root")"
OWNER="$(cut -d/ -f1,2 <<<"$PR_BRANCH")"

# Kept identical to pr-reply.sh's predicate, including the deliberate
# absence of any test on <type>: a shape test there is a permission
# decision resting on an open-ended set, and a wrong "names no session"
# means writing to somebody else's PR.
branch_names_a_session() {
    local b="$1" IFS=/
    local -a p
    read -r -a p <<< "$b"
    [[ "${#p[@]}" -ge 4 ]]             || return 1
    [[ -n "${p[0]}" && -n "${p[1]}" ]] || return 1
    case "${p[0]}" in
        dependabot|renovate|github-actions|weblate|imgbot|\
        allcontributors|pre-commit-ci|snyk-bot) return 1 ;;
    esac
    return 0
}

if ! branch_names_a_session "$PR_BRANCH"; then
    echo "post-substitute-review: #$PR is on '$PR_BRANCH', which names no session." >&2
    echo "  No session owns it, so there is nobody to defer to — posting." >&2
elif [[ "$OWNER" != "$ME" && "$OWNER" != "$ME_LEGACY" ]]; then
    echo "post-substitute-review: #$PR belongs to '$OWNER', and this session is '$ME'." >&2
    echo "  Not posting. That session is mid-flight on work you cannot see," >&2
    echo "  and a review cannot be unsent. Raise it in the PR instead." >&2
    exit 2
fi

# ── assemble ────────────────────────────────────────────────────────
#
# The marker goes FIRST so it survives any truncation a reader applies,
# and so `head -1` identifies the review without fetching the whole body.
header="$SUBSTITUTE_REVIEW_MARKER"
[[ -n "$MODEL" ]] && header+=$'\n'"<!-- model: $MODEL -->"

FULL_BODY="$header
**Substitute blind review** — the recognised reviewer did not cover this
head, so this is a blind agent standing in for it. It is a substitute,
not an equivalent: no session context was given to the reviewer, and a
human-grade review has still not happened.

$BODY"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "would post a substitute review to #$PR ($PR_STATE) at $PR_HEAD"
    echo "--- body ---"
    printf '%s\n' "$FULL_BODY"
    exit 0
fi

# --input with a real file, never -f body="…". A review body quotes code
# by definition, and the shell would expand it first.
payload="$(mktemp)" || die "could not create a temporary file."
trap 'rm -f "$payload"' EXIT INT TERM
jq -n --arg b "$FULL_BODY" --arg c "$PR_HEAD" \
   '{body: $b, event: "COMMENT", commit_id: $c}' > "$payload" \
    || die "could not build the request payload."

url="$(gh api "repos/$REPO/pulls/$PR/reviews" --input "$payload" \
        --jq '.html_url' 2>/dev/null)" \
    || die "the review was rejected by GitHub (PR #$PR)."

[[ -n "$url" ]] || die "GitHub accepted the request but returned no review URL — treat as NOT posted."
echo "posted substitute review: $url"
echo "  marked so pr-review-status.sh counts it; it is reported separately from a real review."
