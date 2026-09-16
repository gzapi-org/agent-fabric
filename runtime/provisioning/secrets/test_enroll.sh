#!/usr/bin/env bash
# runtime/provisioning/secrets/test_enroll.sh — enroll.sh under failure.
#
# A stateful fake `doppler` on PATH (projects, environments, configs,
# secrets, service tokens, per-account `configure` state) plus fakes for
# sudo, getent, id, gh and ori, all in a sandbox; the account being
# enrolled is this login, seen by enroll.sh as "another account" because
# `id -un` is faked to a coordinator name — so the sudo path, the token
# issue and the store as the account all run. A fault file the fake
# reads makes one call fail, kills the caller mid-call, or takes Doppler
# down after a call — and every case ends with a retry that must finish
# the enrolment without duplicating anything.
#
# The whole path and the failure cases run on BOTH host backends: the
# account on this host (direct), and on a far host behind a fake ssh
# that runs the same worker here and answers as far-host — where
# AGENT_HOST must be what the far host said, prepare-home/gather/retire
# must have gone over ssh, and Doppler and the token value must not.
#
# What this proves: no value reaches a terminal or outlives $TMP, a stop
# at any step leaves the old sources in place, and a re-run converges.
# What it does not: the real CLI's wire behaviour, root, or a real account.
set -uo pipefail
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
UNDER_TEST="$SCRIPT_DIR/enroll.sh"
failures=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1" >&2; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/      /' >&2; failures=$((failures+1)); }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null' EXIT
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
ME="$(id -un)"                                   # the account enrolled (fabric-secrets sees this login via pwd)
HOME_ME="$SANDBOX/home/$ME"                       # its sandbox home
HOME_COORD="$SANDBOX/home/coordinator"
STATE="$SANDBOX/doppler-state.json"
FAULT="$SANDBOX/fault"
LOG="$SANDBOX/doppler.log"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"

# ---- the fake doppler: one JSON state, per-account configure under $HOME/.doppler ----
cat > "$SANDBOX/fake_doppler.py" <<'PY'
import json, os, signal, sys, uuid
STATE, FAULT, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
argv = sys.argv[4:]; joined = " ".join(argv)
open(LOG, "a").write(joined + "\n")
def load():
    try: return json.load(open(STATE))
    except (OSError, ValueError): return {"limit": 10, "environments": [], "configs": {}}
def save(s): json.dump(s, open(STATE, "w"), indent=1)
faults = [l.split(None, 1) for l in open(FAULT).read().splitlines() if l.strip()] if os.path.exists(FAULT) else []
def fault_kind(kind):
    for f in faults:
        if f[0] == kind and (len(f) == 1 or joined.startswith(f[1])): return f
def die(msg): print("Doppler Error: " + msg, file=sys.stderr); sys.exit(1)
if fault_kind("down"): die("unable to reach api.doppler.com")
if fault_kind("fail"): die("injected failure for: " + joined)
if fault_kind("kill"):
    os.kill(os.getppid(), signal.SIGTERM); sys.exit(1)
s = load()
def opt(name):
    return argv[argv.index(name) + 1] if name in argv else None
cfg = opt("--config"); cmd = argv[:2]
if argv[:2] == ["projects", "get"]: print(json.dumps({"name": argv[2]}))
elif argv[:1] == ["configs"] and argv[1:2] != ["create"] and argv[1:2] != ["tokens"]:
    print(json.dumps([{"name": n, "root": False, "environment": c["env"]} for n, c in s["configs"].items()]))
elif argv[:2] == ["environments", "get"]: sys.exit(0 if argv[2] in s["environments"] else 1)
elif argv[:2] == ["environments", "create"]: s["environments"].append(argv[2]); save(s)
elif argv[:2] == ["configs", "create"]:
    name, env = opt("--name"), opt("--environment")
    if sum(1 for c in s["configs"].values() if c["env"] == env) >= s.get("limit", 10): die("You've reached the limit of %d configs per environment" % s.get("limit", 10))
    s["configs"][name] = {"env": env, "secrets": {}, "tokens": []}; save(s)
