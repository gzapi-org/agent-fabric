#!/usr/bin/env bash
# Claude Code SessionStart hook: resolve the agent from the OS, record the
# working copy and project the session is in, print one context line.
# Exec of runtime/claude-code/hooks/session-start.py; exit 0 always.
#
# It also makes AGENT_FABRIC_ROOT real in the session's own shell: a
# SessionStart hook may append `export` lines to $CLAUDE_ENV_FILE and the
# harness sources them into every later Bash tool call. Without this the
# variable existed only for the hook's python child, and every documented
# `node "$AGENT_FABRIC_ROOT/…/inbox.mjs"` expanded to /communication/…
# in a live session (devex-tooling, 2026-09-13).
FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
AGENT_FABRIC_ROOT="${AGENT_FABRIC_ROOT:-$FABRIC_ROOT}"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  printf 'export AGENT_FABRIC_ROOT=%q\n' "$AGENT_FABRIC_ROOT" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi
AGENT_FABRIC_ROOT="$AGENT_FABRIC_ROOT" python3 "$FABRIC_ROOT/runtime/claude-code/hooks/session-start.py"
exit 0
