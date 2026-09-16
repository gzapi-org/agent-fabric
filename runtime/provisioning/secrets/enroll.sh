#!/usr/bin/env bash
# runtime/provisioning/secrets/enroll.sh — put an identity's secrets in
# Doppler and hand the account its read-only token. Run by the
# fabric-coordinator (root via sudo; the coordinator's Doppler CLI token
# is the admin credential).
#
#   enroll.sh <login>...      enrol these accounts
#   enroll.sh --all           every account with a ~/projects/agent-fabric
#   enroll.sh sync-all        `fabric-secrets sync` as every enrolled account
#                             (after a rotation in the dashboard)
#   enroll.sh fill-from <login> [<target>...]
#                             copy into each target config (default: every
#                             enrolled login) the names it lacks and <login>'s
#                             config has — never a name already present,
#                             never the identity names, never the
#                             coordinator's own credentials (*_ADMIN_KEY,
#                             *_PROVISIONING_KEY, AGENT_FABRIC_READ_TOKEN),
#                             never a per-login name from the registry's
#                             agent_env (a port offset, OPENAI_API_KEY —
#                             those have their own steps); then sync the
#                             targets. Values stay inside
#                             doppler calls, never on a terminal.
#   enroll.sh issue-openrouter-keys <login>...
#                             give each login an OpenRouter API key of its
#                             own (named after the login, as the existing
#                             keys are) and set it in its
#                             config, replacing a shared one; needs the
#                             coordinator's OpenRouter PROVISIONING key in
#                             the coordinator's own Doppler config as
#                             OPENROUTER_PROVISIONING_KEY (dashboard →
#                             Settings → Provisioning Keys). Key values
#                             go API → doppler, never through a terminal.
#   enroll.sh issue-openai-keys <login>...
#                             give each login an OpenAI API key of its own:
#                             a service account agent-fabric-<login> in
#                             the organisation's project (the only way to
#                             mint a project key programmatically; the key
#                             is returned once), set as OPENAI_API_KEY in
#                             its config. Needs the coordinator's OpenAI
#                             ADMIN key in the coordinator's own config as
#                             OPENAI_ADMIN_KEY (dashboard -> Organization ->
#                             Admin keys) and, with several projects,
#                             OPENAI_PROJECT_ID there too. The Usage API
#                             then reports per api_key_id.
#   enroll.sh set-shared <NAME> <file>
#                             set NAME in EVERY enrolled config to the value
#                             read from <file> (a rotation of a shared
#                             secret such as CLAUDE_BRIDGE_AUTH_TOKEN), then
#                             sync every account. The file is shredded.
#   enroll.sh --dry-run ...   say what would happen; touch nothing
#
# Per login, in order — each step idempotent, none prints a value:
#   1. install the doppler CLI system-wide (once)
#   2. branch config `<env>_<login>` under environment `agents` in project
#      agent-fabric — `agents2`, `agents3`, `agents4` once one holds its ten
#      configs (the Developer plan: four environments of ten configs, so
#      the login is the branch config, never the environment); the name is
#      recorded in the account's doppler config at scope / (enclave.config)
#      so fabric-secrets knows which config is its own
#   3. MIGRATE what the account holds today into that config, gathered as
#      the account into a 0600 temp file that is uploaded and shredded:
#        OPENROUTER_API_KEY        `export` line in ~/.bashrc, or the
#                                  secrets.env of an earlier sync
#        GH_TOKEN                  `gh auth token`
#        CLAUDE_BRIDGE_AUTH_TOKEN  env.* in <clone>/.claude/settings.local.json;
#                                  for the relay host, the runtime dir's bridge-token
#        GIT_*                     git config --global (name, email, signingkey,
#                                  gpg.program) — from the template when unset
#        SSH_PRIVATE_KEY/PUBLIC    ~/.ssh/id_ed25519(.pub)
#        AGENT_LOGIN, AGENT_HOST   the login, this host
#      A name already in Doppler is NOT overwritten (Doppler is the record
#      once enrolled; --remigrate forces the upload).
#   4. a read-only service token on that config, piped straight into the
#      account's ~/.doppler/.doppler.yaml (`doppler configure set token`)
#   5. `fabric-secrets sync` as the account, then verify: ori sees the key
#      from the environment, gh sees GH_TOKEN, git has the signing key
#   6. only after 5: retire the old sources — the ~/.bashrc export line, the
#      settings.local.json entries, the gh hosts.yml login. The synced env
#      file is the one source from here.
#
# Under failure (test_enroll.sh injects each, against a fake doppler): a
# stop at any step leaves the old sources in place and nothing under $TMP;
# a re-run converges — the config it created is reused, names already in
# Doppler are not re-uploaded, a token issued but never stored is noticed
# and another issued; an OpenRouter key minted before a failed Doppler
# write is deleted again. OPENROUTER_API_BASE points the keys API at a
# test server.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
PROJECT="${AGENT_FABRIC_SECRETS_PROJECT:-agent-fabric}"
HOST="${AGENT_FABRIC_HOST:-$(hostname -s)}"
ENVIRONMENT="${AGENT_FABRIC_SECRETS_ENVIRONMENT:-agents}"
DOPPLER_BIN="${DOPPLER_BIN:-/usr/local/bin/doppler}"
TEMPLATE="${AGENT_FABRIC_SECRETS_TEMPLATE:-$HOME/.config/agent-fabric/identity-template.env}"
SUDO="${SUDO:-sudo}"

