#!/usr/bin/env bash
# gzapp's forwarder to the fabric's runtime/github/post-review.sh — the one place
# this project's own names for the tool are allowed to live (the lint
# refuses them in runtime/, which is what keeps the tool every project's).
# gzapp's tools/gh/post-review.sh forwards here, argv and stdin untouched.
#
# The project posted the review class's reviews under its own marker
# before the tool became the fabric's (2026-09-19), from when that review
# was called a substitute; the reader counts those as coverage only
# because this forwarder names the marker. The GZAPP_*
# environment names the project's callers and skills still use are
# mapped to the fabric's here, the fabric's winning when both are set.
export AGENT_FABRIC_LEGACY_REVIEW_MARKERS="${AGENT_FABRIC_LEGACY_REVIEW_MARKERS:-<!-- gzapp-substitute-review v1 -->}"
[[ -n "${GZAPP_PR_REVIEW_STATUS:-}" ]] && export AGENT_FABRIC_PR_REVIEW_STATUS="${AGENT_FABRIC_PR_REVIEW_STATUS:-$GZAPP_PR_REVIEW_STATUS}"
[[ -n "${GZAPP_PR_SESSION:-}" ]]       && export AGENT_FABRIC_PR_SESSION="${AGENT_FABRIC_PR_SESSION:-$GZAPP_PR_SESSION}"
[[ -n "${GZAPP_VERDICT_AUTHORS:-}" ]]  && export AGENT_FABRIC_VERDICT_AUTHORS="${AGENT_FABRIC_VERDICT_AUTHORS:-$GZAPP_VERDICT_AUTHORS}"
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/runtime/github/post-review.sh" "$@"
