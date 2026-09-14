#!/usr/bin/env bash
# runtime/provisioning/secrets/test_fabric-secrets.sh
#
# Behavioural tests for fabric-secrets against a stub `doppler` on PATH that
# answers from a fixture file. Everything happens in a sandbox HOME; git's
# --global config lands there too (HOME is what git reads). Nothing here
# needs Doppler, root, or a real account.
#
# Exit codes: 0 all assertions passed, 1 otherwise.
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/fabric-secrets"
[[ -f "$UNDER_TEST" ]] || { echo "test: $UNDER_TEST not found" >&2; exit 1; }

failures=0
SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
# Only the sandbox bin and the system dirs: a real doppler in ~/.local/bin must
# never be reached by this suite.
export PATH="$BIN:/usr/bin:/bin"
export AGENT_FABRIC_SECRETS_PROJECT="fixture-project"
unset AGENT_FABRIC_SECRETS_CONFIG
ME="$(id -un)"
FIXTURE="$SANDBOX/secrets.json"
DOPPLER_LOG="$SANDBOX/doppler.log"

# The stub: records argv, serves the fixture. `secrets download` returns the
# flat name->value object the real CLI does; `secrets --only-names --json`
# the name-keyed object; `configure get token --plain` a token.
cat > "$BIN/doppler" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOPPLER_LOG"
case "\$*" in
  "secrets download --no-file --format json "*) cat "$FIXTURE" ;;
  "secrets --only-names --json "*) python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k:{} for k in d}))' "$FIXTURE" ;;
  "configure get token --plain") echo "dp.st.stub-token-value" ;;
  "configure get enclave.config --plain --scope /") printf '%s' "\${STUB_CONFIG:-}" ;;
  *) echo "stub: unexpected: \$*" >&2; exit 9 ;;
esac
STUB
chmod +x "$BIN/doppler"

fixture() {  # fixture <login> [omit-name...]
  python3 - "$FIXTURE" "$@" <<'PY'
import json, sys
out, login, omit = sys.argv[1], sys.argv[2], set(sys.argv[3:])
d = {"AGENT_LOGIN": login, "AGENT_HOST": "fixture-host",
     "OPENROUTER_API_KEY": "sk-or-FIXTURE-OPENROUTER", "GH_TOKEN": "ghp_FIXTUREGH",
     "CLAUDE_BRIDGE_AUTH_TOKEN": "bridge-FIXTURE with 'quote' and $dollar",
     "GIT_USER_NAME": "Fixture Person", "GIT_USER_EMAIL": "fixture@example.invalid",
     "GIT_SIGNING_KEY": "0123456789ABCDEF0123456789ABCDEF01234567", "GIT_GPG_PROGRAM": "/usr/bin/gpg",
     # Deliberately NOT shaped like a real key: GitHub secret scanning
     # flags the BEGIN/END armour even around fixture text (alert on cdac5d2).
     "SSH_PRIVATE_KEY": "fixture-private-key-material FIXTUREKEYMATERIAL (not a key)",
     "SSH_PUBLIC_KEY": "ssh-ed25519 AAAAFIXTURE fixture",
     "DOPPLER_PROJECT": "fixture-project", "DOPPLER_CONFIG": login, "DOPPLER_ENVIRONMENT": login}
for k in omit: d.pop(k, None)
json.dump(d, open(out, "w"))
PY
}

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; failures=$((failures+1)); }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || { fail "$1 — expected [$3], got [$2]"; }; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || { fail "$1 — output lacks [$3]"; }; }
assert_lacks() { [[ "$2" != *"$3"* ]] && pass "$1" || { fail "$1 — output CONTAINS [$3]"; }; }

echo "== full sync"
fixture "$ME"
out="$("$UNDER_TEST" sync 2>&1)"; rc=$?
assert_eq "sync exits 0 with every name present" "$rc" "0"
ENV_FILE="$HOME/.config/agent-fabric/secrets.env"
assert_eq "env file mode is 0600" "$(stat -c %a "$ENV_FILE")" "600"
assert_eq "env file exports exactly the three environment names" \
  "$(grep -o '^export [A-Z_]*' "$ENV_FILE" | sed 's/export //' | tr '\n' ' ')" "OPENROUTER_API_KEY GH_TOKEN CLAUDE_BRIDGE_AUTH_TOKEN "
