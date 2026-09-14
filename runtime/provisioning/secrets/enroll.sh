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
#                             config has — never a name already present;
#                             then sync the targets. Values stay inside
#                             doppler calls, never on a terminal.
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
  if doppler configs tokens --project "$PROJECT" --config "$config" --json 2>/dev/null | python3 -c '
import json, sys
try: sys.exit(0 if any(t.get("name") == sys.argv[1] for t in (json.load(sys.stdin) or [])) else 1)
except ValueError: sys.exit(1)' "$name"; then
    say "$login: service token $name already issued; keeping the account's copy"
    return 0
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
    # Names the source has and the target lacks; identity names are never copied.
    missing="$(doppler secrets --only-names --json --project "$PROJECT" --config "$src_cfg" 2>/dev/null | python3 -c '
import json, sys
have = set(sys.argv[1].split())
skip = {"AGENT_LOGIN", "AGENT_HOST"}
try: names = [n for n in json.load(sys.stdin) if not n.startswith("DOPPLER_") and n not in skip and n not in have]
except ValueError: names = []
print(" ".join(sorted(names)))' "$have")"
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

TMP="$(mktemp -d)"; chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
command -v doppler >/dev/null || die "doppler CLI not on PATH"
doppler projects get "$PROJECT" --json >/dev/null 2>&1 || die "Doppler project $PROJECT not reachable with this token"

case "$MODE" in
  fill-from)
    (( ${#LOGINS[@]} )) || die "fill-from needs the source login"
    fill_from "${LOGINS[@]}" ;;
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
