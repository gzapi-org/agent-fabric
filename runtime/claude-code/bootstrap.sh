#!/usr/bin/env bash
# runtime/claude-code/bootstrap.sh
#
# Make agent-fabric's workspace instructions available to a Claude Code
# session launched from the parent projects/ directory, for THIS account.
#
#   runtime/claude-code/bootstrap.sh [--projects DIR] [--dry-run]
#
# Writes, idempotently, and only machine-local files:
#   <projects>/CLAUDE.md               3 lines; imports agent-fabric/CLAUDE.md
#   <projects>/.claude/settings.json   hooks + status line pointing at agent-fabric
#   ~/.claude/commands/role.md         /role for this account, from runtime/claude-code/commands/
#   ~/.claude/agents/code-*.md         the capability-class agent files, from runtime/claude-code/agents/
#
# Nothing here names an agent: the hooks ask the OS who is running at
# session start. Nothing here makes projects/ a git repository. A managed
# project keeps its own CLAUDE.md and .claude/ for sessions launched inside
# it. Re-running refreshes only what differs.
#
# The projects directory defaults to the parent of this checkout — the
# layout agent-fabric assumes is projects/agent-fabric beside the working
# copies it manages.
set -euo pipefail

FABRIC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
PROJECTS="$(dirname "$FABRIC_ROOT")"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --projects) PROJECTS="$(cd "$2" && pwd)"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "bootstrap: unknown argument $1" >&2; exit 2 ;;
    esac
done
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

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

echo "agent-fabric bootstrap for agent $(python3 "$FABRIC_ROOT/runtime/identity.py") — projects: $PROJECTS"

# 1. The workspace CLAUDE.md: three lines, an import, no instructions of its own.
put "$PROJECTS/CLAUDE.md" "$FABRIC_ROOT/runtime/claude-code/workspace/CLAUDE.md"

# 2. The workspace settings: hooks and status line, with the root substituted.
python3 - "$FABRIC_ROOT/runtime/claude-code/workspace/settings.json" "$FABRIC_ROOT" "$PROJECTS/.claude/settings.json" "$TMP/settings.json" <<'PY'
import json, os, sys
template, root, existing_path, out = sys.argv[1:5]
tpl = json.load(open(template))
tpl.pop("_comment", None)
def sub(v):
    if isinstance(v, str): return v.replace("$AGENT_FABRIC_ROOT", root)
    if isinstance(v, list): return [sub(x) for x in v]
    if isinstance(v, dict): return {k: sub(x) for k, x in v.items()}
    return v
tpl = sub(tpl)
# Merge over an existing workspace settings file: keep everything it has,
# add or refresh only the entries agent-fabric owns (those naming its root).
doc = {}
if os.path.exists(existing_path):
    try: doc = json.load(open(existing_path)) or {}
    except ValueError: doc = {}
doc["statusLine"] = tpl["statusLine"]
hooks = doc.setdefault("hooks", {})
for event, groups in tpl["hooks"].items():
    kept = [g for g in hooks.get(event, []) if root not in json.dumps(g)]
    hooks[event] = kept + groups
json.dump(doc, open(out, "w"), indent=2)
open(out, "a").write("\n")
PY
put "$PROJECTS/.claude/settings.json" "$TMP/settings.json"

# 3. /role for this account, and the capability-class agent files.
put "$CLAUDE_HOME/commands/role.md" "$FABRIC_ROOT/runtime/claude-code/commands/role.md"
for f in code-low.md code-medium.md code-high.md; do
    put "$CLAUDE_HOME/agents/$f" "$FABRIC_ROOT/runtime/claude-code/agents/$f"
done

echo "bootstrap: $changed written, $same already current."
echo "Launch from $PROJECTS: cd \"$PROJECTS\" && claude   — the session starts as $(python3 "$FABRIC_ROOT/runtime/identity.py")."
