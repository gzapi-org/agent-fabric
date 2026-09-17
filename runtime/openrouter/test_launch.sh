#!/usr/bin/env bash
# runtime/openrouter/test_launch.sh
#
# Behavioural tests for runtime/openrouter/launch. The launcher execs a
# session, so the tests run it in SANDBOXES: a fake agent-fabric root (the
# real routing files, the real resolver), a fake state directory holding
# this agent's binding, a fake `ori` on PATH, and HOME pointed at a scratch
# dir. Every refusal, the merge order, the shim derivation and the
# review-grade gate are exercised without spawning a real claude.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="$HERE/launch"
LOGIN="$(id -un)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -6; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
mkdir -p "$SANDBOX/bin"
PATH_EXPORT="$SANDBOX/bin:$PATH"

# A fake ori whose auth --json reports environment-sourced auth and which
# records its argv and the child's environment when claude is called.
write_fake_ori() {
cat > "$SANDBOX/bin/ori" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == auth ]]; then
    echo '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'
    exit 0
fi
echo "ORI-EXECCED:$*"
# The child's ENVIRONMENT, not only its argv: a pin that lost its `export`
# would still print under --print and still be absent here.
for v in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL AGENT_FABRIC_LAUNCH_SESSION_MODEL AGENT_FABRIC_LAUNCH_PROFILE AGENT_FABRIC_LAUNCH_AGENT AGENT_FABRIC_LAUNCH_ROLE AGENT_FABRIC_LAUNCH_PROMPT_DIGEST AGENT_FABRIC_LAUNCH_CLAUDE_VERSION CLAUDE_CODE_DISABLE_TERMINAL_TITLE TMPDIR; do
    echo "ORI-ENV:$v=${!v:-}"
done
FAKE
chmod +x "$SANDBOX/bin/ori"
}
write_fake_ori

# A fixture agent-fabric root: the real routing files and resolver, a
# state dir with this agent's binding (role backend-dev), and a launch
# working copy with a real git toplevel.
FABRIC="$SANDBOX/fabric"; STATE="$SANDBOX/state"
mkfabric() {
    rm -rf "$FABRIC" "$STATE" "$SANDBOX/repo"
    mkdir -p "$FABRIC/runtime/openrouter" "$FABRIC/runtime/claude-code" "$FABRIC/tools/fabric" "$FABRIC/projects"
    cp -r "$REAL_ROOT/routing" "$FABRIC/routing"
    cp "$REAL_ROOT/runtime/claude-code/aliases.json" "$REAL_ROOT/runtime/claude-code/install-agent-files.sh" "$FABRIC/runtime/claude-code/"
    cp -r "$REAL_ROOT/runtime/claude-code/agents" "$FABRIC/runtime/claude-code/agents"
    mkdir -p "$FABRIC/runtime/mcp"; cp -r "$REAL_ROOT/runtime/mcp/websearch-locale" "$FABRIC/runtime/mcp/"   # the installer's MCP step reads its helper from the fabric
    cp "$REAL_ROOT/runtime/identity.py" "$FABRIC/runtime/"
    cp "$REAL_ROOT/tools/fabric/routing.py" "$REAL_ROOT/tools/fabric/workingcopy.py" "$FABRIC/tools/fabric/"
    # The role's system prompt: the assembler, the shared sections, and a
    # fixture charter for the bound role (no brief — the placeholder path).
    cp "$REAL_ROOT/tools/fabric/layout.py" "$REAL_ROOT/tools/fabric/launch_prompt.py" "$REAL_ROOT/tools/fabric/announce.py" "$FABRIC/tools/fabric/"
    mkdir -p "$FABRIC/identities/roles/backend-dev"; cp -r "$REAL_ROOT/identities/prompt" "$FABRIC/identities/prompt"
    printf -- '---\nrole: backend-dev\nclass: charter\ndescription: "x"\ntier: 1\ndistilled_at: 2026-09-15\n---\n\n# backend-dev — charter\n\nFIXTURE-CHARTER-LINE: the backend that owns meaning.\n' > "$FABRIC/identities/roles/backend-dev/charter.md"
    cp "$REAL_ROOT/projects/registry.json" "$FABRIC/projects/"
    mkdir -p "$STATE/agents/$LOGIN"
    printf '{"agent":"%s","host":"'"$(hostname -s)"'","role":"backend-dev","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
    mkdir -p "$SANDBOX/repo"; git init -q "$SANDBOX/repo"
}
# profile defaults '<json>'  |  profile roles <role> '<json>'  |  profile agents <login> '<json>'
profile() { python3 - "$FABRIC/routing/profiles.json" "$@" <<'PY'
import json, sys
path, layer = sys.argv[1], sys.argv[2]
d = json.load(open(path))
if layer == "defaults":
    d["defaults"].update(json.loads(sys.argv[3]))
else:
    key, body = sys.argv[3], json.loads(sys.argv[4])
    d.setdefault(layer, {})[key] = body
json.dump(d, open(path, "w"), indent=1)
PY
}
run() { (cd "$SANDBOX/repo" && HOME="$HOME" PATH="$PATH_EXPORT" AGENT_FABRIC_ROOT="$FABRIC" AGENT_FABRIC_STATE_DIR="$STATE" AGENT_FABRIC_NO_ANNOUNCE=1 bash "$LAUNCHER" "$@"); }
run_err() { run "$@" >/dev/null 2>&1; }

echo "launch: --print resolves the capability classes through model -> family shim"
mkfabric
out="$(run --print)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0" || bad "rc=$rc" "$out"
grep -q "resolved profile for backend-dev/$LOGIN (agent $LOGIN, role backend-dev, provider openrouter)" <<<"$out" && ok "the label is role/agent, agent = login" || bad "label wrong" "$out"
grep -q "session : anthropic/claude-sonnet-5" <<<"$out" && ok "default session" || bad "session wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "code-low -> glm-5.3-flash + shim -> haiku alias" || bad "code-low wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_SONNET_MODEL=z-ai/glm-5.2@preset/glm2claude-shim" <<<"$out" && ok "code-medium -> glm-5.2 + shim -> sonnet alias" || bad "code-medium wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "code-high -> glm-5.3 + shim -> opus alias" || bad "code-high wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_FABLE_MODEL=z-ai/glm-5.3@preset/glm2claude-shim$" <<<"$out" && ok "review -> glm-5.3 + shim -> fable alias, its own export" || bad "review wrong" "$out"
[[ "$(grep -c 'export ANTHROPIC_DEFAULT_' <<<"$out")" == 4 ]] && ok "four aliases, four exports: the review class never shares code-high's" || bad "export count" "$out"