assert_lacks "env file carries no git string" "$(cat "$ENV_FILE")" "Fixture Person"
assert_lacks "env file carries no key material" "$(cat "$ENV_FILE")" "FIXTUREKEYMATERIAL"
sourced="$(bash -c "source '$ENV_FILE'; printf '%s' \"\$CLAUDE_BRIDGE_AUTH_TOKEN\"")"
assert_eq "a value with quotes and a dollar survives sourcing" "$sourced" "bridge-FIXTURE with 'quote' and \$dollar"
assert_eq "bashrc sources the env file once" "$(grep -c 'agent-fabric secrets' "$HOME/.bashrc")" "1"
assert_eq "git user.name applied" "$(git config --global --get user.name)" "Fixture Person"
assert_eq "git signing key applied" "$(git config --global --get user.signingkey)" "0123456789ABCDEF0123456789ABCDEF01234567"
assert_eq "gpg.program applied" "$(git config --global --get gpg.program)" "/usr/bin/gpg"
assert_eq "commit.gpgsign on when a signing key is present" "$(git config --global --get commit.gpgsign)" "true"
assert_eq "ssh private key written 0600" "$(stat -c %a "$HOME/.ssh/id_ed25519")" "600"
assert_eq "ssh public key written" "$(cat "$HOME/.ssh/id_ed25519.pub")" "ssh-ed25519 AAAAFIXTURE fixture"
assert_lacks "sync output prints no value" "$out" "sk-or-FIXTURE"
assert_lacks "sync output prints no token" "$out" "ghp_FIXTUREGH"
assert_contains "doppler was called with the project" "$(cat "$DOPPLER_LOG")" "--project fixture-project"
assert_contains "doppler was called with this login's branch config" "$(cat "$DOPPLER_LOG")" "--config agents_$ME"

echo "== the recorded config wins over the default name"
: > "$DOPPLER_LOG"
STUB_CONFIG="agents2_$ME" "$UNDER_TEST" sync >/dev/null 2>&1
assert_contains "doppler was called with the recorded config" "$(cat "$DOPPLER_LOG")" "--config agents2_$ME"
assert_lacks "and not the default" "$(grep download "$DOPPLER_LOG")" "--config agents_$ME"

echo "== idempotent"
"$UNDER_TEST" sync >/dev/null 2>&1
assert_eq "second sync adds no second bashrc line" "$(grep -c 'agent-fabric secrets' "$HOME/.bashrc")" "1"

echo "== ssh key is not replaced without --force"
echo "LOCAL-KEY" > "$HOME/.ssh/id_ed25519"
out="$("$UNDER_TEST" sync 2>&1)"
assert_eq "existing key kept" "$(cat "$HOME/.ssh/id_ed25519")" "LOCAL-KEY"
assert_contains "and the skip is reported" "$out" "SSH_PRIVATE_KEY (present; --force replaces)"
"$UNDER_TEST" sync --force >/dev/null 2>&1
assert_contains "--force replaces it" "$(cat "$HOME/.ssh/id_ed25519")" "FIXTUREKEYMATERIAL"

echo "== login mismatch"
fixture "someone-else"
before="$(cat "$ENV_FILE")"
out="$("$UNDER_TEST" sync 2>&1)"; rc=$?
assert_eq "a config naming another login is refused (exit 3)" "$rc" "3"
assert_contains "and says why" "$out" "AGENT_LOGIN=someone-else"
assert_eq "nothing was rewritten" "$(cat "$ENV_FILE")" "$before"

echo "== missing names"
fixture "$ME" OPENROUTER_API_KEY GIT_SIGNING_KEY
out="$("$UNDER_TEST" sync 2>&1)"; rc=$?
assert_eq "sync exits 2 when names are missing" "$rc" "2"
assert_contains "missing names are listed" "$out" "missing: OPENROUTER_API_KEY, GIT_SIGNING_KEY"
assert_lacks "the env file no longer exports the missing key" "$(cat "$ENV_FILE")" "OPENROUTER_API_KEY"
assert_contains "the other exports remain" "$(cat "$ENV_FILE")" "export GH_TOKEN="

echo "== status"
fixture "$ME"
out="$("$UNDER_TEST" status 2>&1)"; rc=$?
assert_eq "status exits 0 when all present and applied" "$rc" "0"
assert_contains "status reports the token as configured" "$out" "doppler token: True"
assert_lacks "status prints no value" "$out" "dp.st.stub"
assert_lacks "status prints no secret" "$out" "FIXTURE"
js="$("$UNDER_TEST" status --json 2>&1)"
assert_eq "status --json is JSON with the login" "$(printf '%s' "$js" | python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])')" "$ME"
fixture "$ME" GH_TOKEN
out="$("$UNDER_TEST" status 2>&1)"; rc=$?
assert_eq "status exits 1 when a name is missing in Doppler" "$rc" "1"
assert_contains "and names it" "$out" "missing: GH_TOKEN"

echo "== doppler unavailable"
rm "$BIN/doppler"
out="$("$UNDER_TEST" sync 2>&1)"; rc=$?
assert_eq "no CLI: exit 1" "$rc" "1"
assert_contains "no CLI: says so" "$out" "doppler CLI not on PATH"

echo
if [[ $failures -eq 0 ]]; then echo "test_fabric-secrets: OK — all assertions passed."; exit 0; fi
echo "test_fabric-secrets: $failures assertion(s) FAILED."; exit 1
