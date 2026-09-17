#!/usr/bin/env bash
# tests/run.sh — every suite agent-fabric has, in one run.
#
#   tests/run.sh            # all
#   tests/run.sh python     # only the python suites
#   tests/run.sh gzcoord    # only the GZCoord protocol/runtime suite
#   tests/run.sh bash       # only the bash suites (launcher, guards, hooks)
#   tests/run.sh static     # only the static checks (bash -n, shellcheck, ruff)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
what="${1:-all}"
fail=0
run() { echo; echo "== $1"; shift; "$@" || fail=$((fail+1)); }

if [[ "$what" == all || "$what" == static ]]; then
    run "static (bash -n, shellcheck, ruff)" bash tests/static.sh
fi
if [[ "$what" == all || "$what" == python ]]; then
    for t in tests/test_*.py; do run "$t" python3 "$t"; done
    run "corpus lint" python3 tools/fabric/lint.py
    run "routing check" python3 tools/fabric/routing.py check
fi
if [[ "$what" == all || "$what" == gzcoord ]]; then
    run "gzcoord" bash -c 'cd communication/gzcoord && node --test tests/*.test.mjs 2>&1 | grep -E -A14 "^not ok|^# (tests|pass|fail)"; [[ ${PIPESTATUS[0]} -eq 0 ]]'
    run "locale search MCP server" bash -c 'node --test runtime/mcp/websearch-locale/tests/*.test.mjs 2>&1 | grep -E -A14 "^not ok|^# (tests|pass|fail)"; [[ ${PIPESTATUS[0]} -eq 0 ]]'
    run "control plane (ops, agentd, ctl, unit)" bash -c 'node --test runtime/control/tests/*.test.mjs 2>&1 | grep -E -A14 "^not ok|^# (tests|pass|fail)"; [[ ${PIPESTATUS[0]} -eq 0 ]]'
fi
if [[ "$what" == all || "$what" == bash ]]; then
    run "launcher" bash policies/run_suite.sh runtime/openrouter/test_launch.sh
    run "charter authority guard" bash policies/run_suite.sh policies/test_check_charter_authority.sh
    run "git hooks (attribution ban, .agent-fabric/ fence)" bash policies/run_suite.sh policies/githooks/test_hooks.sh
    run ".agent-fabric/ authority guard" bash policies/run_suite.sh policies/test_check_agent_fabric_dir_authority.sh
    run ".agent-fabric/ authority (this branch)" env AGENT_FABRIC_CHARTER_BASE=origin/main bash policies/check_agent_fabric_dir_authority.sh
    run "no-model-pins guard" bash policies/run_suite.sh policies/test_check_repo_settings_carry_no_model_pins.sh
    run "attribution guard" bash policies/run_suite.sh policies/test_ban_generated_by_attribution.sh
    run "attribution (this branch)" env AGENT_FABRIC_ATTRIBUTION_BASE=origin/main bash policies/ban_generated_by_attribution.sh
    run "fabric-status" bash policies/run_suite.sh tests/test_fabric-status.sh
    run "status line" bash runtime/claude-code/hooks/test_statusline.sh
    run "new-agent (the sequence, its refusals, a failure at each step)" bash runtime/provisioning/test_new-agent.sh
    run "account persistence (the Qubes boot script, the snapshot writer)" bash runtime/provisioning/platform/test_qubes-accounts.sh
    run "language identification (the detector venv)" bash runtime/langid/test_install.sh
    run "rename-working-copy (the shell half)" bash runtime/provisioning/test_rename-working-copy.sh
    run "dispatch guard" bash runtime/claude-code/hooks/test_agent-dispatch-guard.sh
    run "review bash guard" bash runtime/claude-code/hooks/test_review-bash-guard.sh
    run "subagent clone guard" bash runtime/claude-code/hooks/test_subagent-clone-guard.sh
    run "model-switch guard" bash runtime/claude-code/hooks/test_model-switch-guard.sh
    run "plan hold" bash runtime/claude-code/hooks/test_plan-hold.sh
    run "model fallback note" bash runtime/claude-code/hooks/test_model-fallback-note.sh
    run "tab title hook" bash runtime/claude-code/hooks/test_tab-title.sh
    run "install-agent-files (the locale worker)" bash runtime/claude-code/test_install-agent-files.sh
    run "moveto" bash runtime/provisioning/moveto/test_moveto.sh
    run "hostexec (local and ssh backends)" bash runtime/hostexec/test_hostexec.sh
    run "fabric-secrets" bash policies/run_suite.sh runtime/provisioning/secrets/test_fabric-secrets.sh
    run "enroll (fault injection)" bash runtime/provisioning/secrets/test_enroll.sh
    run "github pr-reply" bash runtime/github/test_pr-reply.sh
    run "github pr-sessions" bash runtime/github/test_pr-sessions.sh
fi

echo
if (( fail )); then echo "tests/run.sh: $fail suite(s) FAILED"; exit 1; fi
echo "tests/run.sh: all suites passed"