echo "launch: a non-GLM override receives no shim; a GLM override keeps it"
mkfabric; profile roles backend-dev '{"capabilities":{"code-high":"anthropic/claude-sonnet-5"}}'
out="$(run --print)"
grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic/claude-sonnet-5$" <<<"$out" && ok "a role override to a non-GLM model gets no shim" || bad "shim attached to a non-GLM model" "$out"
grep -q "export ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "the untouched GLM class keeps its shim" || bad "shim lost" "$out"
mkfabric; profile agents "$LOGIN" '{"capabilities":{"code-low":"z-ai/glm-5.2"},"session":"z-ai/glm-5.3"}'
out="$(run --print)"
grep -q "export ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.2@preset/glm2claude-shim" <<<"$out" && ok "an agent (login-keyed) override to another GLM model keeps the family shim" || bad "agent override ignored or unshimmed" "$out"
grep -q "session : z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "the session (main agent) gets the family shim too, separately from the classes" || bad "session shim wrong" "$out"

echo "launch: merge order — defaults <- role <- agent <- local, later wins"
mkfabric
profile defaults '{"capabilities":{"code-low":"vendor/default-low"}}'
profile roles backend-dev '{"capabilities":{"code-low":"vendor/role-low","code-medium":"vendor/role-medium"}}'
profile agents "$LOGIN" '{"capabilities":{"code-medium":"vendor/agent-medium"},"session":"vendor/agent-session"}'
printf '%s\n' '{"session":"vendor/local-session"}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --print)"
grep -q "ANTHROPIC_DEFAULT_HAIKU_MODEL=vendor/role-low" <<<"$out" && ok "role row wins over defaults" || bad "role row ignored" "$out"
grep -q "ANTHROPIC_DEFAULT_SONNET_MODEL=vendor/agent-medium" <<<"$out" && ok "agent row wins over role" || bad "agent row ignored" "$out"
grep -q "session : vendor/local-session" <<<"$out" && ok "the local override wins over the agent row" || bad "local override ignored" "$out"

echo "launch: the review gate"
mkfabric; printf '%s\n' '{"capabilities":{"code-review":"anthropic/claude-opus-5"}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "code-review : anthropic/claude-opus-5  shim -  => anthropic/claude-opus-5  (pinned in the agent file" <<<"$out" && ! grep -q "ANTHROPIC_DEFAULT_FABLE_MODEL=anthropic/claude-opus-5" <<<"$out" && ok "another review-grade model in the local override is allowed; it reaches the reviewer file, never the fable export (code-plan's)" || bad "review-grade override refused" "$out"
grep -q "export ANTHROPIC_DEFAULT_FABLE_MODEL=z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "the fable export is code-plan's" || bad "fable export not code-plan's" "$out"
mkfabric; printf '%s\n' '{"capabilities":{"code-review":"z-ai/glm-5.3-flash"}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
run_err --print; [[ $? -ne 0 ]] && ok "a review model outside review-grade.json in the local override is REFUSED" || bad "review gate bypassed by local override"
mkfabric; printf '%s\n' '{"capabilities":{"code-high":"z-ai/glm-5.3-flash"}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "the coding classes are NOT review-gated: a cheap code-high is allowed" || bad "code-high wrongly gated" "$out"

echo "launch: the refusals"
mkfabric; rm "$STATE/agents/$LOGIN/binding.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "no active role binding" <<<"$out" && grep -q "bin/fabric-role bind" <<<"$out" && ok "no binding: refused, names bin/fabric-role" || bad "ran without a role" "$out"
mkfabric; printf '{"agent":"%s","host":"'"$(hostname -s)"'","role":null,"updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
run_err --print; [[ $? -eq 1 ]] && ok "binding with no role: refused" || bad "ran with a null role"
mkfabric; rm "$FABRIC/routing/capabilities.json"
run_err --print; [[ $? -eq 1 ]] && ok "no capabilities.json: refused" || bad "ran without the routing files"
mkfabric
out="$(run --settings foo.json)"; [[ $? -ne 0 ]] && ok "--settings passthrough refused" || bad "fence bypass allowed" "$out"
mkfabric; run_err --setting-sources user,project
[[ $? -ne 0 ]] && ok "--setting-sources passthrough refused" || bad "fence bypass allowed"
for flag in --system-prompt --system-prompt-file --append-system-prompt --append-system-prompt-file; do
    mkfabric; out="$(run $flag x.md 2>&1)"; rc=$?
    [[ $rc -ne 0 ]] && grep -q "role's system prompt is the" <<<"$out" && ok "$flag passthrough refused: the role's prompt is the launcher's" || bad "$flag admitted" "$out"
    mkfabric; run_err "$flag=x.md"; [[ $? -ne 0 ]] && ok "$flag=… refused too" || bad "$flag=… admitted"
done
mkfabric
mkdir -p "$HOME/.claude"
printf '%s\n' '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"vendor/sneaky"}}' > "$HOME/.claude/settings.json"
run_err --print; [[ $? -eq 1 ]] && ok "user-scope ANTHROPIC_DEFAULT pin: refused" || bad "would race the profile"
rm -f "$HOME/.claude/settings.json"