DRY=0; REMIGRATE=0; MODE=enrol; LOGINS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --remigrate) REMIGRATE=1 ;;
    --all) MODE=all ;;
    sync-all) MODE=sync-all ;;
    fill-from) MODE=fill-from ;;
    set-shared) MODE=set-shared ;;
    issue-openrouter-keys) MODE=issue-openrouter-keys ;;
    issue-openai-keys) MODE=issue-openai-keys ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) echo "enroll: unknown flag $a" >&2; exit 2 ;;
    *) LOGINS+=("$a") ;;
  esac
done

# Progress goes to stderr: several steps run inside $(...) captures.
say() { printf 'enroll: %s\n' "$*" >&2; }
die() { printf 'enroll: %s\n' "$*" >&2; exit 1; }
run() { if (( DRY )); then say "would: $*"; else "$@"; fi; }
# As the account, from its home (the coordinator's cwd is not readable to
# it, and git stats the cwd even for --global). The coordinator's own
# login runs directly — its gh credential sits in the session keyring,
# which a sudo'd shell cannot open.
as_login() {
  local login="$1"; shift
  if [[ "$login" == "$(id -un)" ]]; then "$@"; return; fi
  $SUDO -u "$login" -H env -i HOME="$(home_of "$login")" PATH="/usr/local/bin:/usr/bin:/bin" \
    bash -c 'cd "$HOME" && exec "$@"' -- "$@"
}
home_of() { getent passwd "$1" | cut -d: -f6; }
# The account's own checkout of the fabric: the coordinator's is not
# readable to it.
fabric_secrets_of() {
  if [[ "$1" == "$(id -un)" ]]; then echo "$ROOT/runtime/provisioning/secrets/fabric-secrets"
  else echo "$(home_of "$1")/projects/agent-fabric/runtime/provisioning/secrets/fabric-secrets"; fi
}

