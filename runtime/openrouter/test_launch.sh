#!/usr/bin/env bash
# tools/launch/test_ori.sh
#
# Behavioural tests for tools/launch/ori. The launcher execs a session, so
# the tests run it in SANDBOXES: a fake repo root (registry + instance
# state), a fake `ori` on PATH, and HOME pointed at a scratch dir. Every
# refusal, the merge order, and the review_grade gate are exercised without
# spawning a real claude.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$HERE/ori"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' | head -6; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
mkdir -p "$SANDBOX/bin"
PATH_EXPORT="$SANDBOX/bin:$PATH"

# A fake ori whose auth --json reports environment-sourced auth and which
# records its argv when claude is called.
cat > "$SANDBOX/bin/ori" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == auth ]]; then
    echo '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'
    exit 0
fi
echo "ORI-EXECCED:$*"
# The child's ENVIRONMENT, not only its argv: a pin that lost its `export`
# would still print under --print and still be absent here.
for v in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL GZAPP_LAUNCH_SESSION_MODEL GZAPP_LAUNCH_PROFILE; do
    echo "ORI-ENV:$v=${!v:-}"
done
FAKE
chmod +x "$SANDBOX/bin/ori"

# A fixture repo root: registry copied from the real one, a state file, no
# local override. $REPO is re-created per case.
mkrepo() {
    rm -rf "$SANDBOX/repo"; mkdir -p "$SANDBOX/repo/.roles/registry" "$SANDBOX/repo/.roles/schema" "$SANDBOX/repo/.roles/.instance"
    cp "$HERE/../../.roles/registry/model-profiles.json" "$SANDBOX/repo/.roles/registry/" 2>/dev/null || {
        printf '{"version":1,"review_grade":["anthropic/claude-opus-5"],"defaults":{"session":"anthropic/claude-sonnet-5","tiers":{"haiku":"anthropic/claude-haiku-4.5","sonnet":"anthropic/claude-sonnet-5","opus":"anthropic/claude-opus-5","fable":"anthropic/claude-fable-5.1"}},"roles":{},"instances":{}}\n' > "$SANDBOX/repo/.roles/registry/model-profiles.json"
    }
    # The schema: the launcher validates every merged model against its
    # model_id pattern, so the fixture carries the real file.
    cp "$HERE/../../.roles/schema/model-profiles.schema.json" "$SANDBOX/repo/.roles/schema/"
    printf '%s\n' '{"role":"backend-dev","dir_basename":"backend-dev-02"}' > "$SANDBOX/repo/.roles/.instance/state.json"
    # A real toplevel, like production: the launcher derives its root from
    # the launch directory and nothing else (no REPO_ROOT override), and a
    # TMPDIR inside some git work tree must not resolve to that tree.
    git init -q "$SANDBOX/repo"
}
run() { (cd "$SANDBOX/repo" && HOME="$HOME" PATH="$PATH_EXPORT" bash "$LAUNCHER" "$@"); }
run_err() { run "$@" >/dev/null 2>&1; }

echo "ori-launch: --print resolves defaults for a role with no row"
mkrepo
out="$(run --print)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0" || bad "rc=$rc" "$out"
grep -q "session : anthropic/claude-sonnet-5" <<<"$out" && ok "default session" || bad "session wrong" "$out"
grep -q "opus    : anthropic/claude-opus-5" <<<"$out" && ok "default opus (in review_grade)" || bad "opus wrong" "$out"

echo "ori-launch: role and instance rows override defaults, later wins"
mkrepo
python3 - "$SANDBOX/repo/.roles/registry/model-profiles.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["roles"]["backend-dev"] = {"tiers": {"haiku": "vendor/cheap-haiku", "opus": "anthropic/claude-opus-5"}}
d["instances"]["backend-dev-02"] = {"tiers": {"sonnet": "vendor/special-sonnet"}, "session": "vendor/instance-session"}
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY
out="$(run --print)"
grep -q "haiku   : vendor/cheap-haiku" <<<"$out" && ok "role row wins over defaults" || bad "role row ignored" "$out"
grep -q "sonnet  : vendor/special-sonnet" <<<"$out" && ok "instance row wins over role" || bad "instance row ignored" "$out"
grep -q "session : vendor/instance-session" <<<"$out" && ok "session override carried" || bad "session ignored" "$out"