# EVERY settings scope is fenced, and the refusal names the file and key.
pin_in() {  # pin_in <file> <json>
    mkfabric; mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
    [[ -s "$1" ]] || { bad "fixture not written: $1"; rc=99; out=""; return; }
    out="$(run --print 2>&1)"; rc=$?
    rm -f "$1"
}
pin_in "$HOME/.claude/settings.local.json" '{"env":{"ANTHROPIC_DEFAULT_HAIKU_MODEL":"vendor/sneaky"}}'
[[ $rc -eq 1 ]] && ok "user LOCAL scope pin: refused" || bad "user local scope unfenced" "$out"
pin_in "$SANDBOX/repo/.claude/settings.json" '{"modelOverrides":{"claude-opus-5":"vendor/sneaky"}}'
[[ $rc -eq 1 ]] && ok "project scope modelOverrides: refused" || bad "project scope unfenced" "$out"
pin_in "$SANDBOX/repo/.claude/settings.local.json" '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"vendor/sneaky"}}'
[[ $rc -eq 1 ]] && ok "project LOCAL scope subagent pin: refused" || bad "project local scope unfenced" "$out"
grep -q "settings.local.json carries model pins (env.CLAUDE_CODE_SUBAGENT_MODEL)" <<<"$out" && ok "…naming the file and the key" || bad "refusal does not name the offender" "$out"
mkdir -p "$SANDBOX/cfgdir"; mkfabric; printf '%s\n' '{"env":{"ANTHROPIC_MODEL":"vendor/sneaky"}}' > "$SANDBOX/cfgdir/settings.json"
out="$(CLAUDE_CONFIG_DIR="$SANDBOX/cfgdir" run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && ok "CLAUDE_CONFIG_DIR scope, ANTHROPIC_MODEL (not only _DEFAULT_): refused" || bad "config-dir scope unfenced" "$out"
rm -rf "$SANDBOX/cfgdir"
pin_in "$SANDBOX/repo/.claude/settings.local.json" '{"env":{"CLAUDE_BRIDGE_AUTH_TOKEN":"not-a-pin"},"model":"opus"}'
[[ $rc -eq 0 ]] && ok "a non-pin env entry and a top-level model preference are not refused" || bad "over-fenced" "$out"
mkfabric
out="$(CLAUDE_CODE_SUBAGENT_MODEL=vendor/sneaky run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && ok "CLAUDE_CODE_SUBAGENT_MODEL in the caller's environment: refused" || bad "process-env subagent pin rides through" "$out"
mkfabric
out="$(CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "SUBAGENT_MODEL_FORCE" <<<"$out" && ok "CLAUDE_CODE_SUBAGENT_MODEL_FORCE: refused" || bad "FORCE rides through" "$out"
# The fence is on the LAUNCH directory, never an inherited REPO_ROOT.
mkfabric; rm -rf "$SANDBOX/other"; cp -r "$SANDBOX/repo" "$SANDBOX/other"
mkdir -p "$SANDBOX/repo/.claude"; printf '%s\n' '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"vendor/sneaky"}}' > "$SANDBOX/repo/.claude/settings.local.json"
out="$(REPO_ROOT="$SANDBOX/other" run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "repo/.claude/settings.local.json carries model pins" <<<"$out" && ok "an inherited REPO_ROOT does not move the fence off the launch directory" || bad "inherited REPO_ROOT bypassed the launch dir's pin" "$out"
rm -rf "$SANDBOX/other"

echo "launch: identity comes from the OS, not from the directory or the environment"
mkfabric; rm -rf "$SANDBOX/repo"; mkdir -p "$SANDBOX/architect-cto-01"; git init -q "$SANDBOX/architect-cto-01"
out="$(cd "$SANDBOX/architect-cto-01" && HOME="$HOME" PATH="$PATH_EXPORT" AGENT_FABRIC_ROOT="$FABRIC" AGENT_FABRIC_STATE_DIR="$STATE" USER=architect-cto-01 LOGNAME=architect-cto-01 bash "$LAUNCHER" --print 2>&1)"
grep -q "(agent $LOGIN, role backend-dev, provider openrouter)" <<<"$out" && ok "launched from a directory named for another agent, with USER forged: still agent $LOGIN" || bad "identity taken from directory or env" "$out"
mkdir -p "$SANDBOX/repo"; git init -q "$SANDBOX/repo"

# A malformed LOCAL override is refused, not exported as "None".
override() { mkfabric; printf '%s\n' "$1" > "$STATE/agents/$LOGIN/model-profile.local.json"; out="$(run --print 2>&1)"; rc=$?; }
override '{"session": null}'
[[ $rc -eq 1 ]] && grep -q "session is None" <<<"$out" && ok "session: null refused, named" || bad "None session accepted" "$out"
override '{"capabilities": {"code-low": null}}'
[[ $rc -eq 1 ]] && ok "capabilities.code-low: null refused" || bad "None class accepted" "$out"
override '{"capabilities": {"code-low": "Not A Model"}}'
[[ $rc -eq 1 ]] && ok "a class that is not a model id refused" || bad "prose accepted" "$out"
override '{"capabilities": {"code-low": ""}}'
[[ $rc -eq 1 ]] && ok "an empty class refused (ori would silently substitute its own default)" || bad "empty accepted" "$out"
override '{"capabilities": {"code-low": "z-ai/glm-5.3@preset/glm2claude-shim"}}'
[[ $rc -eq 1 ]] && ok "a COMPOSITE in a profile layer is refused: the shim is derived, never configured" || bad "composite accepted as canonical" "$out"
override '{"session": "anthropic/claude-opus-5:floor[1m]"}'
[[ $rc -eq 0 ]] && ok "variant and [1m] spellings accepted" || bad "valid ids refused" "$out"
override '{"session": "vendor/model\n"}'
[[ $rc -eq 1 ]] && grep -q "session is 'vendor/model\\\\n'" <<<"$out" && ok "a trailing newline is not a model id" || bad "regex stopped before the newline" "$out"

# --print anywhere in the arguments, not only first.
mkfabric
out="$(run --verbose --print 2>&1)"; rc=$?
grep -q "resolved profile" <<<"$out" && ! grep -q "ORI-EXECCED" <<<"$out" && ok "--print after another flag still prints, never execs" || bad "--print passed through to claude" "$out"

