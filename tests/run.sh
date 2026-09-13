#!/usr/bin/env bash
# tests/run.sh — every suite agent-fabric has, in one run.
#
#   tests/run.sh            # all
#   tests/run.sh python     # only the python suites
#   tests/run.sh gzcoord    # only the GZCoord protocol/runtime suite
#   tests/run.sh bash       # only the bash suites (launcher, guards, hooks)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
what="${1:-all}"
fail=0
run() { echo; echo "== $1"; shift; "$@" || fail=$((fail+1)); }

if [[ "$what" == all || "$what" == python ]]; then
    for t in tests/test_*.py; do run "$t" python3 "$t"; done
    run "corpus lint" python3 tools/fabric/lint.py
    run "routing check" python3 tools/fabric/routing.py check
fi
if [[ "$what" == all || "$what" == gzcoord ]]; then
    run "gzcoord" bash -c 'cd communication/gzcoord && node --test tests/*.test.mjs 2>&1 | grep -E "^(not ok|# (tests|pass|fail))"; [[ ${PIPESTATUS[0]} -eq 0 ]]'
fi
if [[ "$what" == all || "$what" == bash ]]; then
    run "launcher" bash policies/run_suite.sh runtime/openrouter/test_launch.sh
    run "charter authority guard" bash policies/run_suite.sh policies/test_check_charter_authority.sh
    run "no-model-pins guard" bash policies/run_suite.sh policies/test_check_repo_settings_carry_no_model_pins.sh
    run "dispatch guard" bash runtime/claude-code/hooks/test_agent-dispatch-guard.sh
    run "tab title hook" bash runtime/claude-code/hooks/test_tab-title.sh
    run "moveto" bash runtime/provisioning/moveto/test_moveto.sh
    run "gzapp pr-reply" bash projects/gzapp/integration/gh/test_pr-reply.sh
    run "gzapp pr-sessions" bash projects/gzapp/integration/gh/test_pr-sessions.sh
fi

echo
if (( fail )); then echo "tests/run.sh: $fail suite(s) FAILED"; exit 1; fi
echo "tests/run.sh: all suites passed"
