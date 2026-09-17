#!/usr/bin/env bash
# runtime/claude-code/test_install-agent-files.sh
#
# The locale worker's installation: ~/.claude/agents/locale-worker.md
# exists exactly on a language-culture login whose locale the fabric
# authored a worker for, and is removed from any other (a rebind, a locale
# with no worker), by the marker in its description. The class files ride
# unchanged. Sandboxed like runtime/openrouter/test_launch.sh: a fixture
# fabric root, a state dir with this login's binding, HOME in scratch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$HERE/../.." && pwd)"
LOGIN="$(id -un)"; SUFFIX="${LOGIN##*-}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -6; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
FABRIC="$SANDBOX/fabric"; STATE="$SANDBOX/state"
mkdir -p "$FABRIC/runtime/claude-code" "$FABRIC/tools/fabric" "$FABRIC/runtime" "$STATE/agents/$LOGIN"
cp -r "$REAL_ROOT/routing" "$FABRIC/routing"
cp "$REAL_ROOT/runtime/claude-code/aliases.json" "$REAL_ROOT/runtime/claude-code/install-agent-files.sh" "$FABRIC/runtime/claude-code/"
cp -r "$REAL_ROOT/runtime/claude-code/agents" "$FABRIC/runtime/claude-code/agents"
cp "$REAL_ROOT/runtime/identity.py" "$FABRIC/runtime/"
cp "$REAL_ROOT/tools/fabric/routing.py" "$REAL_ROOT/tools/fabric/workingcopy.py" "$REAL_ROOT/tools/fabric/layout.py" "$FABRIC/tools/fabric/"
bind() { printf '{"agent":"%s","host":"%s","role":"%s","updated_at":"x"}\n' "$LOGIN" "$(hostname -s)" "$1" > "$STATE/agents/$LOGIN/binding.json"; }
WORKER="$FABRIC/identities/roles/language-culture/locale/$SUFFIX/worker.md"
mkdir -p "$(dirname "$WORKER")"
printf -- '---\nname: locale-worker\ndescription: The locale worker (agent-fabric) — fixture\nmodel: opus\ntools:\n---\n\nფიქსტურა.\n' > "$WORKER"
run_install() { AGENT_FABRIC_ROOT="$FABRIC" AGENT_FABRIC_STATE_DIR="$STATE" bash "$FABRIC/runtime/claude-code/install-agent-files.sh" "$@" 2>&1; }
DEST="$HOME/.claude/agents/locale-worker.md"

echo "a language-culture login with an authored worker for its locale gets the file"
bind language-culture
out="$(run_install --dry-run)"
grep -q "locale-worker.md (would write)" <<<"$out" && [[ ! -e "$DEST" ]] && ok "dry run names it and writes nothing" || bad "dry run" "$out"
out="$(run_install)"
[[ -f "$DEST" ]] && cmp -s "$DEST" "$WORKER" && ok "installed, byte-equal to the source" || bad "install" "$out"
[[ -f "$HOME/.claude/agents/code-low.md" && -f "$HOME/.claude/agents/code-review.md" ]] && ok "the class files ride as before" || bad "class files"
out="$(run_install)"; grep -q "locale-worker.md" <<<"$out" && grep -q "=  $DEST" <<<"$out" && ok "a second run changes nothing" || bad "idempotence" "$out"

echo "the locale search tool: an MCP entry in the user configuration, on the same login"
mkdir -p "$(dirname "$WORKER")"; printf '{"country": "ALL", "timezone": "Asia/Tbilisi", "tool_description": "ვებ-ძიება"}' > "$(dirname "$WORKER")/locale.json"
mkdir -p "$FABRIC/runtime/mcp/websearch-locale"; cp "$REAL_ROOT/runtime/mcp/websearch-locale/install.py" "$FABRIC/runtime/mcp/websearch-locale/"; : > "$FABRIC/runtime/mcp/websearch-locale/server.mjs"
printf '{"theme": "dark", "mcpServers": {"mine": {"command": "x"}}}' > "$HOME/.claude.json"
out="$(run_install)"; grep -q "mcpServers.websearch-locale" <<<"$out" && python3 -c "import json,sys; d=json.load(open('$HOME/.claude.json')); e=d['mcpServers']['websearch-locale']; assert e['command']=='node' and e['args'][0].endswith('runtime/mcp/websearch-locale/server.mjs') and e['env']['WEBSEARCH_LOCALE_FILE'].endswith('/locale.json') and d['theme']=='dark' and 'mine' in d['mcpServers'], d" && ok "the entry is written beside what was there" || bad "mcp entry" "$out"
out="$(run_install)"; grep -q "=  $HOME/.claude.json mcpServers.websearch-locale" <<<"$out" && ok "a second run leaves it" || bad "mcp idempotence" "$out"

echo "another role: the worker is removed by its marker"
bind backend-dev
out="$(run_install --dry-run)"; grep -q "would remove: role is backend-dev" <<<"$out" && [[ -f "$DEST" ]] && ok "dry run names the removal and touches nothing" || bad "dry-run removal" "$out"
out="$(run_install)"; [[ ! -e "$DEST" ]] && grep -q "removed: role is backend-dev" <<<"$out" && ok "removed" || bad "removal" "$out"
out="$(run_install)"; ! grep -q "locale-worker" <<<"$out" && ok "nothing to remove the second time, nothing said" || bad "second removal" "$out"
python3 -c "import json; d=json.load(open('$HOME/.claude.json')); assert 'websearch-locale' not in d['mcpServers'] and 'mine' in d['mcpServers'], d" && ok "the MCP entry went with the role; the login's own stayed" || bad "mcp removal" "$(cat "$HOME/.claude.json")"

echo "a language-culture login whose locale has no authored worker: removed, never another locale's"
bind language-culture
run_install >/dev/null; [[ -f "$DEST" ]] || bad "precondition: installed"
rm -rf "$FABRIC/identities/roles/language-culture/locale/$SUFFIX"; mkdir -p "$FABRIC/identities/roles/language-culture/locale/xx"; cp "$WORKER" "$FABRIC/identities/roles/language-culture/locale/xx/worker.md" 2>/dev/null || printf -- '---\nname: locale-worker\ndescription: (agent-fabric)\nmodel: opus\ntools:\n---\nx\n' > "$FABRIC/identities/roles/language-culture/locale/xx/worker.md"
out="$(run_install)"; [[ ! -e "$DEST" ]] && grep -q "no worker authored for locale $SUFFIX" <<<"$out" && ok "removed and the reason names the locale" || bad "wrong-locale removal" "$out"

echo "a worker file the fabric did not write is left alone"
bind backend-dev
mkdir -p "$HOME/.claude/agents"; printf -- '---\nname: locale-worker\ndescription: my own\n---\nmine\n' > "$DEST"
run_install >/dev/null; [[ -f "$DEST" ]] && grep -q "my own" "$DEST" && ok "a hand-written file without the marker survives" || bad "hand-written file removed"

echo
if (( FAIL == 0 )); then echo "test_install-agent-files: OK — $PASS assertion(s) passed."; exit 0; fi
echo "test_install-agent-files: $FAIL failure(s)" >&2; exit 1