# Auth is a CONJUNCTION — authenticated AND source.kind == environment.
fake_auth() { printf '#!/usr/bin/env bash\necho %q\nexit %s\n' "$1" "${2:-0}" > "$SANDBOX/bin/ori"; chmod +x "$SANDBOX/bin/ori"; }
mkfabric; fake_auth '{"ok":false,"data":{"authenticated":false}}' 1
run_err --print; [[ $? -eq 1 ]] && ok "unauthenticated ori: refused" || bad "would exec into a prompt"
mkfabric; fake_auth '{"ok":true,"data":{"authenticated":false,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'
run_err --print; [[ $? -eq 1 ]] && ok "unauthenticated but environment-sourced: refused" || bad "OR admitted an unauthenticated env key"
mkfabric; fake_auth '{"ok":true,"data":{"authenticated":true,"source":{"kind":"workspace"}}}'
run_err --print; [[ $? -eq 1 ]] && ok "authenticated from a stored credential: refused" || bad "non-environment source admitted"
mkfabric; fake_auth '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment"}}}' 3
run_err --print; [[ $? -eq 1 ]] && ok "ori auth exit status is kept" || bad "non-zero ori auth ignored"
write_fake_ori

echo "launch: --provider anthropic execs plain claude with only the pinned tiers exported"
# A fake claude that records its argv and the four tier variables.
cat > "$SANDBOX/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "CLAUDE-EXECCED:$*"
for v in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_BASE_URL AGENT_FABRIC_LAUNCH_SESSION_MODEL AGENT_FABRIC_LAUNCH_PROVIDER AGENT_FABRIC_LAUNCH_PROFILE AGENT_FABRIC_LAUNCH_ROLE AGENT_FABRIC_LAUNCH_PROMPT_DIGEST AGENT_FABRIC_LAUNCH_CLAUDE_VERSION CLAUDE_CODE_DISABLE_TERMINAL_TITLE TMPDIR; do
    echo "CLAUDE-ENV:$v=${!v:-}"