echo "ori-launch: a gitignored local override layer applies, and is checked"
mkrepo
mkdir -p "$SANDBOX/repo/.roles/.instance"
printf '%s\n' '{"tiers":{"opus":"vendor/cheap-opus"}}' > "$SANDBOX/repo/.roles/.instance/model-profile.local.json"
run_err --print
[[ $? -ne 0 ]] && ok "a cheap-opus local override is REFUSED" || bad "review_grade bypassed by local override"

echo "ori-launch: the refusals"
mkrepo; rm "$SANDBOX/repo/.roles/.instance/state.json"
run_err --print
[[ $? -eq 1 ]] && ok "no state file: refused" || bad "ran without a role"
mkrepo; rm "$SANDBOX/repo/.roles/registry/model-profiles.json"
run_err --print
[[ $? -eq 1 ]] && ok "no registry: refused" || bad "ran without a registry"
mkrepo
out="$(run --settings foo.json)"; [[ $? -ne 0 ]] && ok "--settings passthrough refused" || bad "fence bypass allowed" "$out"
mkrepo; run_err --setting-sources user,project
[[ $? -ne 0 ]] && ok "--setting-sources passthrough refused" || bad "fence bypass allowed"
mkrepo
mkdir -p "$HOME/.claude"
printf '%s\n' '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"vendor/sneaky"}}' > "$HOME/.claude/settings.json"
run_err --print; [[ $? -eq 1 ]] && ok "user-scope ANTHROPIC_DEFAULT pin: refused" || bad "would race the profile"
rm -f "$HOME/.claude/settings.json"

