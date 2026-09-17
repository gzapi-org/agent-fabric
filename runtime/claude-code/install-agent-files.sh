#!/usr/bin/env bash
# runtime/claude-code/install-agent-files.sh
#
# Install THIS account's capability-class agent files,
# ~/.claude/agents/{code-low,code-medium,code-high,code-review}.md, from
# runtime/claude-code/agents/, with the review pin applied — and, on a
# language-culture login, the locale worker (below).
#
#   runtime/claude-code/install-agent-files.sh [--provider openrouter|anthropic] [--dry-run]
#
# The launcher calls this for its provider before every exec; bootstrap.sh
# at provisioning (anthropic, the unlaunched default); bin/fabric-model
# after a change to the review pin. The pin it applies is per agent and
# per provider: `routing.py pins --me --provider P` merges the column with
# the login's role and its model-profile.local.json.
#
# WHY A FILE CARRIES THE PIN. The review class rides the same tier alias
# as code-plan (fable): the Agent tool's `model` takes only the four
# aliases, and one alias carries one export, so through the export the
# reviewer would follow code-plan (as it once followed code-high on opus,
# 2026-09-13). The one route left (verified live on plain claude,
# 2026-09-15): the agent file's `model:` line decides when the dispatch
# leaves `model` unset, and the dispatch guard drops the dispatch's alias
# under a fabric launch after checking it was `fable`. The coding classes
# ride the exported aliases and keep the repo file's alias line; the pin
# here is the review class's alone, from routing, so there is one source.
# One file serves one launch at a time: two sessions of one account on
# different providers would rewrite it in turn, which the guard catches.
set -euo pipefail

FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DRY_RUN=0; PROVIDER="${AGENT_FABRIC_LAUNCH_PROVIDER:-anthropic}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --provider=*) PROVIDER="${1#--provider=}"; shift ;;
        *) echo "install-agent-files: unknown argument $1" >&2; exit 2 ;;
    esac
done

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
done < <(AGENT_FABRIC_ROOT="$FABRIC_ROOT" python3 "$FABRIC_ROOT/tools/fabric/routing.py" pins --me --provider "$PROVIDER")
for f in code-low.md code-medium.md code-high.md code-plan.md code-review.md; do
    pin="${PIN_BY_CLASS[${f%.md}]:-}"
    if [[ -n "$pin" ]]; then
        sed "0,/^model: .*/s||model: $pin|" "$FABRIC_ROOT/runtime/claude-code/agents/$f" > "$TMP/$f"
        put "$CLAUDE_HOME/agents/$f" "$TMP/$f"
    else
        put "$CLAUDE_HOME/agents/$f" "$FABRIC_ROOT/runtime/claude-code/agents/$f"
    fi
done
# The locale worker: the language-culture role's subagent, one inert tool, whose
# system prompt is the locale's language (docs/language-culture-bridge.md).
# Installed as ~/.claude/agents/locale-worker.md on a login of that role
# whose name ends in a locale the fabric authored
# (identities/roles/language-culture/locale/<suffix>/worker.md); removed —
# by the `agent-fabric` marker in its description, as blind-reviewer.md
# below — from any other login, and from one whose locale has no worker,
# so a rebind never serves another locale's worker. No per-provider pin:
# the worker shares no alias with another class, so its model line rides
# as authored (the reviewer's file pin exists only because fable is
# code-plan's too).
ROLE="$(AGENT_FABRIC_ROOT="$FABRIC_ROOT" python3 "$FABRIC_ROOT/runtime/identity.py" --role 2>/dev/null || true)"
LOGIN_NAME="$(id -un)"; LOCALE_SUFFIX="${LOGIN_NAME##*-}"
WORKER_SRC="$FABRIC_ROOT/identities/roles/language-culture/locale/$LOCALE_SUFFIX/worker.md"
WORKER_DEST="$CLAUDE_HOME/agents/locale-worker.md"
if [[ "$ROLE" == "language-culture" && -f "$WORKER_SRC" ]]; then
    put "$WORKER_DEST" "$WORKER_SRC"
elif [[ -f "$WORKER_DEST" ]] && grep -q "agent-fabric" "$WORKER_DEST" 2>/dev/null; then
    if (( DRY_RUN )); then echo "  -  $WORKER_DEST (would remove: role is ${ROLE:-unbound}, or no worker authored for locale $LOCALE_SUFFIX)"
    else rm -f "$WORKER_DEST"; echo "  -  $WORKER_DEST (removed: role is ${ROLE:-unbound}, or no worker authored for locale $LOCALE_SUFFIX)"; changed=$((changed+1)); fi
fi
# The review class was installed as blind-reviewer.md until 2026-09-15; a
# copy of ours left there would offer the retired type beside the new one.
old="$CLAUDE_HOME/agents/blind-reviewer.md"
if [[ -f "$old" ]] && grep -q "agent-fabric" "$old" 2>/dev/null; then
    if (( DRY_RUN )); then echo "  -  $old (would remove: retired name of code-review)"
    else rm -f "$old"; echo "  -  $old (retired name of code-review)"; changed=$((changed+1)); fi
fi
echo "agent files ($PROVIDER): $changed written, $same already current."