done
FAKE
chmod +x "$SANDBOX/bin/claude"
mkfabric
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "--print exits 0" || bad "rc=$rc" "$out"
grep -q "provider anthropic)" <<<"$out" && ok "the header names the provider" || bad "provider not in header" "$out"
grep -q "session : claude-opus-5$" <<<"$out" && ok "the session is the anthropic default, Opus 5 (its own, not the broker's spelled natively)" || bad "session not the anthropic default" "$out"
grep -q "code-review : claude-opus-5\[1m\]  (pinned in the agent file; the dispatch guard applies it; from capabilities.providers.anthropic)" <<<"$out" && ok "the review class is pinned to claude-opus-5[1m] (the column's native id), through the agent file" || bad "review not pinned" "$out"
grep -q "code-high   : claude-opus-5  (exported for its tier; from capabilities.providers.anthropic)" <<<"$out" && grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5$" <<<"$out" && ok "a coding class pinned by the column is exported for the tier it rides (the top of each class)" || bad "column pin not exported" "$out"
grep -q "export ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5-1$" <<<"$out" && ok "the fable export is code-plan's pin; the reviewer never rides it" || bad "fable export wrong" "$out"
python3 - "$FABRIC/routing/capabilities.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1])); d["providers"]["anthropic"]["models"]["code-high"] = None
json.dump(d, open(sys.argv[1], "w"))
PY2
out="$(run --provider anthropic --print 2>&1)"; rc=$?
grep -q "code-high   : opus  (harness default for its tier)" <<<"$out" && ! grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL" <<<"$out" && ok "a null in the column is the harness's own tier: nothing exported for it" || bad "null column not the harness's" "$out"
mkfabric; out="$(run --provider anthropic --print 2>&1)"; rc=$?
out="$(run --provider=anthropic --version 2>&1)"
grep -q "CLAUDE-EXECCED:--model claude-opus-5 --append-system-prompt-file $STATE/agents/$LOGIN/launch-prompt.md --version" <<<"$out" && ok "execs plain claude with the native session model and the role's prompt file" || bad "no plain-claude exec" "$out"
grep -q "CLAUDE-ENV:AGENT_FABRIC_LAUNCH_ROLE=backend-dev$" <<<"$out" && ok "role stamped on plain claude" || bad "no role stamp" "$out"
! grep -q -- "--disallowedTools" <<<"$out" && ok "no tool removed from a login that is not language-culture" || bad "WebSearch removed from the wrong login" "$out"
# A language-culture login whose locale has a search: the harness's WebSearch is removed at exec.
mkdir -p "$FABRIC/identities/roles/language-culture"; cp -r "$FABRIC/identities/roles/backend-dev/." "$FABRIC/identities/roles/language-culture/"   # a charter to render
mkdir -p "$FABRIC/identities/roles/language-culture/locale/${LOGIN##*-}"; printf '{"timezone":"Asia/Tbilisi","brave":{"country":"ALL","tool_description":"ძიება"}}' > "$FABRIC/identities/roles/language-culture/locale/${LOGIN##*-}/locale.json"
printf '{"agent":"%s","host":"'"$(hostname -s)"'","role":"language-culture","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
outlc="$(run --provider anthropic -- --version 2>&1)"
grep -q "CLAUDE-EXECCED:.*--disallowedTools WebSearch .*--version" <<<"$outlc" && ok "a language-culture login with a locale search execs claude without WebSearch" || bad "WebSearch not removed on the language-culture login" "$outlc"
grep -q "CLAUDE-EXECCED:.*--append-system-prompt-file $STATE/agents/$LOGIN/launch-prompt.md" <<<"$outlc" && grep -q "CLAUDE-ENV:AGENT_FABRIC_LAUNCH_CLAUDE_VERSION=$" <<<"$outlc" && ok "…with the prompt still appended and no build stamp: the locale carries no harness text" || bad "append expected without a harness translation" "$outlc"
# The locale carries the harness text: the whole prompt is replaced, the build stamped, on both providers.
printf -- '---\nclass: harness-translation\ntranslates: runtime/claude-code/harness/en.md\ntranslates_digest: sha256:x\n---\nშენ ხარ Claude Code. მეხსიერება: `{memory_dir}`.\n' > "$FABRIC/identities/roles/language-culture/locale/${LOGIN##*-}/harness.md"
outlc="$(run --provider anthropic -- --version 2>&1)"
grep -q "CLAUDE-EXECCED:.*--system-prompt-file $STATE/agents/$LOGIN/launch-prompt.md" <<<"$outlc" && ! grep -q -- "--append-system-prompt-file" <<<"$outlc" && ok "a locale with the harness text execs claude with the whole prompt replaced" || bad "the prompt was not replaced" "$outlc"
grep -q "CLAUDE-ENV:AGENT_FABRIC_LAUNCH_CLAUDE_VERSION=." <<<"$outlc" && ok "…and the build it ran is stamped" || bad "no build stamp on the replace branch" "$outlc"
grep -q "შენ ხარ Claude Code. მეხსიერება: \`$HOME/.claude/projects/" "$STATE/agents/$LOGIN/launch-prompt.md" && ! grep -q "{memory_dir}" "$STATE/agents/$LOGIN/launch-prompt.md" && ok "the rendered file ends with the harness text, its memory directory filled" || bad "harness text not rendered" "$(tail -3 "$STATE/agents/$LOGIN/launch-prompt.md")"
outp="$(run --provider anthropic --print 2>&1)"
grep -q "bytes; --system-prompt-file)" <<<"$outp" && grep -q "AGENT_FABRIC_LAUNCH_CLAUDE_VERSION=" <<<"$outp" && ok "--print names the flag and the build" || bad "--print does not name the replace" "$outp"
outori="$(run -- --version 2>&1)"
grep -q "ORI-EXECCED:claude .*--system-prompt-file $STATE/agents/$LOGIN/launch-prompt.md" <<<"$outori" && ok "the broker path carries the same flag" || bad "ori path lost the replace flag" "$outori"
rm -f "$FABRIC/identities/roles/language-culture/locale/${LOGIN##*-}/harness.md"
rm -rf "$FABRIC/identities/roles/language-culture/locale/${LOGIN##*-}"
outlc="$(run --provider anthropic -- --version 2>&1)"
! grep -q -- "--disallowedTools" <<<"$outlc" && ok "…and not when its locale has no search authored" || bad "WebSearch removed without a locale" "$outlc"
rm -rf "$FABRIC/identities/roles/language-culture"
printf '{"agent":"%s","host":"'"$(hostname -s)"'","role":"backend-dev","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
grep -q "CLAUDE-ENV:CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1" <<<"$out" && ok "tab-title writer off on plain claude too" || bad "terminal-title switch missing on plain claude" "$out"
grep -q "CLAUDE-ENV:TMPDIR=/var/tmp/agent-fabric-$LOGIN" <<<"$out" && [[ -d "/var/tmp/agent-fabric-$LOGIN" && "$(stat -c %a "/var/tmp/agent-fabric-$LOGIN")" == 700 ]] && ok "TMPDIR is a per-login directory under /var/tmp, created 700" || bad "TMPDIR not exported under /var/tmp" "$out"
mkdir -p "$SANDBOX/own-tmp"
out2="$(TMPDIR="$SANDBOX/own-tmp" run --provider=anthropic --version 2>&1)"
grep -q "CLAUDE-ENV:TMPDIR=$SANDBOX/own-tmp" <<<"$out2" && ok "a TMPDIR the account set wins" || bad "the launcher overrode a set TMPDIR" "$out2"
! grep -q "ORI-EXECCED" <<<"$out" && ok "…not ori" || bad "went through ori" "$out"
grep -q "CLAUDE-ENV:ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5-1$" <<<"$out" && ok "FABLE exported as code-plan's pin, the native id" || bad "fable pin not in the child's env" "$out"
grep -q "CLAUDE-ENV:ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5$" <<<"$out" && ok "OPUS exported as code-high's pin" || bad "opus not in the child's env" "$out"
grep -q "^model: claude-opus-5\[1m\]$" "$HOME/.claude/agents/code-review.md" && ok "the exec installed the reviewer file for plain claude: claude-opus-5[1m]" || bad "reviewer file not installed for anthropic" "$(cat "$HOME/.claude/agents/code-review.md" 2>&1 | head -5)"
out="$(run --version 2>&1)"
grep -q "^model: z-ai/glm-5.3@preset/glm2claude-shim$" "$HOME/.claude/agents/code-review.md" && ok "…and a broker launch rewrites it with the composite: one file, one launch at a time" || bad "reviewer file not installed for the broker" "$(cat "$HOME/.claude/agents/code-review.md" 2>&1 | head -5)"
grep -q "^model: fable$" "$HOME/.claude/agents/code-plan.md" && ok "code-plan keeps its alias line: its pin is the export" || bad "code-plan file pinned" "$(head -5 "$HOME/.claude/agents/code-plan.md")"
out="$(run --provider=anthropic --version 2>&1)"
grep -q "CLAUDE-ENV:ANTHROPIC_BASE_URL=$" <<<"$out" && ok "no base URL: Anthropic direct" || bad "base URL set" "$out"
grep -q "CLAUDE-ENV:AGENT_FABRIC_LAUNCH_PROVIDER=anthropic" <<<"$out" && ok "provider stamped" || bad "no provider stamp" "$out"
grep -q "CLAUDE-ENV:AGENT_FABRIC_LAUNCH_PROFILE=backend-dev/$LOGIN" <<<"$out" && ok "profile stamped on vanilla too" || bad "no profile stamp" "$out"
mkfabric
rm -f "$STATE/agents/$LOGIN/binding.json"
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no active role binding" <<<"$out" && ok "vanilla through the launcher still needs a bound role" || bad "unbound vanilla launch admitted" "$out"
mkfabric
profile defaults '{"session": "z-ai/glm-5.3", "providers": {}}'
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "not an Anthropic model and no profile layer names one" <<<"$out" && ok "a non-Anthropic session with no Anthropic layer is refused on vanilla, not mistranslated" || bad "foreign session admitted" "$out"
# A layer is per provider: plain claude's session and pins are named in
# its own vocabulary (the class, a native id) and never leak to the broker.
mkfabric
printf '%s\n' '{"providers":{"openrouter":{"session":"z-ai/glm-5.3"},"anthropic":{"session":"code-plan","capabilities":{"code-high":"claude-opus-5[1m]","code-low":"claude-haiku-4-5"}}}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "session : claude-fable-5-1  (the code-plan class)" <<<"$out" && ! grep -q "is not an Anthropic model" <<<"$out" && ok "plain claude's session is providers.anthropic.session, a class, resolved on this provider, with no skip to report" || bad "per-provider session not honoured" "$out"
grep -q "code-high   : claude-opus-5\[1m\]  (exported for its tier; from local)" <<<"$out" && grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5\[1m\]" <<<"$out" && ok "a local pin of a coding class is exported for the tier it rides and says where it came from" || bad "local pin not exported" "$out"
grep -q "export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5$" <<<"$out" && grep -q "export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5$" <<<"$out" && ok "the other tiers keep the column's pins" || bad "column pins lost under a local layer" "$out"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "session : z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "the same file on the broker: its own session, and the native pins do not reach the broker's exports" || bad "anthropic layer leaked to the broker" "$out"
printf '%s\n' '{"session":"code-high"}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "session : z-ai/glm-5.3@preset/glm2claude-shim  (the code-high class)" <<<"$out" && ok "a flat class-named session is that class's composite on the broker" || bad "class session on the broker" "$out"
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "session : claude-opus-5  (the code-high class)" <<<"$out" && ok "…and that class's native pin on plain claude" || bad "class session on vanilla" "$out"
printf '%s\n' '{"providers":{"anthropic":{"capabilities":{"code-review":"claude-haiku-4-5"}}}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "not in routing/policies/review-grade.json" <<<"$out" && ok "a local review pin outside the grade is refused on vanilla" || bad "ungraded local review pin admitted" "$out"
printf '%s\n' '{"providers":{"anthropic":{"capabilities":{"code-high":"z-ai/glm-5.3"}}}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "providers.anthropic.capabilities.code-high is 'z-ai/glm-5.3', not a native Claude id" <<<"$out" && ok "a class pinned to a broker id on plain claude is refused by name" || bad "wrong vocabulary admitted" "$out"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "…on the broker path too: one malformed layer refuses every launch" || bad "malformed anthropic layer admitted on the broker" "$out"
printf '%s\n' '{"providers":{"anthropic":{"capabilities":{"code-high":"opus"}}}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "not a native Claude id" <<<"$out" && ok "a tier alias is not a model: the class is the vocabulary, the alias is the adapter's" || bad "alias admitted as a model" "$out"
mkfabric
python3 - "$FABRIC/routing/capabilities.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["providers"]["anthropic"]["models"]["code-review"] = "claude-haiku-4-5"
json.dump(d, open(sys.argv[1], "w"))
PY
out="$(run --provider anthropic --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "not in routing/policies/review-grade.json" <<<"$out" && ok "a pinned review model outside the grade is refused on vanilla too" || bad "ungraded vanilla review admitted" "$out"
out="$(run --provider nowhere --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "must be openrouter or anthropic" <<<"$out" && ok "an unknown provider is refused" || bad "unknown provider admitted" "$out"
rm -f "$SANDBOX/bin/claude"

