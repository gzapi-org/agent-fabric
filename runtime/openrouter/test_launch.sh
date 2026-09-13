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
for v in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL AGENT_FABRIC_LAUNCH_SESSION_MODEL AGENT_FABRIC_LAUNCH_PROFILE AGENT_FABRIC_LAUNCH_AGENT; do
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
    cp "$REAL_ROOT/runtime/claude-code/aliases.json" "$FABRIC/runtime/claude-code/"
    cp "$REAL_ROOT/runtime/identity.py" "$FABRIC/runtime/"
    cp "$REAL_ROOT/tools/fabric/routing.py" "$REAL_ROOT/tools/fabric/workingcopy.py" "$FABRIC/tools/fabric/"
    cp "$REAL_ROOT/projects/registry.json" "$FABRIC/projects/"
    mkdir -p "$STATE/agents/$LOGIN"
    printf '{"agent":"%s","host":"testhost","role":"backend-dev","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
    mkdir -p "$SANDBOX/repo"; git init -q "$SANDBOX/repo"
}
profile() { python3 - "$FABRIC/routing/profiles.json" "$@" <<'PY'
import json, sys
path, layer, key, body = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
d = json.load(open(path))
if layer == "defaults": d["defaults"].update(body)
else: d.setdefault(layer, {})[key] = body
json.dump(d, open(path, "w"), indent=1)
PY
}
run() { (cd "$SANDBOX/repo" && HOME="$HOME" PATH="$PATH_EXPORT" AGENT_FABRIC_ROOT="$FABRIC" AGENT_FABRIC_STATE_DIR="$STATE" bash "$LAUNCHER" "$@"); }
run_err() { run "$@" >/dev/null 2>&1; }

echo "launch: --print resolves the capability classes through model -> family shim"
mkfabric
out="$(run --print)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0" || bad "rc=$rc" "$out"
grep -q "resolved profile for backend-dev/$LOGIN (agent $LOGIN, role backend-dev)" <<<"$out" && ok "the label is role/agent, agent = login" || bad "label wrong" "$out"
grep -q "session : anthropic/claude-sonnet-5" <<<"$out" && ok "default session" || bad "session wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "code-low -> glm-5.3-flash + shim -> haiku alias" || bad "code-low wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_SONNET_MODEL=z-ai/glm-5.2@preset/glm2claude-shim" <<<"$out" && ok "code-medium -> glm-5.2 + shim -> sonnet alias" || bad "code-medium wrong" "$out"
grep -q "export ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "code-high -> glm-5.3 + shim -> opus alias" || bad "code-high wrong" "$out"
grep -q "review      : anthropic/claude-opus-5\[1m\]  shim -  declared in the agent file as claude-opus-5\[1m\], not exported" <<<"$out" && ok "review is declared by full id, no shim, not exported" || bad "review wrong" "$out"
! grep -q "ANTHROPIC_DEFAULT_FABLE_MODEL" <<<"$out" && ok "no class rides the fable alias, so nothing is exported for it" || bad "fable exported" "$out"

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
mkfabric; printf '%s\n' '{"capabilities":{"review":"anthropic/claude-opus-5"}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "resolves to 'anthropic/claude-opus-5' on the broker, but the agent file declares 'claude-opus-5\[1m\]'" <<<"$out" && ok "a review-grade model that is not the DECLARED id is still refused (the request names the declared id)" || bad "declared/profile mismatch admitted" "$out"
mkfabric; printf '%s\n' '{"capabilities":{"review":"z-ai/glm-5.3"}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
run_err --print; [[ $? -ne 0 ]] && ok "a cheap review model in the local override is REFUSED" || bad "review gate bypassed by local override"
mkfabric; printf '%s\n' '{"capabilities":{"code-high":"z-ai/glm-5.3-flash"}}' > "$STATE/agents/$LOGIN/model-profile.local.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "the coding classes are NOT review-gated: a cheap code-high is allowed" || bad "code-high wrongly gated" "$out"