all_logins() {
  local h
  # Homes are not readable across accounts; ask root.
  for h in /home/*; do
    $SUDO test -d "$h/projects/agent-fabric" && basename "$h"
  done
}

# ---- 1. the CLI, once -----------------------------------------------------
install_cli() {
  if [[ -x "$DOPPLER_BIN" ]]; then return 0; fi
  local src; src="$(command -v doppler || true)"
  [[ -n "$src" ]] || die "no doppler CLI to install from (command -v doppler)"
  say "installing $src -> $DOPPLER_BIN"
  run $SUDO install -m 755 "$src" "$DOPPLER_BIN"
}

# ---- 2. the config -------------------------------------------------------
existing_config() {  # the config already holding this login, if any
  doppler configs --project "$PROJECT" --json 2>/dev/null | python3 -c '
import json, sys
login = sys.argv[1]
for c in (json.load(sys.stdin) or []):
    if c.get("name", "").endswith("_" + login) and not c.get("root"): print(c["name"]); break' "$1"
}
ensure_config() {
  local login="$1" name; name="$(existing_config "$login")"
  if [[ -n "$name" ]]; then echo "$name"; return 0; fi
  if (( DRY )); then say "would: create branch config ${ENVIRONMENT}_$login (or the next environment's) in $PROJECT"; echo "${ENVIRONMENT}_$login"; return 0; fi
  local env
  for env in "$ENVIRONMENT" "${ENVIRONMENT}2" "${ENVIRONMENT}3" "${ENVIRONMENT}4"; do
    doppler environments get "$env" --project "$PROJECT" >/dev/null 2>&1 \
      || doppler environments create "$env" "$env" --project "$PROJECT" >/dev/null 2>"$TMP/env.err" \
      || die "cannot create environment $env: $(tail -1 "$TMP/env.err")"
    name="${env}_$login"
    if doppler configs create --name "$name" --environment "$env" --project "$PROJECT" >/dev/null 2>"$TMP/cfg.err"; then
      say "created branch config $name"; echo "$name"; return 0
    fi
    grep -q "limit of .* configs" "$TMP/cfg.err" || die "cannot create config $name: $(tail -1 "$TMP/cfg.err")"
    say "environment $env is full; trying the next"
  done
  die "every environment is full; the plan allows four of ten configs"
}
record_config() {  # tell the account which config is its own
  local login="$1" config="$2"
  if (( DRY )); then say "would: record enclave.config=$config for $login"; return 0; fi
  as_login "$login" bash -c 'mkdir -p -m 700 ~/.doppler; doppler configure set "enclave.project=$1" "enclave.config=$2" --scope / --silent' -- "$PROJECT" "$config" \
    || die "$login: could not record the config name"
}

# ---- 3. migrate ----------------------------------------------------------
# Gathers as the account; writes NAME=value lines into $out (0600, owned by
# root). Values never pass through this shell's stdout.
gather() {
  local login="$1" out="$2" home; home="$(home_of "$login")"
  local relay_dir="$home/projects/.gzcoord"
  # The template (git identity strings) is the coordinator's file; its
  # lines travel to the account's python as arguments, never as a path.
  local -a tpl=()
  [[ -r "$TEMPLATE" ]] && mapfile -t tpl < <(grep -E '^[A-Z_]+=' "$TEMPLATE")
  as_login "$login" python3 - "$home" "$relay_dir" "$login" "$HOST" "${tpl[@]}" > "$out" <<'PY'
import glob, json, os, re, shlex, subprocess, sys
home, relay_dir, login, host = sys.argv[1:5]
tpl = dict(a.split("=", 1) for a in sys.argv[5:])
vals = {"AGENT_LOGIN": login, "AGENT_HOST": host}
# OPENROUTER_API_KEY: the .bashrc export line, else the secrets.env of an earlier sync
for f in (os.path.join(home, ".bashrc"), os.path.join(home, ".config", "agent-fabric", "secrets.env")):
    try:
        for line in open(f, encoding="utf-8"):
            m = re.match(r'^\s*export\s+OPENROUTER_API_KEY=(.*?)\s*$', line)
            if m and "OPENROUTER_API_KEY" not in vals:
                vals["OPENROUTER_API_KEY"] = shlex.split(m.group(1))[0]
    except (FileNotFoundError, IndexError, ValueError): pass
clones = [d for d in glob.glob(os.path.join(home, "projects", "*", "")) if not d.rstrip("/").endswith("/agent-fabric")]
clone = clones[0] if clones else ""
# GH_TOKEN from gh
r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
if r.returncode == 0 and r.stdout.strip(): vals["GH_TOKEN"] = r.stdout.strip()
# the bridge token: the clone's settings.local.json, else the relay host's token file
tok = None
if clone:
    try: tok = json.load(open(os.path.join(clone, ".claude", "settings.local.json"))).get("env", {}).get("CLAUDE_BRIDGE_AUTH_TOKEN")
    except (OSError, ValueError): pass
if not tok:
    try: tok = open(os.path.join(relay_dir, "bridge-token")).read().strip()
    except OSError: pass
if tok: vals["CLAUDE_BRIDGE_AUTH_TOKEN"] = tok
# git identity + signing: strings; the template fills what the account lacks
git = {"GIT_USER_NAME": "user.name", "GIT_USER_EMAIL": "user.email", "GIT_SIGNING_KEY": "user.signingkey", "GIT_GPG_PROGRAM": "gpg.program"}
for name, key in git.items():
    r = subprocess.run(["git", "config", "--global", "--get", key], capture_output=True, text=True)
    v = r.stdout.strip() if r.returncode == 0 else ""
    if not v: v = tpl.get(name, "")
    if v: vals[name] = v
# the ssh key pair
for name, fn in (("SSH_PRIVATE_KEY", "id_ed25519"), ("SSH_PUBLIC_KEY", "id_ed25519.pub")):
    try: vals[name] = open(os.path.join(home, ".ssh", fn)).read().rstrip("\n")
    except OSError: pass
json.dump(vals, sys.stdout)
PY
}

migrate() {
  local login="$1" config="$2"
  local gathered="$TMP/$login.json"
  ( umask 077; : > "$gathered" )
  gather "$login" "$gathered" || die "$login: gathering failed"
  local have=""
  have="$(doppler secrets --only-names --json --project "$PROJECT" --config "$config" 2>/dev/null | python3 -c '
import json, sys
try: print(" ".join(json.load(sys.stdin).keys()))
except ValueError: pass' || true)"
  # Names already in Doppler stay unless --remigrate: once enrolled, Doppler is the record.
  local upload="$TMP/$login.upload.json"
  ( umask 077; : > "$upload" )
  # The GZCoord token is one shared secret: an account that never held a
  # copy (no clone yet) gets the relay host's, read here as the coordinator.
  local shared_bridge="${AGENT_FABRIC_RELAY_TOKEN_FILE:-$(dirname "$ROOT")/.gzcoord/bridge-token}"
  python3 - "$gathered" "$upload" "$have" "$REMIGRATE" "$shared_bridge" <<'PY'
import json, sys
src, dst, have, force, bridge = sys.argv[1], sys.argv[2], set(sys.argv[3].split()), sys.argv[4] == "1", sys.argv[5]
vals = json.load(open(src))
if "CLAUDE_BRIDGE_AUTH_TOKEN" not in vals:
    try: vals["CLAUDE_BRIDGE_AUTH_TOKEN"] = open(bridge).read().strip()
    except OSError: pass
keep = {k: v for k, v in vals.items() if force or k not in have}
json.dump(keep, open(dst, "w"))
print("gathered: " + ", ".join(sorted(vals)))
print("upload:   " + (", ".join(sorted(keep)) or "(nothing new)"))
PY
  if [[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$upload")" != "0" ]]; then
    # upload echoes what it set; nothing of that reaches the terminal.
    run doppler secrets upload "$upload" --project "$PROJECT" --config "$config" --silent >/dev/null || die "$login: upload failed"
  fi
  shred -u "$gathered" "$upload" 2>/dev/null || rm -f "$gathered" "$upload"
}

# ---- 4. the account's token ---------------------------------------------
issue_token() {
  local login="$1" config="$2" home; home="$(home_of "$login")"
  local name="$HOST/$login"
  # The coordinator's own login reads its config with the CLI token it
  # already holds (workplace admin); a service token at scope / would
  # replace that credential and lock the coordinator out of the project.
  if [[ "$login" == "$(id -un)" ]]; then say "$login: coordinator keeps its CLI token; no service token"; return 0; fi
  # Issued before AND held by the account: done. Issued but not held (the
  # store step failed last time, or the account's ~/.doppler was rebuilt)
  # is the partially-enrolled state — a second token of the same name is
  # issued and the unused one named for revoking; the account is never
  # left with a record that says "done" and no credential.
  if doppler configs tokens --project "$PROJECT" --config "$config" --json 2>/dev/null | python3 -c '
import json, sys
try: sys.exit(0 if any(t.get("name") == sys.argv[1] for t in (json.load(sys.stdin) or [])) else 1)
except ValueError: sys.exit(1)' "$name"; then
    if [[ -n "$(as_login "$login" doppler configure get token --plain --scope / 2>/dev/null)" ]]; then
      say "$login: service token $name already issued; keeping the account's copy"
      return 0
    fi
    (( DRY )) || say "$login: a token named $name exists but the account holds none (an earlier run stopped between issuing and storing); issuing another — revoke the unused one in the dashboard"
  fi
  if (( DRY )); then say "would: issue read token $name and configure it for $login"; return 0; fi
  # The token goes from doppler's stdout into the account's config file and nowhere else.
  doppler configs tokens create "$name" --project "$PROJECT" --config "$config" --access read --plain \
    | as_login "$login" bash -c 'read -r t; [ -n "$t" ] || exit 1; mkdir -p -m 700 ~/.doppler; doppler configure set token "$t" --scope / --silent' \
    || die "$login: could not issue or store the service token"
  say "$login: service token $name issued and stored"
}

# ---- 5. sync + verify ----------------------------------------------------
sync_and_verify() {
  local login="$1"
  if (( DRY )); then say "would: fabric-secrets sync as $login and verify"; return 0; fi
  as_login "$login" "$(fabric_secrets_of "$login")" sync || say "$login: sync reported missing names (see above)"
  local ok=1
  if as_login "$login" bash -lc 'ori auth --json' 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin); d = d.get("data", d)
    sys.exit(0 if d.get("authenticated") is True and (d.get("source") or {}).get("kind") == "environment" else 1)
except (ValueError, AttributeError): sys.exit(1)'; then
    say "$login: ori authenticated from the environment"
  else
    say "$login: ori NOT authenticated from the environment (no OPENROUTER_API_KEY in Doppler?)"; ok=0
  fi
  if as_login "$login" bash -lc 'gh auth status' >/dev/null 2>&1; then say "$login: gh authenticated"; else say "$login: gh NOT authenticated"; ok=0; fi
  if [[ -n "$(as_login "$login" git config --global --get user.signingkey)" ]]; then say "$login: signing key set"; else say "$login: signing key NOT set"; ok=0; fi
  return $(( ok ? 0 : 1 ))
}

# ---- 6. retire the old sources -------------------------------------------
retire_old_sources() {
  local login="$1" home; home="$(home_of "$login")"
  if (( DRY )); then say "would: retire .bashrc export, settings.local.json entries and gh hosts.yml login for $login"; return 0; fi
  as_login "$login" python3 - "$home" <<'PY'
import json, os, re, sys, glob
home = sys.argv[1]
rc = os.path.join(home, ".bashrc")
try:
    lines = open(rc, encoding="utf-8").read().splitlines(keepends=True)
    kept = [l for l in lines if not re.match(r'^\s*export\s+OPENROUTER_API_KEY=', l)]
    if kept != lines:
        open(rc, "w", encoding="utf-8").writelines(kept); print("retired: .bashrc OPENROUTER_API_KEY export")
except FileNotFoundError: pass
for f in glob.glob(os.path.join(home, "projects", "*", ".claude", "settings.local.json")):
    try: d = json.load(open(f))
    except (OSError, ValueError): continue
    env = d.get("env") or {}
    if "CLAUDE_BRIDGE_AUTH_TOKEN" in env:
        del env["CLAUDE_BRIDGE_AUTH_TOKEN"]
        if env: d["env"] = env
        else: d.pop("env", None)
        json.dump(d, open(f, "w"), indent=2); open(f, "a").write("\n")
        print(f"retired: CLAUDE_BRIDGE_AUTH_TOKEN in {os.path.relpath(f, home)}")
PY
  # gh: with GH_TOKEN in the environment the stored login is a second credential; drop it.
  # Not for the coordinator's own login: its keyring login is the session's
  # live credential, and the exported token only reaches new shells.
  [[ "$login" == "$(id -un)" ]] && return 0
  if as_login "$login" bash -c 'gh auth status --hostname github.com 2>&1 | grep -q hosts.yml'; then
    as_login "$login" bash -c 'gh auth logout --hostname github.com >/dev/null 2>&1' && say "$login: retired gh hosts.yml login"
  fi
}

enrol() {
  local login="$1"
  getent passwd "$login" >/dev/null || die "no such login: $login"
  $SUDO test -d "$(home_of "$login")/projects/agent-fabric" || die "$login has no ~/projects/agent-fabric (bootstrap first)"
  say "== $login"
  local home; home="$(home_of "$login")"
  # Provisioning left ~/.config root-owned on some accounts; the account
  # must own what fabric-secrets writes under it.
  if $SUDO test -d "$home/.config" && [[ "$($SUDO stat -c %U "$home/.config")" != "$login" ]]; then
    run $SUDO chown "$login:" "$home/.config"; say "$login: ~/.config handed to the account"
  fi
  local config; config="$(ensure_config "$login")" || exit 1
  migrate "$login" "$config"
  issue_token "$login" "$config"
  record_config "$login" "$config"
  if sync_and_verify "$login"; then
    retire_old_sources "$login"
  else
    say "$login: verification incomplete; old sources kept — fix the Doppler config, then re-run"
  fi
}

# ---- fill-from: complete configs from another login's ---------------------
config_of() {  # the config holding this login (recorded by enrol), or empty
  existing_config "$1"
}
fill_from() {
  local source="$1"; shift
  local src_cfg; src_cfg="$(config_of "$source")"
  [[ -n "$src_cfg" ]] || die "no config for $source"
  local targets=("$@")
  (( ${#targets[@]} )) || mapfile -t targets < <(all_logins | grep -vx "$source")
  local login tgt_cfg have missing
  for login in "${targets[@]}"; do
    [[ "$login" == "$source" ]] && continue
    tgt_cfg="$(config_of "$login")"
    [[ -n "$tgt_cfg" ]] || { say "$login: not enrolled, skipped"; continue; }
    have="$(doppler secrets --only-names --json --project "$PROJECT" --config "$tgt_cfg" 2>/dev/null | python3 -c '
import json, sys
try: print(" ".join(json.load(sys.stdin).keys()))
except ValueError: pass')"
    # Names the source has and the target lacks. Never copied: the identity
    # names; the coordinator's own credentials — the provisioning and admin
    # keys the issue-* commands use, and the fabric's read token — which the
    # source config holds precisely because it is the coordinator's (copying
    # them handed a fresh agent account the power to mint keys for every
    # other: brand-comms-01, 2026-09-15, deleted the same hour); and every
    # name projects/registry.json declares under `agent_env`, which is
    # per login by definition (a port offset, an OpenAI key of its own) and
    # is set by its own step, never inherited from another account.
    per_login="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
names = set(d.get("agent_env") or {})
for p in (d.get("projects") or {}).values(): names |= set(p.get("agent_env") or {})
print(" ".join(sorted(names)))' "$ROOT/projects/registry.json" 2>/dev/null)"
    missing="$(doppler secrets --only-names --json --project "$PROJECT" --config "$src_cfg" 2>/dev/null | python3 -c '
import json, sys
have = set(sys.argv[1].split())
skip = {"AGENT_LOGIN", "AGENT_HOST"} | set(sys.argv[2].split())
coordinator_only = ("_ADMIN_KEY", "_PROVISIONING_KEY", "AGENT_FABRIC_READ_TOKEN")
try: names = [n for n in json.load(sys.stdin) if not n.startswith("DOPPLER_") and n not in skip and n not in have
              and not any(n.endswith(c) or n == c for c in coordinator_only)]
except ValueError: names = []
print(" ".join(sorted(names)))' "$have" "$per_login")"
    if [[ -z "$missing" ]]; then say "$login: nothing missing"; continue; fi
    if (( DRY )); then say "would: copy $missing from $src_cfg into $tgt_cfg"; continue; fi
    local upload="$TMP/$login.fill.json"; ( umask 077; : > "$upload" )
    doppler secrets download --no-file --format json --project "$PROJECT" --config "$src_cfg" 2>/dev/null | python3 -c '
import json, sys
names = sys.argv[1].split(); out = sys.argv[2]
vals = json.load(sys.stdin)
json.dump({n: vals[n] for n in names if n in vals}, open(out, "w"))' "$missing" "$upload" || die "$login: could not read $src_cfg"
    doppler secrets upload "$upload" --project "$PROJECT" --config "$tgt_cfg" --silent >/dev/null || die "$login: upload failed"
    shred -u "$upload" 2>/dev/null || rm -f "$upload"
    say "$login: copied $missing from $source"
    as_login "$login" "$(fabric_secrets_of "$login")" sync --quiet || true
  done
}

# ---- issue-openai-keys: one service-account key per agent ----------------
issue_openai_keys() {
  local me_cfg; me_cfg="$(config_of "$(id -un)")"
  [[ -n "$me_cfg" ]] || die "no config for $(id -un)"
  local login tgt_cfg
  for login in "$@"; do
    tgt_cfg="$(config_of "$login")"
    [[ -n "$tgt_cfg" ]] || { say "$login: not enrolled, skipped"; continue; }
    if (( DRY )); then say "would: create OpenAI service account agent-fabric-$login and set OPENAI_API_KEY in $tgt_cfg"; continue; fi
    local upload="$TMP/$login.oaikey.json"; ( umask 077; : > "$upload" )
    python3 - "$PROJECT" "$me_cfg" "$login" "$upload" <<'PY' || die "$login: key creation failed"
import json, subprocess, sys, urllib.request
project, me_cfg, login, out = sys.argv[1:5]
def secret(name):
    r = subprocess.run(["doppler", "secrets", "get", name, "--plain", "--project", project, "--config", me_cfg], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""
adm = secret("OPENAI_ADMIN_KEY")
if not adm: print("enroll: OPENAI_ADMIN_KEY is not in the coordinator's config", file=sys.stderr); sys.exit(1)
H = {"Authorization": f"Bearer {adm}", "Content-Type": "application/json"}
def call(path, data=None):
    req = urllib.request.Request("https://api.openai.com/v1/" + path, data=json.dumps(data).encode() if data is not None else None, headers=H)
    try:
        with urllib.request.urlopen(req) as resp: return json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"enroll: OpenAI refused ({e.code}) on {path}: {e.read()[:160].decode(errors='replace')}", file=sys.stderr); sys.exit(1)
pid = secret("OPENAI_PROJECT_ID")
if not pid:
    projs = [p for p in call("organization/projects?limit=50")["data"] if p.get("status") == "active"]
    if len(projs) != 1:
        print(f"enroll: {len(projs)} active projects; set OPENAI_PROJECT_ID in the coordinator's config", file=sys.stderr); sys.exit(1)
    pid = projs[0]["id"]
# Named for what it is: this control plane's key for that login. A key is
# returned only at creation, so an account already there under this name
# (or the bare login, an earlier spelling) is replaced, never reused.
name = f"agent-fabric-{login}"
existing = {s["name"]: s["id"] for s in call(f"organization/projects/{pid}/service_accounts?limit=100")["data"]}
for old in (name, login):
    if old in existing:
        req = urllib.request.Request(f"https://api.openai.com/v1/organization/projects/{pid}/service_accounts/{existing[old]}", headers=H, method="DELETE")
        urllib.request.urlopen(req).read()
        print(f"enroll: {login}: replaced the existing service account {old}", file=sys.stderr)
sa = call(f"organization/projects/{pid}/service_accounts", {"name": name})
key = (sa.get("api_key") or {}).get("value")
if not key: print("enroll: OpenAI returned no key with the service account", file=sys.stderr); sys.exit(1)
json.dump({"OPENAI_API_KEY": key}, open(out, "w"))
print(f"enroll: created OpenAI service account {name} (key id {(sa.get('api_key') or {}).get('id', '?')})", file=sys.stderr)
PY
    doppler secrets upload "$upload" --project "$PROJECT" --config "$tgt_cfg" --silent >/dev/null || die "$login: upload failed"
    shred -u "$upload" 2>/dev/null || rm -f "$upload"
    say "$login: OPENAI_API_KEY set in $tgt_cfg"
    as_login "$login" "$(fabric_secrets_of "$login")" sync --quiet || true
  done
}

# ---- set-shared: one value into every config (a rotation) ----------------
set_shared() {
  local name="$1" file="$2"
  [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "not a secret name: $name"
  [[ -r "$file" ]] || die "cannot read $file"
  local upload="$TMP/shared.json"; ( umask 077; : > "$upload" )
  python3 -c 'import json,sys; v=open(sys.argv[2]).read().strip(); assert v, "empty value"; json.dump({sys.argv[1]: v}, open(sys.argv[3], "w"))' "$name" "$file" "$upload" || die "could not read the value"
  local login cfg n=0
  for login in $(all_logins); do
    cfg="$(config_of "$login")"; [[ -n "$cfg" ]] || { say "$login: not enrolled, skipped"; continue; }
    if (( DRY )); then say "would: set $name in $cfg"; continue; fi
    doppler secrets upload "$upload" --project "$PROJECT" --config "$cfg" --silent >/dev/null || die "$login: upload failed"
    n=$((n+1))
  done
  shred -u "$upload" "$file" 2>/dev/null || rm -f "$upload" "$file"
  say "$name set in $n config(s); syncing every account"
  (( DRY )) || for login in $(all_logins); do as_login "$login" "$(fabric_secrets_of "$login")" sync --quiet || say "$login: sync reported a problem"; done
}

# ---- issue-openrouter-keys: one key per agent -----------------------------
# Per-agent spend follows the key (runtime/openrouter/launch): an account
# that runs on a copied key spends on someone else's. The provisioning key
# is read from the coordinator's config inside python and used there only.
issue_openrouter_keys() {
  local me_cfg; me_cfg="$(config_of "$(id -un)")"
  [[ -n "$me_cfg" ]] || die "no config for $(id -un)"
  local login tgt_cfg
  for login in "$@"; do
    tgt_cfg="$(config_of "$login")"
    [[ -n "$tgt_cfg" ]] || { say "$login: not enrolled, skipped"; continue; }
    if (( DRY )); then say "would: create OpenRouter key $login and set OPENROUTER_API_KEY in $tgt_cfg"; continue; fi
    local upload="$TMP/$login.orkey.json"; ( umask 077; : > "$upload" )
    # The key's hash (its handle at OpenRouter, not the secret) is kept
    # beside the upload so a failed store can delete the key it minted:
    # otherwise a key exists under the login's name that nothing records,
    # and the re-run mints a second (review, 2026-09-16).
    local hashf="$TMP/$login.orkey.hash"; ( umask 077; : > "$hashf" )
    python3 - "$PROJECT" "$me_cfg" "$login" "$upload" "$hashf" "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}" <<'PY' || die "$login: key creation failed"
import json, subprocess, sys, urllib.request
project, me_cfg, name, out, hashf, base = sys.argv[1:7]
r = subprocess.run(["doppler", "secrets", "get", "OPENROUTER_PROVISIONING_KEY", "--plain",
                    "--project", project, "--config", me_cfg], capture_output=True, text=True)
prov = r.stdout.strip()
if r.returncode != 0 or not prov:
    print("enroll: OPENROUTER_PROVISIONING_KEY is not in the coordinator's config", file=sys.stderr); sys.exit(1)
req = urllib.request.Request(base + "/keys", data=json.dumps({"name": name}).encode(),
                             headers={"Authorization": f"Bearer {prov}", "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req) as resp: body = json.load(resp)
except urllib.error.HTTPError as e:
    print(f"enroll: OpenRouter refused ({e.code}): {e.read()[:200].decode(errors='replace')}", file=sys.stderr); sys.exit(1)
key = body.get("key") or (body.get("data") or {}).get("key")
if not key:
    print("enroll: OpenRouter returned no key", file=sys.stderr); sys.exit(1)
json.dump({"OPENROUTER_API_KEY": key}, open(out, "w"))
h = (body.get("data") or {}).get("hash") or ""
open(hashf, "w").write(h)
print(f"enroll: created OpenRouter key {name} (hash {h[:12]}…)", file=sys.stderr)
PY
    if ! doppler secrets upload "$upload" --project "$PROJECT" --config "$tgt_cfg" --silent >/dev/null; then
      shred -u "$upload" 2>/dev/null || rm -f "$upload"
      if python3 - "$PROJECT" "$me_cfg" "$hashf" "${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}" <<'PY'
import subprocess, sys, urllib.request
project, me_cfg, hashf, base = sys.argv[1:5]
h = open(hashf).read().strip()
if not h: sys.exit(1)
prov = subprocess.run(["doppler", "secrets", "get", "OPENROUTER_PROVISIONING_KEY", "--plain", "--project", project, "--config", me_cfg],
                      capture_output=True, text=True).stdout.strip()
req = urllib.request.Request(base + "/keys/" + h, method="DELETE", headers={"Authorization": f"Bearer {prov}"})
try:
    with urllib.request.urlopen(req): pass
except Exception: sys.exit(1)
PY
      then die "$login: Doppler upload failed; the key just minted was deleted at OpenRouter — nothing to clean up, re-run"
      else die "$login: Doppler upload failed AND the minted key could not be deleted: a key named $login exists at OpenRouter that nothing records — delete it in the dashboard, then re-run"
      fi
    fi
    shred -u "$upload" "$hashf" 2>/dev/null || rm -f "$upload" "$hashf"
    say "$login: OPENROUTER_API_KEY set in $tgt_cfg"
    as_login "$login" "$(fabric_secrets_of "$login")" sync --quiet || true
  done
}

# Every gathered value lives only under $TMP (0700) between gather and
# upload, and the EXIT trap removes it on any end — a die, a kill, a full
# disk (runtime/provisioning/secrets/test_enroll.sh injects each). A
# temporary directory that cannot be made is the stop, before anything
# is created remotely.
TMP="$(mktemp -d 2>/dev/null)" && [[ -d "$TMP" ]] || die "cannot create a temporary directory under ${TMPDIR:-/tmp} (full, or not writable): nothing done"
chmod 700 "$TMP" || die "cannot secure $TMP: nothing done"
trap 'rm -rf "$TMP"' EXIT
command -v doppler >/dev/null || die "doppler CLI not on PATH"
doppler projects get "$PROJECT" --json >/dev/null 2>&1 || die "Doppler project $PROJECT not reachable with this token"

case "$MODE" in
  fill-from)
    (( ${#LOGINS[@]} )) || die "fill-from needs the source login"
    fill_from "${LOGINS[@]}" ;;
  issue-openrouter-keys)
    (( ${#LOGINS[@]} )) || die "issue-openrouter-keys needs the logins"
    issue_openrouter_keys "${LOGINS[@]}" ;;
  issue-openai-keys)
    (( ${#LOGINS[@]} )) || die "issue-openai-keys needs the logins"
    issue_openai_keys "${LOGINS[@]}" ;;
  set-shared)
    (( ${#LOGINS[@]} == 2 )) || die "set-shared needs <NAME> <file>"
    set_shared "${LOGINS[0]}" "${LOGINS[1]}" ;;
  sync-all)
    for login in $(all_logins); do
      say "== $login"; as_login "$login" "$(fabric_secrets_of "$login")" sync || true
    done ;;
  all)
    install_cli
    for login in $(all_logins); do enrol "$login"; done ;;
  enrol)
    (( ${#LOGINS[@]} )) || { sed -n '2,12p' "$0" >&2; exit 2; }
    install_cli
    for login in "${LOGINS[@]}"; do enrol "$login"; done ;;
esac