echo "launch: the exec carries the pins to the child"
mkfabric
out="$(run --version 2>&1)"; rc=$?
grep -q "ORI-EXECCED:" <<<"$out" && ok "execs via ori claude" || bad "no exec" "$out"
grep -q -- "--model anthropic/claude-sonnet-5" <<<"$out" && ok "session model passed as --model" || bad "session missing" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "HAIKU pin (code-low composite) is in the child's environment" || bad "haiku pin not exported" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_SONNET_MODEL=z-ai/glm-5.2@preset/glm2claude-shim" <<<"$out" && ok "SONNET pin (code-medium composite) is in the child's environment" || bad "sonnet pin not exported" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "OPUS pin (code-high composite) is in the child's environment" || bad "opus pin not exported" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_FABLE_MODEL=z-ai/glm-5.3@preset/glm2claude-shim$" <<<"$out" && ok "FABLE pin (review composite) is in the child's environment, separate from OPUS" || bad "fable pin not exported" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_SESSION_MODEL=anthropic/claude-sonnet-5" <<<"$out" && ok "session model stamped in the child env" || bad "no session stamp" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_PROFILE=backend-dev/$LOGIN" <<<"$out" && ok "profile stamped as role/agent" || bad "no profile stamp" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_AGENT=$LOGIN" <<<"$out" && ok "agent stamped" || bad "no agent stamp" "$out"
grep -q "ORI-ENV:CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1" <<<"$out" && ok "the harness's tab-title writer is off in the child: the hook is the only writer" || bad "terminal-title switch not in the child's env" "$out"
mkfabric
out="$(run --model vendor/override --version 2>&1)"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_SESSION_MODEL=vendor/override" <<<"$out" && ok "a caller's --model is what gets stamped" || bad "stamp disagrees with argv" "$out"
grep -q "ORI-EXECCED:claude --append-system-prompt-file $STATE/agents/$LOGIN/launch-prompt.md --model vendor/override --version" <<<"$out" && ! grep -q -- "--model anthropic/claude-sonnet-5" <<<"$out" && ok "…and the launcher's own --model is omitted, so the child sees one; the prompt file still rides" || bad "two --model flags reached the child, or no prompt file" "$out"
mkfabric
out="$(run --print --model=vendor/override2 2>&1)"
grep -q "overridden by --model on the command line: vendor/override2" <<<"$out" && ok "--print shows the override" || bad "--print hides the override" "$out"
mkfabric
out="$(run -p hi 2>&1)"
grep -q "ORI-EXECCED:claude --model anthropic/claude-sonnet-5 --append-system-prompt-file $STATE/agents/$LOGIN/launch-prompt.md -p hi" <<<"$out" && ok "-p passes through to claude untouched, after the prompt file" || bad "-p swallowed by the launcher" "$out"