echo "launch: the refusals"
mkfabric; rm "$STATE/agents/$LOGIN/binding.json"
out="$(run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "no active role binding" <<<"$out" && ok "no binding: refused, names /role" || bad "ran without a role" "$out"
mkfabric; printf '{"agent":"%s","host":"h","role":null,"updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
run_err --print; [[ $? -eq 1 ]] && ok "binding with no role: refused" || bad "ran with a null role"
mkfabric; rm "$FABRIC/routing/capabilities.json"
run_err --print; [[ $? -eq 1 ]] && ok "no capabilities.json: refused" || bad "ran without the routing files"
mkfabric
out="$(run --settings foo.json)"; [[ $? -ne 0 ]] && ok "--settings passthrough refused" || bad "fence bypass allowed" "$out"
mkfabric; run_err --setting-sources user,project
[[ $? -ne 0 ]] && ok "--setting-sources passthrough refused" || bad "fence bypass allowed"
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
grep -q "(agent $LOGIN, role backend-dev)" <<<"$out" && ok "launched from a directory named for another agent, with USER forged: still agent $LOGIN" || bad "identity taken from directory or env" "$out"
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

echo "launch: the exec carries the pins to the child"
mkfabric
out="$(run --version 2>&1)"; rc=$?
grep -q "ORI-EXECCED:" <<<"$out" && ok "execs via ori claude" || bad "no exec" "$out"
grep -q -- "--model anthropic/claude-sonnet-5" <<<"$out" && ok "session model passed as --model" || bad "session missing" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.3-flash@preset/glm2claude-shim" <<<"$out" && ok "HAIKU pin (code-low composite) is in the child's environment" || bad "haiku pin not exported" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_SONNET_MODEL=z-ai/glm-5.2@preset/glm2claude-shim" <<<"$out" && ok "SONNET pin (code-medium composite) is in the child's environment" || bad "sonnet pin not exported" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3@preset/glm2claude-shim" <<<"$out" && ok "OPUS pin (code-high composite) is in the child's environment" || bad "opus pin not exported" "$out"
grep -q "ORI-ENV:ANTHROPIC_DEFAULT_FABLE_MODEL=$" <<<"$out" && ok "FABLE is not pinned (no class rides it; ori's default applies)" || bad "fable pinned" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_SESSION_MODEL=anthropic/claude-sonnet-5" <<<"$out" && ok "session model stamped in the child env" || bad "no session stamp" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_PROFILE=backend-dev/$LOGIN" <<<"$out" && ok "profile stamped as role/agent" || bad "no profile stamp" "$out"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_AGENT=$LOGIN" <<<"$out" && ok "agent stamped" || bad "no agent stamp" "$out"
mkfabric
out="$(run --model vendor/override --version 2>&1)"
grep -q "ORI-ENV:AGENT_FABRIC_LAUNCH_SESSION_MODEL=vendor/override" <<<"$out" && ok "a caller's --model is what gets stamped" || bad "stamp disagrees with argv" "$out"
grep -q "ORI-EXECCED:claude --model vendor/override --version" <<<"$out" && ! grep -q -- "--model anthropic/claude-sonnet-5" <<<"$out" && ok "…and the launcher's own --model is omitted, so the child sees one" || bad "two --model flags reached the child" "$out"
mkfabric
out="$(run --print --model=vendor/override2 2>&1)"
grep -q "overridden by --model on the command line: vendor/override2" <<<"$out" && ok "--print shows the override" || bad "--print hides the override" "$out"
mkfabric
out="$(run -p hi 2>&1)"
grep -q "ORI-EXECCED:claude --model anthropic/claude-sonnet-5 -p hi" <<<"$out" && ok "-p passes through to claude untouched" || bad "-p swallowed by the launcher" "$out"

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
out="$(env -i PATH="$PATH" HOME="$HOME" GZAPP_LAUNCH_SESSION_MODEL=vendor/s GZAPP_LAUNCH_PROFILE=r/i bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'session : vendor/s' <<<"$out" && ok "the gzapp-era stamp name is still read during the transition" || bad "old stamp ignored" "$out"
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