elif argv[:2] == ["configure", "set"]:
    d = os.path.join(os.environ["HOME"], ".doppler"); os.makedirs(d, exist_ok=True); f = os.path.join(d, "fake.json")
    try: c = json.load(open(f))
    except (OSError, ValueError): c = {}
    rest = [a for a in argv[2:] if not a.startswith("--") and a != "/"]
    if rest[0] == "token": c["token"] = rest[1]
    else:
        for kv in rest: k, v = kv.split("=", 1); c[k] = v
    json.dump(c, open(f, "w"))
elif argv[:2] == ["configure", "get"]:
    try: c = json.load(open(os.path.join(os.environ["HOME"], ".doppler", "fake.json")))
    except (OSError, ValueError): c = {}
    v = c.get(argv[2], ""); print(v, end="" if argv[2] != "token" else "\n")
    if not v: sys.exit(1)
elif argv[:2] == ["secrets", "upload"]:
    if cfg not in s["configs"]: die("config not found")
    s["configs"][cfg]["secrets"].update(json.load(open(argv[2]))); save(s)
elif argv[:2] == ["secrets", "download"]:
    if cfg not in s["configs"]: die("config not found")
    print(json.dumps({**s["configs"][cfg]["secrets"], "DOPPLER_PROJECT": opt("--project"), "DOPPLER_CONFIG": cfg, "DOPPLER_ENVIRONMENT": s["configs"][cfg]["env"]}))
elif argv[:2] == ["secrets", "get"]:
    v = s["configs"].get(cfg, {}).get("secrets", {}).get(argv[2]); print(v or ""); sys.exit(0 if v else 1)
elif argv[:1] == ["secrets"] and "--only-names" in argv:
    if cfg not in s["configs"]: die("config not found")
    print(json.dumps({k: {} for k in s["configs"][cfg]["secrets"]}))
elif argv[:3] == ["configs", "tokens", "create"]:
    t = "dp.st." + uuid.uuid4().hex; s["configs"][cfg]["tokens"].append({"name": argv[3], "token": t}); save(s); print(t)
elif argv[:2] == ["configs", "tokens"]:
    print(json.dumps([{"name": t["name"]} for t in s["configs"][cfg]["tokens"]]))
else: die("fake: unexpected " + joined)
after = fault_kind("down-after")
if after: open(FAULT, "a").write("down\n")
PY
cat > "$BIN/doppler" <<STUB
#!/usr/bin/env bash
exec python3 "$SANDBOX/fake_doppler.py" "$STATE" "$FAULT" "$LOG" "\$@"
STUB
# sudo: drop `-u <login> -H`, keep the fakes reachable through env -i's PATH, run the rest.
cat > "$BIN/sudo" <<STUB
#!/usr/bin/env bash
[[ "\$1" == -n ]] && shift
[[ "\$1" == -u ]] && shift 2; [[ "\$1" == -H ]] && shift
[[ "\$1" == chown ]] && exit 0
# On the fake far host (FAKE_FAR, exported by the fake ssh) the far host's own hostname comes first.
args=(); for a in "\$@"; do [[ "\$a" == PATH=* ]] && a="PATH=$BIN:\${a#PATH=}" && [[ -n "\${FAKE_FAR:-}" ]] && a="PATH=$SANDBOX/farbin:\${a#PATH=}"; args+=("\$a"); done
exec "\${args[@]}"
STUB
cat > "$BIN/getent" <<STUB
#!/usr/bin/env bash
[[ "\$1" == passwd && "\$2" == "$ME" ]] && { echo "$ME:x:1000:1000::$HOME_ME:/bin/bash"; exit 0; }
[[ "\$1" == passwd && "\$2" == coordinator ]] && { echo "coordinator:x:1001:1001::$HOME_COORD:/bin/bash"; exit 0; }
exit 2
STUB
cat > "$BIN/id" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == "-un" ]] && { echo coordinator; exit 0; }
exec /usr/bin/id "$@"
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "auth token") [[ -f "$HOME/.config/gh/hosts.yml" ]] && { echo "ghp_FROMKEYRING"; exit 0; } || exit 1 ;;
  "auth status") [[ -n "${GH_TOKEN:-}" ]] ;;
  "auth status --hostname github.com") [[ -f "$HOME/.config/gh/hosts.yml" ]] && echo "logged in via hosts.yml" ;;
  "auth logout --hostname github.com") rm -f "$HOME/.config/gh/hosts.yml" ;;
  *) exit 9 ;;