echo "launch: HELLO before the session, GOODBYE after it, however it ended"
# A stub announce.py that records every call; the binding names a project
# (announce sends nothing without one); NO_ANNOUNCE lifted for these cases.
mkfabric
printf '{"agent":"%s","host":"'"$(hostname -s)"'","role":"backend-dev","project":"gzapp","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
cat > "$FABRIC/tools/fabric/announce.py" <<'STUB'
import os, sys, time
with open(os.environ["ANNOUNCE_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + f" @{time.time():.3f}\n")
STUB
ALOG="$SANDBOX/announce.log"; rm -f "$ALOG"
runa() { (cd "$SANDBOX/repo" && HOME="$HOME" PATH="$PATH_EXPORT" AGENT_FABRIC_ROOT="$FABRIC" AGENT_FABRIC_STATE_DIR="$STATE" ANNOUNCE_LOG="$ALOG" bash "$LAUNCHER" "$@"); }
out="$(runa --version 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "the launcher's exit status is the session's (0)" || bad "rc=$rc" "$out"
grep -q "^hello --role backend-dev --project gzapp" "$ALOG" && ok "HELLO sent, as the bound role and project" || bad "no hello" "$(cat "$ALOG")"
grep -q "^goodbye --role backend-dev --project gzapp --note session ended" "$ALOG" && ok "GOODBYE sent after the session returned" || bad "no goodbye" "$(cat "$ALOG")"
[[ "$(grep -c . "$ALOG")" == 2 ]] && ok "exactly one of each" || bad "announce count" "$(cat "$ALOG")"
h="$(grep '^hello' "$ALOG" | sed 's/.*@//')"; g="$(grep '^goodbye' "$ALOG" | sed 's/.*@//')"
python3 -c "import sys; sys.exit(0 if float('$h') < float('$g') else 1)" && ok "…in that order" || bad "goodbye before hello" "$(cat "$ALOG")"
# The session's failure is the launcher's failure, and still a GOODBYE.
cat > "$SANDBOX/bin/ori" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == auth ]]; then echo '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'; exit 0; fi
echo "ORI-EXECCED:$*"; exit 3
FAKE
chmod +x "$SANDBOX/bin/ori"; rm -f "$ALOG"
out="$(runa --version 2>&1)"; rc=$?
[[ $rc -eq 3 ]] && ok "a session exiting 3 makes the launcher exit 3" || bad "rc=$rc" "$out"
grep -q "^goodbye .*--note session ended with status 3" "$ALOG" && ok "…and the GOODBYE names the status" || bad "goodbye note" "$(cat "$ALOG")"
# A session killed by a signal — what a double Ctrl-C or a kill leaves — still ends in a GOODBYE.
cat > "$SANDBOX/bin/ori" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == auth ]]; then echo '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'; exit 0; fi
echo "ORI-EXECCED:$*"; kill -TERM $$
FAKE
chmod +x "$SANDBOX/bin/ori"; rm -f "$ALOG"
out="$(runa --version 2>&1)"; rc=$?
[[ $rc -eq 143 ]] && ok "a session ended by SIGTERM: the launcher reports 143" || bad "rc=$rc" "$out"
grep -q "^goodbye .*--note session ended by signal 15" "$ALOG" && ok "…and the GOODBYE names the signal" || bad "goodbye note" "$(cat "$ALOG")"
write_fake_ori