# EVERY settings scope is fenced, not only ~/.claude/settings.json (review
# on PR #679, judged CONFIRMED: a pin in the gitignored local scope was
# seen by neither the committed guard nor the launcher). And the refusal
# names the file and the key.
pin_in() {  # pin_in <file> <json>
    mkrepo; mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
    # A fixture that did not land is a vacuous case, not a pass: one of
    # these once wrote into a directory mkrepo had just deleted, the
    # redirection failed, and the assertion passed against no file at all
    # (review on PR #679, judged CONFIRMED).
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
mkdir -p "$SANDBOX/cfgdir"; mkrepo; printf '%s\n' '{"env":{"ANTHROPIC_MODEL":"vendor/sneaky"}}' > "$SANDBOX/cfgdir/settings.json"
out="$(CLAUDE_CONFIG_DIR="$SANDBOX/cfgdir" run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && ok "CLAUDE_CONFIG_DIR scope, ANTHROPIC_MODEL (not only _DEFAULT_): refused" || bad "config-dir scope unfenced" "$out"
rm -rf "$SANDBOX/cfgdir"
pin_in "$SANDBOX/repo/.claude/settings.local.json" '{"env":{"CLAUDE_BRIDGE_AUTH_TOKEN":"not-a-pin"},"model":"opus"}'
[[ $rc -eq 0 ]] && ok "a non-pin env entry and a top-level model preference are not refused" || bad "over-fenced" "$out"
mkrepo
out="$(CLAUDE_CODE_SUBAGENT_MODEL=vendor/sneaky run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && ok "CLAUDE_CODE_SUBAGENT_MODEL in the caller's environment: refused" || bad "process-env subagent pin rides through" "$out"
# The root is the LAUNCH directory, never an inherited REPO_ROOT: the fence
# must inspect the clone the child will start in (review on PR #679, judged
# CONFIRMED: REPO_ROOT at a clean clone passed the fence on it and exec'd in
# the pinned one).
mkrepo; rm -rf "$SANDBOX/other"; cp -r "$SANDBOX/repo" "$SANDBOX/other"
mkdir -p "$SANDBOX/repo/.claude"; printf '%s\n' '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"vendor/sneaky"}}' > "$SANDBOX/repo/.claude/settings.local.json"
[[ -s "$SANDBOX/repo/.claude/settings.local.json" ]] || bad "fixture not written"
out="$(REPO_ROOT="$SANDBOX/other" run --print 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "repo/.claude/settings.local.json carries model pins" <<<"$out" && ok "an inherited REPO_ROOT does not move the fence off the launch directory" || bad "inherited REPO_ROOT bypassed the cwd clone's pin" "$out"
# …and the PROFILE is this clone's too — the fence has a second layer ($PWD
# is scanned as well), so the root derivation is pinned by the label.
rm -f "$SANDBOX/repo/.claude/settings.local.json"
printf '%s\n' '{"role":"web-dev","dir_basename":"other-clone"}' > "$SANDBOX/other/.roles/.instance/state.json"
out="$(REPO_ROOT="$SANDBOX/other" run --print 2>&1)"; rc=$?
grep -q "resolved profile for backend-dev/backend-dev-02" <<<"$out" && ok "…and the profile is resolved from the launch clone, not the inherited root" || bad "profile read from the inherited REPO_ROOT" "$out"
rm -rf "$SANDBOX/other"

# A malformed LOCAL override is refused, not exported as "None" (review on
# PR #679, judged CONFIRMED: null printed as the string None, passed the
# emptiness check, reached --model).
override() { mkrepo; printf '%s\n' "$1" > "$SANDBOX/repo/.roles/.instance/model-profile.local.json"; out="$(run --print 2>&1)"; rc=$?; }
override '{"session": null}'
[[ $rc -eq 1 ]] && grep -q "session is None" <<<"$out" && ok "session: null refused, named" || bad "None session accepted" "$out"
override '{"tiers": {"haiku": null}}'
[[ $rc -eq 1 ]] && ok "tiers.haiku: null refused" || bad "None tier accepted" "$out"
override '{"tiers": {"haiku": "Not A Model"}}'
[[ $rc -eq 1 ]] && ok "a tier that is not a model id refused" || bad "prose tier accepted" "$out"
override '{"tiers": {"haiku": ""}}'
[[ $rc -eq 1 ]] && ok "an empty tier refused (ori would silently substitute its own default)" || bad "empty tier accepted" "$out"
override '{"tiers": null}'
[[ $rc -eq 1 ]] && grep -q "tiers is None" <<<"$out" && ok "tiers: null refused, named" || bad "null tiers misreported" "$out"
override '{"session": "anthropic/claude-opus-5:floor[1m]", "tiers": {"fable": "@preset/reviewer"}}'
[[ $rc -eq 0 ]] && ok "variant, [1m] and @preset spellings accepted" || bad "valid ids refused" "$out"
# The pattern must consume the WHOLE value: re.match with a trailing $
# accepts "vendor/model\n" (the $ matches before a final newline).
override '{"session": "vendor/model\n"}'
[[ $rc -eq 1 ]] && grep -q "session is 'vendor/model\\\\n'" <<<"$out" && ok "a trailing newline is not a model id" || bad "regex stopped before the newline" "$out"

# --print anywhere in the arguments, not only first.
mkrepo
out="$(run --verbose --print 2>&1)"; rc=$?
grep -q "resolved profile" <<<"$out" && ! grep -q "ORI-EXECCED" <<<"$out" && ok "--print after another flag still prints, never execs" || bad "--print passed through to claude" "$out"

# Auth is a CONJUNCTION — authenticated AND source.kind == environment —
# and ori's exit status counts (review on PR #679, judged CONFIRMED: the
# OR admitted an unauthenticated env key, an authenticated `ori login`
# credential, and a refusal message that merely contained "environment").
fake_auth() { printf '#!/usr/bin/env bash\necho %q\nexit %s\n' "$1" "${2:-0}" > "$SANDBOX/bin/ori"; chmod +x "$SANDBOX/bin/ori"; }
mkrepo; fake_auth '{"ok":false,"data":{"authenticated":false}}' 1
run_err --print; [[ $? -eq 1 ]] && ok "unauthenticated ori: refused" || bad "would exec into a prompt"
mkrepo; fake_auth '{"ok":true,"data":{"authenticated":false,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'
run_err --print; [[ $? -eq 1 ]] && ok "unauthenticated but environment-sourced: refused" || bad "OR admitted an unauthenticated env key"
mkrepo; fake_auth '{"ok":true,"data":{"authenticated":true,"source":{"kind":"workspace"}}}'
run_err --print; [[ $? -eq 1 ]] && ok "authenticated from a stored credential: refused" || bad "non-environment source admitted"
mkrepo; fake_auth '{"ok":false,"error":"set OPENROUTER_API_KEY in the environment"}'
run_err --print; [[ $? -eq 1 ]] && ok "a refusal message containing the word environment: refused" || bad "substring match on the message"
mkrepo; fake_auth '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment"}}}' 3
run_err --print; [[ $? -eq 1 ]] && ok "ori auth exit status is kept" || bad "non-zero ori auth ignored"

# restore the authed fake before the exec case
cat > "$SANDBOX/bin/ori" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == auth ]]; then
    echo '{"ok":true,"data":{"authenticated":true,"source":{"kind":"environment","location":"OPENROUTER_API_KEY"}}}'
    exit 0
