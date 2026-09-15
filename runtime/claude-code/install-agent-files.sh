#!/usr/bin/env bash
# runtime/claude-code/install-agent-files.sh
#
# Install THIS account's capability-class agent files,
# ~/.claude/agents/{code-low,code-medium,code-high,blind-reviewer}.md, from
# runtime/claude-code/agents/, with the review pin applied.
#
#   runtime/claude-code/install-agent-files.sh [--dry-run]
#
# bootstrap.sh calls this at provisioning; bin/fabric-model calls it after
# a change to the account's local layer, because the pin it applies is
# per agent: `routing.py pins --me` merges the column with the login's
# role and its model-profile.local.json.
#
# WHY A FILE CARRIES THE PIN. On a fabric vanilla launch (runtime/
# openrouter/launch --provider anthropic) the review class runs on a
# native model, but its alias (fable) is also the hand's tier, so the
# launcher exports nothing under it — a hand `/model fable` must stay the
# harness's. The one route left (verified live 2026-09-15): the agent
# file's `model:` line decides when the dispatch leaves `model` unset,
# and the dispatch guard drops the dispatch's alias under this launch
# after checking it was `fable`. The coding classes ride the exported
# aliases and keep the repo file's alias line; the pin here is the review
# class's alone, from routing, so there is one source.
set -euo pipefail

FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

changed=0; same=0
put() {  # put <dest> <content-file>
    local dest="$1" src="$2"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        same=$((same+1)); echo "  =  $dest"; return
    fi
    if (( DRY_RUN )); then echo "  +  $dest (would write)"; return; fi
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]] && ! grep -q "agent-fabric" "$dest" 2>/dev/null; then
        cp "$dest" "$dest.before-agent-fabric"
        echo "     (kept the previous file as $dest.before-agent-fabric)"
    fi
    install -m 644 "$src" "$dest"
    changed=$((changed+1)); echo "  +  $dest"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
declare -A PIN_BY_CLASS=()
while read -r klass alias model; do
    [[ -n "$klass" ]] && PIN_BY_CLASS["$klass"]="$model"
done < <(AGENT_FABRIC_ROOT="$FABRIC_ROOT" python3 "$FABRIC_ROOT/tools/fabric/routing.py" pins --me)
agent_class() { case "$1" in blind-reviewer.md) echo review ;; *) echo "${1%.md}" ;; esac; }
for f in code-low.md code-medium.md code-high.md blind-reviewer.md; do
    pin="${PIN_BY_CLASS[$(agent_class "$f")]:-}"
    if [[ -n "$pin" ]]; then
        sed "0,/^model: .*/s||model: $pin|" "$FABRIC_ROOT/runtime/claude-code/agents/$f" > "$TMP/$f"
        put "$CLAUDE_HOME/agents/$f" "$TMP/$f"
    else
        put "$CLAUDE_HOME/agents/$f" "$FABRIC_ROOT/runtime/claude-code/agents/$f"
    fi
done
echo "agent files: $changed written, $same already current."