echo "launch: a fabric checkout behind origin/main is pulled and the launcher re-executes on it"
# The fixture fabric becomes a git checkout with a bare origin one commit ahead.
mkfabric
G() { git -C "$FABRIC" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G init -q -b main >/dev/null 2>&1; G add -A >/dev/null; G commit -q -m base >/dev/null
rm -rf "$SANDBOX/origin.git"; git init -q --bare -b main "$SANDBOX/origin.git"
G remote add origin "$SANDBOX/origin.git"; G push -q origin main 2>/dev/null
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "current: the fetch finds nothing behind, launch proceeds" || bad "current checkout refused" "$out"
# origin gains a commit the checkout lacks
rm -rf "$SANDBOX/other"; git clone -q "$SANDBOX/origin.git" "$SANDBOX/other"
git -C "$SANDBOX/other" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m newer; git -C "$SANDBOX/other" push -q origin main
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "was 1 commit(s) behind origin/main; pulled to" <<<"$out" && grep -q "relaunching on it" <<<"$out" && ok "behind: pulled, said so, relaunched" || bad "stale checkout not pulled" "$out"
[[ "$(G rev-parse HEAD)" == "$(git -C "$SANDBOX/other" rev-parse HEAD)" ]] && ok "…the checkout is at origin/main" || bad "not pulled" "$(G log --oneline -2)"
grep -q "resolved profile" <<<"$out" && ok "…and the relaunch resolved the profile (one pull, one relaunch)" || bad "no profile after the relaunch" "$out"
# behind again, with a local commit that cannot fast-forward: refused with the reason
git -C "$SANDBOX/other" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m newer2; git -C "$SANDBOX/other" push -q origin main
G commit -q --allow-empty -m local-divergence
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "cannot fast-forward" <<<"$out" && ! grep -q "resolved profile" <<<"$out" && ok "diverged: refused with the reason, before resolving anything" || bad "diverged checkout admitted" "$out"
G reset -q --hard origin/main
# behind, with the override: launches without pulling, loudly
git -C "$SANDBOX/other" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m newer3; git -C "$SANDBOX/other" push -q origin main
out="$(AGENT_FABRIC_ALLOW_STALE=1 run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "WARNING — agent-fabric is 1 commit(s) behind" <<<"$out" && [[ "$(G rev-parse HEAD)" != "$(git -C "$SANDBOX/other" rev-parse HEAD)" ]] && ok "AGENT_FABRIC_ALLOW_STALE=1: launches without pulling, loudly" || bad "override" "$out"
# a relaunch that is still behind does not loop
out="$(AGENT_FABRIC_PULLED=1 run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "still 1 commit(s) behind origin/main after a pull; not relaunching again" <<<"$out" && ok "a second relaunch is refused: no loop" || bad "loop guard" "$out"
G pull -q --ff-only origin main
G remote set-url origin /nonexistent/origin.git
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "could not fetch origin/main" <<<"$out" && ok "origin unreachable: launches on what is checked out, and says so" || bad "offline refused" "$out"

echo "launch: the role rides in the system prompt file"
mkfabric
out="$(run --version 2>&1)"; rc=$?
[[ -f "$STATE/agents/$LOGIN/launch-prompt.md" ]] && ok "the prompt file is written under the agent's state dir" || bad "no prompt file" "$(ls -la "$STATE/agents/$LOGIN" 2>&1)"
grep -q "FIXTURE-CHARTER-LINE" "$STATE/agents/$LOGIN/launch-prompt.md" && ok "…and carries the bound role's charter body" || bad "charter not in the prompt" "$(head -40 "$STATE/agents/$LOGIN/launch-prompt.md")"
grep -q "^You are agent \`$LOGIN\` on host" "$STATE/agents/$LOGIN/launch-prompt.md" && grep -q "the role \*\*backend-dev\*\*" "$STATE/agents/$LOGIN/launch-prompt.md" && ok "…the identity header names agent and role" || bad "header wrong" "$(head -5 "$STATE/agents/$LOGIN/launch-prompt.md")"
grep -q "No brief has been distilled" "$STATE/agents/$LOGIN/launch-prompt.md" && ok "…a missing brief is a placeholder, not a refusal" || bad "no placeholder" "$(grep -n brief "$STATE/agents/$LOGIN/launch-prompt.md")"
grep -q "REPLY-EXPECTED: yes" "$STATE/agents/$LOGIN/launch-prompt.md" && grep -q "memory/domains/backend-dev/" "$STATE/agents/$LOGIN/launch-prompt.md" && ok "…the team and memory sections are rendered for the role" || bad "shared sections missing" ""
! grep -q "class: charter" "$STATE/agents/$LOGIN/launch-prompt.md" && ok "…without frontmatter" || bad "frontmatter leaked" ""
digest="sha256:$(sha256sum "$STATE/agents/$LOGIN/launch-prompt.md" | cut -d' ' -f1)"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_ROLE=backend-dev$" <<<"$out" && ok "role stamped in the child env" || bad "no role stamp" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_PROMPT_DIGEST=$digest$" <<<"$out" && ok "the prompt's sha256 stamped, and it is the file's" || bad "digest stamp wrong" "$out"
mkfabric
out="$(run --print 2>&1)"
grep -q "export AGENT_FABRIC_LAUNCH_ROLE=backend-dev" <<<"$out" && grep -q "export AGENT_FABRIC_LAUNCH_PROMPT_DIGEST=sha256:" <<<"$out" && grep -q "prompt  : $STATE/agents/$LOGIN/launch-prompt.md (" <<<"$out" && ok "--print shows the role, the digest and the prompt path" || bad "--print hides the prompt" "$out"
! grep -q "EXECCED" <<<"$out" && ok "…and execs nothing" || bad "--print exec'd" "$out"
mkfabric; rm "$FABRIC/identities/roles/backend-dev/charter.md"
out="$(run --version 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "could not render the role's system prompt" <<<"$out" && ! grep -q "EXECCED" <<<"$out" && ok "a role with no charter cannot launch: refused before exec" || bad "launched without a charter" "$out"

echo "model-audit: provider values are allowlisted, never echoed by default"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_CUSTOM_HEADERS='Authorization: Bearer test-secret' ANTHROPIC_BASE_URL='https://key-secret@proxy.example/api' ANTHROPIC_DEFAULT_OPUS_MODEL='anthropic/claude-opus-5' bash "$HERE/model-audit.sh" 2>&1)"
! grep -q 'test-secret' <<<"$out" && grep -q 'ANTHROPIC_CUSTOM_HEADERS = <set, ' <<<"$out" && ok "a non-allowlisted provider variable is reported set, not printed" || bad "credential printed in clear" "$out"
! grep -q 'key-secret' <<<"$out" && grep -q 'ANTHROPIC_BASE_URL = https://proxy.example$' <<<"$out" && ok "the base URL prints scheme+host, no userinfo" || bad "base URL userinfo leaked" "$out"
grep -q 'ANTHROPIC_DEFAULT_OPUS_MODEL = anthropic/claude-opus-5' <<<"$out" && ok "an allowlisted pin prints its value" || bad "pin redacted" "$out"
grep -q 'not launched via runtime/openrouter/launch' <<<"$out" && ok "no stamp: says the session model is not visible" || bad "guessed a session model" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='HTTPS://key@proxy.example:8443?api_key=qs-secret#frag-secret' bash "$HERE/model-audit.sh" 2>&1)"
! grep -qE 'key@|qs-secret|frag-secret' <<<"$out" && grep -q 'ANTHROPIC_BASE_URL = https://proxy.example:8443$' <<<"$out" && ok "uppercase scheme, no path, query+fragment: scheme://host:port only" || bad "base URL leaked" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='sk-or-v1-notaurl' bash "$HERE/model-audit.sh" 2>&1)"
! grep -q 'sk-or' <<<"$out" && grep -q 'ANTHROPIC_BASE_URL = <set, 16 chars>' <<<"$out" && ok "a non-URL base value is reported set, never echoed" || bad "non-URL printed" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" AGENT_FABRIC_LAUNCH_SESSION_MODEL=vendor/s AGENT_FABRIC_LAUNCH_PROFILE=r/a AGENT_FABRIC_LAUNCH_AGENT=a bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'session : vendor/s' <<<"$out" && grep -q 'profile : r/a' <<<"$out" && grep -q 'agent   : a' <<<"$out" && ok "the launcher's stamp is reported, agent included" || bad "stamp not reported" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_CUSTOM_HEADERS=$'Authorization: Bearer first-secret\nANTHROPIC_MODEL=second-secret' bash "$HERE/model-audit.sh" 2>&1)"
! grep -qE 'first-secret|second-secret' <<<"$out" && grep -q 'ANTHROPIC_CUSTOM_HEADERS = <set, 64 chars>' <<<"$out" && ! grep -q 'ANTHROPIC_MODEL = ' <<<"$out" && ok "a newline inside a redacted value neither splits the entry nor truncates the count" || bad "env entry boundary lost on newline" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='HTTPS://OPENROUTER.AI/api' bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'routed through OpenRouter' <<<"$out" && ok "an uppercase openrouter.ai host classifies as OpenRouter" || bad "host test is case-sensitive" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='https://notopenrouter.example/openrouter' bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'does not name OpenRouter' <<<"$out" && ok "a look-alike host with openrouter in the path is not OpenRouter" || bad "host test is a substring match" "$out"

echo
if [[ $FAIL -eq 0 ]]; then
    echo "test_launch: OK — $PASS assertion(s) passed."
else
    echo "test_launch: FAILED — $FAIL assertion(s) failed."; exit 1
fi