fi
echo "ORI-EXECCED:$*"
# The child's ENVIRONMENT, not only its argv: a pin that lost its `export`
# would still print under --print and still be absent here.
for v in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL GZAPP_LAUNCH_SESSION_MODEL GZAPP_LAUNCH_PROFILE; do
    echo "ORI-ENV:$v=${!v:-}"
done
FAKE
chmod +x "$SANDBOX/bin/ori"

echo "ori-launch: the exec carries the pins to the child"
mkrepo
out="$(run --version 2>&1)"; rc=$?
grep -q "ORI-EXECCED:" <<<"$out" && ok "execs via ori claude" || bad "no exec" "$out"
grep -q -- "--model anthropic/claude-sonnet-5" <<<"$out" && ok "session model passed as --model" || bad "session missing" "$out"
for v in HAIKU SONNET OPUS FABLE; do
    grep -qE "ORI-ENV:ANTHROPIC_DEFAULT_${v}_MODEL=.+" <<<"$out" && ok "$v pin is in the child's environment" || bad "$v pin not exported" "$out"
done
grep -q "ORI-ENV:GZAPP_LAUNCH_SESSION_MODEL=anthropic/claude-sonnet-5" <<<"$out" && ok "session model stamped in the child env" || bad "no session stamp" "$out"
grep -q "ORI-ENV:GZAPP_LAUNCH_PROFILE=backend-dev/backend-dev-02" <<<"$out" && ok "profile stamped" || bad "no profile stamp" "$out"
# 0060: an explicit --model on the command line wins — and the stamp says so.
mkrepo
out="$(run --model vendor/override --version 2>&1)"
grep -q "ORI-ENV:GZAPP_LAUNCH_SESSION_MODEL=vendor/override" <<<"$out" && ok "a caller's --model is what gets stamped" || bad "stamp disagrees with argv" "$out"
grep -q "ORI-EXECCED:claude --model vendor/override --version" <<<"$out" && ! grep -q -- "--model anthropic/claude-sonnet-5" <<<"$out" && ok "…and the launcher's own --model is omitted, so the child sees one" || bad "two --model flags reached the child" "$out"
mkrepo
out="$(run --print --model=vendor/override2 2>&1)"
grep -q "overridden by --model on the command line: vendor/override2" <<<"$out" && ok "--print shows the override" || bad "--print hides the override" "$out"
# claude's -p (headless) is NOT the launcher's --print and passes through.
mkrepo
out="$(run -p hi 2>&1)"
grep -q "ORI-EXECCED:claude --model anthropic/claude-sonnet-5 -p hi" <<<"$out" && ok "-p passes through to claude untouched" || bad "-p swallowed by the launcher" "$out"

