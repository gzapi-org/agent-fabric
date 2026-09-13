#!/usr/bin/env bash
# Claude Code SessionStart hook: resolve the agent from the OS, record the
# working copy and project the session is in, print one context line.
# Exec of runtime/claude-code/hooks/session-start.py; exit 0 always.
FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
AGENT_FABRIC_ROOT="${AGENT_FABRIC_ROOT:-$FABRIC_ROOT}" python3 "$FABRIC_ROOT/runtime/claude-code/hooks/session-start.py"
exit 0
