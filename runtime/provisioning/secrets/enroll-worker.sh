#!/usr/bin/env bash
# runtime/provisioning/secrets/enroll-worker.sh — the host half of
# enroll.sh: what must run ON THE ACCOUNT'S HOST, as the account or as
# the host's operator. enroll.sh (the coordinator) reaches it through
# runtime/hostexec/hostexec — directly on its own host, over ssh to any
# other — and keeps Doppler, the tokens and the keys to itself.
#
#   as the OPERATOR (hostexec <host> -- @fabric/.../enroll-worker.sh ...):
#     prepare-home <login>      the account exists, has ~/projects/agent-fabric,
#                               and owns ~/.config; prints the home path
#   as the ACCOUNT (hostexec <host> --as <login> -- ...):
#     gather <login> [NAME=value]...   what the account holds today, as
#                               one JSON object on stdout (values: this is
#                               the only channel they take, into the
#                               coordinator's 0700 temp dir); AGENT_HOST is
#                               what THIS host says (hostname -s) — the
#                               coordinator never stamps a host it is not on
#     retire <login> [keep-gh]  drop the old sources once Doppler is the record
#                               (keep-gh: leave the gh keyring login alone)
#
# Nothing here prints a value except gather's stdout, which the caller
# captures into a file it shreds.
set -uo pipefail
cmd="${1:-}"; login="${2:-}"; shift 2 || true
[[ -n "$cmd" && -n "$login" ]] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
say() { printf 'enroll: %s\n' "$*" >&2; }
die() { printf 'enroll: %s\n' "$*" >&2; exit 1; }
SUDO="${SUDO:-sudo}"
case "$cmd" in
  prepare-home)
    home="$(getent passwd "$login" | cut -d: -f6)"; [[ -n "$home" ]] || die "no such login on $(hostname -s): $login"
    $SUDO -n test -d "$home/projects/agent-fabric" || die "$login has no ~/projects/agent-fabric on $(hostname -s) (bootstrap first)"
    # Provisioning left ~/.config root-owned on some accounts; the account
    # must own what fabric-secrets writes under it.
    if $SUDO -n test -d "$home/.config" && [[ "$($SUDO -n stat -c %U "$home/.config")" != "$login" ]]; then
      $SUDO -n chown "$login:" "$home/.config" || die "$login: could not hand ~/.config to the account"; say "$login: ~/.config handed to the account"
    fi
    echo "$home" ;;
  gather)
    home="$HOME"; relay_dir="$home/projects/.gzcoord"
    python3 - "$home" "$relay_dir" "$login" "$(hostname -s)" "$@" <<'PY'
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
    ;;
  retire)
    python3 - "$HOME" <<'PY'
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
    # gh: with GH_TOKEN in the environment the stored login is a second
    # credential; drop it — unless the caller says keep-gh (the
    # coordinator's own login: its keyring login is the live session
    # credential, and the exported token only reaches new shells).
    [[ "${1:-}" == keep-gh ]] && exit 0
    if gh auth status --hostname github.com 2>&1 | grep -q hosts.yml; then
      gh auth logout --hostname github.com >/dev/null 2>&1 && say "$login: retired gh hosts.yml login"
    fi ;;
  *) die "unknown command $cmd (prepare-home | gather | retire)" ;;
esac
