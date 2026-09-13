#!/usr/bin/env bash
# tools/checks/run_suite.sh
#
# Runs a shell self-test so that an UNDEFINED COMMAND fails it.
#
# THE DEFECT THIS EXISTS FOR. Every suite in this repo counts failures in
# a variable and derives its exit code from it. Call a function that was
# never defined — `assert_lacks` before it was added, a mistyped
# `assert_contians` — and bash prints "command not found" to stderr,
# returns 127, and CARRIES ON. `set -u` does not catch it. `set -e` is
# deliberately absent, because a failing assertion must not abort the
# run. The failures counter is never touched. The suite then announces
# "all assertions passed" having skipped that check entirely, and in CI,
# where nobody reads a green job's log, it is invisible.
#
# It happened on 2026-08-13 in test_actions-health.sh, and the assertion
# skipped was a NEGATIVE one — the kind that exists precisely because the
# positive check is not sufficient.
#
# WHY THIS SHAPE, AFTER A WORSE ONE. The first attempt was a static
# guard that read each suite and compared `assert_*` names called against
# names defined. Parsing shell with regular expressions cannot be done
# correctly, and it was not: it read heredoc fixture bodies as calls,
# then comments as calls, then comments containing an apostrophe as
# calls. Each patch produced the next false failure, on a MANDATORY
# check, blocking every session's PR and not only the author's. Three
# rounds of review findings.
#
# So the question changed from "can I recognise a call?" to "did one
# happen?". Bash already knows the answer: `command_not_found_handle` is
# invoked with the name whenever a command cannot be resolved. No
# lexical edge case can fool it, because nothing is being parsed —
# heredocs, comments, quotes and `eval` are all simply irrelevant. It
# also catches more than assertions: a mistyped `grpe` or a tool missing
# from the runner is the same defect wearing different clothes.
#
# THE FORK MATTERS. Bash forks before exec'ing an external command and
# calls the handler in that CHILD when the exec fails, so the handler
# cannot abort the suite by exiting — that kills only the child. It
# records the name instead, and this wrapper fails after the suite
# returns. That is also better behaviour: the suite runs to completion,
# so one missing helper does not hide the rest of the results.
#
# Usage — as a drop-in for `bash <suite>`:
#   bash tools/checks/run_suite.sh tools/gh/test_wait-merged.sh
#
# Exit codes:
#   0  the suite passed and every command it ran resolved
#   1  a command did not resolve (named on stderr), or the suite failed
#   2  usage

set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "run_suite: usage: run_suite.sh <suite.sh> [args...]" >&2
    exit 2
fi

SUITE="$1"; shift
[[ -r "$SUITE" ]] || { echo "run_suite: cannot read $SUITE" >&2; exit 2; }

MARKER="$(mktemp)"
export GZAPP_UNDEF_MARKER="$MARKER"
cleanup() { rm -f "$MARKER"; }
trap cleanup EXIT

# Exported so it reaches the suite's shell, and every shell the suite
# itself spawns. Returns rather than exits — see THE FORK MATTERS above.
command_not_found_handle() {
    printf '%s\n' "$1" >> "$GZAPP_UNDEF_MARKER"
    printf 'run_suite: undefined command: %s\n' "$1" >&2
    return 127
}
export -f command_not_found_handle

bash "$SUITE" "$@"
suite_rc=$?

if [[ -s "$MARKER" ]]; then
    echo "run_suite: FAIL — $SUITE called command(s) that do not exist:" >&2
    sort -u "$MARKER" | sed 's/^/    /' >&2
    echo "    bash returns 127 for these and continues, so the suite's own" >&2
    echo "    failures counter never saw them — it may well have reported OK." >&2
    exit 1
fi

exit "$suite_rc"