echo "model-audit: provider values are allowlisted, never echoed by default"
# The audit's output is written to be pasted into a PR thread; a credential
# in a non-allowlisted ANTHROPIC_* must never appear in it.
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_CUSTOM_HEADERS='Authorization: Bearer test-secret' ANTHROPIC_BASE_URL='https://key-secret@proxy.example/api' ANTHROPIC_DEFAULT_OPUS_MODEL='anthropic/claude-opus-5' bash "$HERE/model-audit.sh" 2>&1)"
! grep -q 'test-secret' <<<"$out" && grep -q 'ANTHROPIC_CUSTOM_HEADERS = <set, ' <<<"$out" && ok "a non-allowlisted provider variable is reported set, not printed" || bad "credential printed in clear" "$out"
! grep -q 'key-secret' <<<"$out" && grep -q 'ANTHROPIC_BASE_URL = https://proxy.example$' <<<"$out" && ok "the base URL prints scheme+host, no userinfo" || bad "base URL userinfo leaked" "$out"
grep -q 'ANTHROPIC_DEFAULT_OPUS_MODEL = anthropic/claude-opus-5' <<<"$out" && ok "an allowlisted pin prints its value" || bad "pin redacted" "$out"
grep -q 'not launched via tools/launch/ori' <<<"$out" && ok "no stamp: says the session model is not visible" || bad "guessed a session model" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='HTTPS://key@proxy.example:8443?api_key=qs-secret#frag-secret' bash "$HERE/model-audit.sh" 2>&1)"
! grep -qE 'key@|qs-secret|frag-secret' <<<"$out" && grep -q 'ANTHROPIC_BASE_URL = https://proxy.example:8443$' <<<"$out" && ok "uppercase scheme, no path, query+fragment: scheme://host:port only" || bad "base URL leaked" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='sk-or-v1-notaurl' bash "$HERE/model-audit.sh" 2>&1)"
! grep -q 'sk-or' <<<"$out" && grep -q 'ANTHROPIC_BASE_URL = <set, 16 chars>' <<<"$out" && ok "a non-URL base value is reported set, never echoed" || bad "non-URL printed" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" GZAPP_LAUNCH_SESSION_MODEL=vendor/s GZAPP_LAUNCH_PROFILE=r/i bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'session : vendor/s' <<<"$out" && grep -q 'profile : r/i' <<<"$out" && ok "the launcher's stamp is reported" || bad "stamp not reported" "$out"
# A newline INSIDE a redacted value must neither forge an allowlisted entry
# nor truncate the count (env is read NUL-delimited).
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_CUSTOM_HEADERS=$'Authorization: Bearer first-secret\nANTHROPIC_MODEL=second-secret' bash "$HERE/model-audit.sh" 2>&1)"
! grep -qE 'first-secret|second-secret' <<<"$out" && grep -q 'ANTHROPIC_CUSTOM_HEADERS = <set, 64 chars>' <<<"$out" && ! grep -q 'ANTHROPIC_MODEL = ' <<<"$out" && ok "a newline inside a redacted value neither splits the entry nor truncates the count" || bad "env entry boundary lost on newline" "$out"
# The provider is classified on the parsed hostname, not a substring.
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='HTTPS://OPENROUTER.AI/api' bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'routed through OpenRouter' <<<"$out" && ok "an uppercase openrouter.ai host classifies as OpenRouter" || bad "host test is case-sensitive" "$out"
out="$(env -i PATH="$PATH" HOME="$HOME" ANTHROPIC_BASE_URL='https://notopenrouter.example/openrouter' bash "$HERE/model-audit.sh" 2>&1)"
grep -q 'does not name OpenRouter' <<<"$out" && ok "a look-alike host with openrouter in the path is not OpenRouter" || bad "host test is a substring match" "$out"

echo
if [[ $FAIL -eq 0 ]]; then
    echo "test_ori: OK — $PASS assertion(s) passed."
else
    echo "test_ori: FAILED — $FAIL assertion(s) failed."; exit 1
fi