esac
STUB
cat > "$BIN/ori" <<'STUB'
#!/usr/bin/env bash
[[ -n "${OPENROUTER_API_KEY:-}" ]] && echo '{"authenticated": true, "source": {"kind": "environment"}}' || echo '{"authenticated": false}'
STUB
chmod +x "$BIN"/*
export PATH="$BIN:/usr/bin:/bin"
export HOME="$HOME_COORD"; mkdir -p "$HOME_COORD"
export SUDO="$BIN/sudo" DOPPLER_BIN="$BIN/doppler" AGENT_FABRIC_SECRETS_PROJECT=fixture-project
# The host registry: this host (direct) and a far one behind a fake ssh
# that runs the same worker here, answering as far-host. The suite runs
# on both; on the far one AGENT_HOST must be what the far host said.
LOCAL="$(hostname -s)"; REG="$SANDBOX/hosts.json"
cat > "$REG" <<EOF
{"version": 1,
 "hosts": {"$LOCAL": {"platform": "fedora-qubes", "ssh": null, "operator": "coordinator", "fabric": "$ROOT"},
           "far-host": {"platform": "debian", "ssh": "op@far.example", "operator": "op", "fabric": "$ROOT"}},
 "placement": {"coordinator": "$LOCAL"}}
EOF
mkdir -p "$SANDBOX/farbin"; printf '#!/usr/bin/env bash\n[[ "$1" == -s ]] && { echo far-host; exit 0; }; exec /usr/bin/hostname "$@"\n' > "$SANDBOX/farbin/hostname"; chmod +x "$SANDBOX/farbin/hostname"
SSHLOG="$SANDBOX/ssh.log"
cat > "$BIN/ssh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSHLOG"; args=("\$@"); FAKE_FAR=1 PATH="$SANDBOX/farbin:\$PATH" exec bash -c "\${args[-1]}"
STUB
chmod +x "$BIN/ssh"
export AGENT_FABRIC_HOSTS_REGISTRY="$REG" SSH="$BIN/ssh"
BACKEND=local; EXPECT_HOST="$LOCAL"
export AGENT_FABRIC_SECRETS_TEMPLATE="$SANDBOX/template.env" AGENT_FABRIC_RELAY_TOKEN_FILE="$SANDBOX/bridge-token"
printf 'GIT_USER_NAME=Fixture Person\nGIT_USER_EMAIL=fixture@example.invalid\nGIT_SIGNING_KEY=0123456789ABCDEF0123456789ABCDEF01234567\nGIT_GPG_PROGRAM=/usr/bin/gpg\n' > "$SANDBOX/template.env"
printf 'bridge-FIXTURE-TOKEN\n' > "$SANDBOX/bridge-token"

reset_account() {  # the account as provisioning leaves it: old sources present, nothing enrolled
  rm -rf "$HOME_ME" "$STATE" "$FAULT" "$LOG"; mkdir -p "$HOME_ME/projects/demo/.claude" "$HOME_ME/.ssh" "$HOME_ME/.config/gh"
  ln -s "$ROOT" "$HOME_ME/projects/agent-fabric"
  printf 'export OPENROUTER_API_KEY=sk-or-OLD-FROM-BASHRC\n' > "$HOME_ME/.bashrc"
  printf '. ~/.bashrc\n' > "$HOME_ME/.bash_profile"
  printf '{"env": {"CLAUDE_BRIDGE_AUTH_TOKEN": "bridge-FROM-SETTINGS"}, "permissions": {}}\n' > "$HOME_ME/projects/demo/.claude/settings.local.json"
  printf 'fixture-private-key-material NOTAKEY\n' > "$HOME_ME/.ssh/id_ed25519"; printf 'ssh-ed25519 AAAAFIXTURE fixture\n' > "$HOME_ME/.ssh/id_ed25519.pub"; chmod 600 "$HOME_ME/.ssh/id_ed25519"
  printf 'github.com:\n  user: fixture\n' > "$HOME_ME/.config/gh/hosts.yml"
}
enrol() { local h=(); [[ "$BACKEND" == ssh ]] && h=(--host far-host); bash "$UNDER_TEST" "$@" "${h[@]}" "$ME" 2>&1; }
state() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"s": s}))' "$STATE" "$1" 2>/dev/null; }
no_values_leaked() {  # $1 = output; nothing from the sources may appear anywhere but Doppler
  ! grep -q "sk-or-OLD-FROM-BASHRC\|bridge-FROM-SETTINGS\|ghp_FROMKEYRING\|NOTAKEY\|dp\.st\." <<<"$1"
}
tmp_is_empty() { [[ -z "$(ls -A "$TMPDIR" 2>/dev/null)" ]]; }
fully_enrolled() {  # the state a successful enrolment leaves
  [[ "$(state 'sorted(s["configs"])')" == "['agents_$ME']" ]] || return 1
  [[ "$(state 'sorted(s["configs"]["agents_'"$ME"'"]["secrets"])')" == "['AGENT_HOST', 'AGENT_LOGIN', 'CLAUDE_BRIDGE_AUTH_TOKEN', 'GH_TOKEN', 'GIT_GPG_PROGRAM', 'GIT_SIGNING_KEY', 'GIT_USER_EMAIL', 'GIT_USER_NAME', 'OPENROUTER_API_KEY', 'SSH_PRIVATE_KEY', 'SSH_PUBLIC_KEY']" ]] || return 1
  [[ "$(state 'len(s["configs"]["agents_'"$ME"'"]["tokens"])')" -ge 1 ]] || return 1
  [[ "$(state 's["configs"]["agents_'"$ME"'"]["secrets"]["AGENT_HOST"]')" == "$EXPECT_HOST" ]] || { echo "AGENT_HOST is not what the host said ($EXPECT_HOST)"; return 1; }
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["token"].startswith("dp.st.") and c["enclave.config"]=="agents_"+sys.argv[2]' "$HOME_ME/.doppler/fake.json" "$ME" || return 1
  [[ -f "$HOME_ME/.config/agent-fabric/secrets.env" && "$(stat -c %a "$HOME_ME/.config/agent-fabric/secrets.env")" == 600 ]] || return 1
  ! grep -q OPENROUTER_API_KEY "$HOME_ME/.bashrc" || return 1                        # the export retired
  ! grep -q CLAUDE_BRIDGE_AUTH_TOKEN "$HOME_ME/projects/demo/.claude/settings.local.json" || return 1
  [[ ! -f "$HOME_ME/.config/gh/hosts.yml" ]] || return 1                             # the keyring login retired
  tmp_is_empty
}

for BACKEND in local ssh; do
[[ "$BACKEND" == ssh ]] && EXPECT_HOST=far-host; : > "$SSHLOG"
echo "enroll [$BACKEND]: the whole path, then again"
reset_account
out="$(enrol)"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit $rc" "$out"
fully_enrolled && ok "config, secrets, token stored, config recorded, env file 0600, old sources retired, \$TMP gone" || bad "not fully enrolled" "$out
$(cat "$STATE" 2>/dev/null)"
no_values_leaked "$out" && ok "no value on the terminal" || bad "a value reached the terminal" "$out"
if [[ "$BACKEND" == ssh ]]; then
  grep -q "enroll-worker.sh prepare-home $ME" "$SSHLOG" && grep -q -- "--as $ME -- @fabric/runtime/provisioning/secrets/enroll-worker.sh gather $ME" "$SSHLOG" \
    && grep -q -- "--as $ME -- @fabric/runtime/provisioning/secrets/enroll-worker.sh retire $ME" "$SSHLOG" && ok "ssh: prepare-home as the operator, gather and retire as the account, on the far host" || bad "ssh worker calls" "$(cat "$SSHLOG")"
  ! grep -q "doppler secrets upload\|configs tokens create\|fill-from" "$SSHLOG" && ok "…and Doppler never left the coordinator" || bad "Doppler went over ssh" "$(cat "$SSHLOG")"
  ! grep -q "dp\.st\." "$SSHLOG" && ok "…and the token went over stdin, never in argv" || bad "token in ssh argv" "$(cat "$SSHLOG")"
else
  [[ ! -s "$SSHLOG" ]] && ok "local: ssh never called" || bad "ssh called on the local backend" "$(cat "$SSHLOG")"
fi
out="$(enrol)"
grep -q "already issued" <<<"$out" && grep -q "(nothing new)" <<<"$out" && [[ "$(state 'len(s["configs"]["agents_'"$ME"'"]["tokens"])')" == 1 ]] \
  && fully_enrolled && ok "a second run changes nothing: one config, one token, nothing re-uploaded" || bad "the re-run was not idempotent" "$out"

echo "enroll: killed between gather and upload"
reset_account; printf 'kill secrets upload\n' > "$FAULT"
out="$(enrol)"; rc=$?
[[ $rc -ne 0 ]] && ok "the run ended ($rc)" || bad "survived its own kill" "$out"
tmp_is_empty && ok "the gathered values did not outlive \$TMP" || bad "a temporary with values remains" "$(ls -laR "$TMPDIR")"
[[ "$(state 'sorted(s["configs"]["agents_'"$ME"'"]["secrets"])')" == "[]" ]] && ok "the config exists and holds nothing" || bad "secrets uploaded before the kill?" "$(cat "$STATE")"
grep -q "OPENROUTER_API_KEY" "$HOME_ME/.bashrc" && ok "old sources untouched" || bad "old sources retired without a sync"
rm -f "$FAULT"; out="$(enrol)"
fully_enrolled && no_values_leaked "$out" && ok "the retry completes the enrolment" || bad "retry did not converge" "$out"

echo "enroll: Doppler goes down right after the config is created"
reset_account; printf 'down-after configs create\n' > "$FAULT"
out="$(enrol)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "upload failed" <<<"$out" && ok "stops at the upload and says so" || bad "did not stop" "$out"
tmp_is_empty && grep -q OPENROUTER_API_KEY "$HOME_ME/.bashrc" && ok "nothing left in \$TMP, old sources kept" || bad "partial state left" "$(ls -A "$TMPDIR")"
rm -f "$FAULT"; out="$(enrol)"
fully_enrolled && [[ "$(state 'len(s["configs"])')" == 1 ]] && ok "the retry reuses the config it had created" || bad "retry duplicated or failed" "$out"

echo "enroll: the token is issued but the store as the account fails"
reset_account; printf 'fail configure set token\n' > "$FAULT"
out="$(enrol)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "could not issue or store" <<<"$out" && ok "stops at the store" || bad "did not stop" "$out"
[[ "$(state 'len(s["configs"]["agents_'"$ME"'"]["tokens"])')" == 1 ]] && [[ ! -f "$HOME_ME/.doppler/fake.json" || -z "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token",""))' "$HOME_ME/.doppler/fake.json" 2>/dev/null)" ]] \
  && ok "a token exists at Doppler that the account never received" || bad "unexpected token state" "$(cat "$STATE")"
rm -f "$FAULT"; out="$(enrol)"
grep -q "exists but the account holds none" <<<"$out" && grep -q "issuing another" <<<"$out" && fully_enrolled \
  && [[ "$(state 'len(s["configs"]["agents_'"$ME"'"]["tokens"])')" == 2 ]] && ok "the retry sees the gap, issues another and names the unused one" || bad "the partially issued token was taken as done" "$out"

echo "enroll: the upload itself fails once"
reset_account; printf 'fail secrets upload\n' > "$FAULT"
out="$(enrol)"; rc=$?
[[ $rc -ne 0 ]] && tmp_is_empty && grep -q OPENROUTER_API_KEY "$HOME_ME/.bashrc" && ok "stops, cleans \$TMP, keeps the old sources" || bad "upload failure mishandled" "$out"
rm -f "$FAULT"; out="$(enrol)"; fully_enrolled && ok "the retry completes" || bad "retry failed" "$out"

done
BACKEND=local; EXPECT_HOST="$LOCAL"

echo "enroll: no temporary directory can be made (a full or read-only \$TMPDIR)"
reset_account; chmod 500 "$TMPDIR"
out="$(enrol)"; rc=$?; chmod 700 "$TMPDIR"
[[ $rc -eq 1 ]] && grep -q "cannot create a temporary directory" <<<"$out" && grep -q "nothing done" <<<"$out" && ok "refuses before touching anything" || bad "ran without a temp dir" "$out"
[[ ! -f "$STATE" ]] && ok "no config was created" || bad "a config was created without a temp dir" "$(cat "$STATE")"

echo "enroll: a full environment spills to the next"
reset_account; printf '{"limit": 1, "environments": ["agents"], "configs": {"agents_other": {"env": "agents", "secrets": {}, "tokens": []}}}\n' > "$STATE"
out="$(enrol)"
[[ "$(state 'sorted(s["configs"])')" == "['agents2_$ME', 'agents_other']" ]] && grep -q "environment agents is full" <<<"$out" \
  && [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["enclave.config"])' "$HOME_ME/.doppler/fake.json")" == "agents2_$ME" ]] \
  && ok "agents2_<login>, recorded as the account's own" || bad "spill to the next environment failed" "$out
$(cat "$STATE")"

echo "enroll: issue-openrouter-keys — the key is minted, then the Doppler write fails"
# A fake OpenRouter keys API: POST mints, DELETE records the hash it was asked to remove.
cat > "$SANDBOX/fake_or.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log = sys.argv[2]
class H(BaseHTTPRequestHandler):
    n = 0
    def log_message(self, *a): pass
    def do_POST(self):
        H.n += 1; body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open(log, "a").write(f"POST {self.path} {body['name']}\n")
        out = json.dumps({"key": f"sk-or-MINTED-{H.n}", "data": {"hash": f"hash{H.n}", "name": body["name"]}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_DELETE(self):
        open(log, "a").write(f"DELETE {self.path}\n"); self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$(( 20000 + RANDOM % 20000 )); ORLOG="$SANDBOX/or.log"
python3 "$SANDBOX/fake_or.py" "$PORT" "$ORLOG" & SERVER_PID=$!
for _ in $(seq 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.2)" 2>/dev/null && break; sleep 0.1; done
export OPENROUTER_API_BASE="http://127.0.0.1:$PORT"
reset_account; enrol >/dev/null                                       # the account enrolled, and the coordinator's own config with the provisioning key
python3 - "$STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["configs"]["agents_coordinator"] = {"env": "agents", "secrets": {"OPENROUTER_PROVISIONING_KEY": "sk-or-v1-PROV"}, "tokens": []}; json.dump(s, open(sys.argv[1], "w"))
PY
printf 'fail secrets upload\n' > "$FAULT"
out="$(bash "$UNDER_TEST" issue-openrouter-keys "$ME" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "the key just minted was deleted at OpenRouter" <<<"$out" && ok "says the write failed and that the key was removed" || bad "orphaned key not handled" "$out"
grep -q "^POST /keys $ME$" "$ORLOG" && grep -q "^DELETE /keys/hash1$" "$ORLOG" && ok "…and the API saw the DELETE for the hash it minted" || bad "no DELETE reached the API" "$(cat "$ORLOG")"
! grep -q "sk-or-MINTED" <<<"$out" && tmp_is_empty && ok "the key value never reached the terminal or outlived \$TMP" || bad "key leaked" "$out"
rm -f "$FAULT"; out="$(bash "$UNDER_TEST" issue-openrouter-keys "$ME" 2>&1)"
[[ "$(state 's["configs"]["agents_'"$ME"'"]["secrets"]["OPENROUTER_API_KEY"]')" == "sk-or-MINTED-2" ]] && ! grep -q "sk-or-MINTED" <<<"$out" \
  && ok "the retry mints a fresh key and stores it" || bad "retry did not store the key" "$out"

echo
if (( failures )); then echo "test_enroll: $failures assertion(s) FAILED"; exit 1; fi
echo "test_enroll: all assertions passed"
