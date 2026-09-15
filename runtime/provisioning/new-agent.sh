#!/usr/bin/env bash
# runtime/provisioning/new-agent.sh — give a role its own account on this
# host: everything the control plane can do without a person at a
# terminal, in order, idempotently, then the short list of what only a
# person can do. Run by a fabric-coordinator holder from its own login
# (the account steps go through sudo; the Doppler steps use the
# coordinator's own CLI token).
#
#   runtime/provisioning/new-agent.sh <login> <role> [--project <id>]... [--dry-run]
#
#   new-agent.sh brand-comms-01 brand-comms --project gzapi.ge --project gzapp.decks
#
# WHY THIS EXISTS. The host runbook (the managed project's docs/host/
# PROVISIONING.md) is twelve sections a person walks by hand, and twice
# on 2026-09-15 an account was walked through it in a session and came
# out short: a claude binary never installed, a root-owned ~/.local/bin,
# the GitHub host key never trusted so every SSH step failed as a
# password prompt, pnpm and node_modules absent, and — the one that
# mattered — a fill-from that copied the coordinator's admin keys into
# the new account's config. Each of those is one line here, checked
# before it is done, so the second account costs what the first did.
#
# WHAT IT DOES, in order (each step is skipped when already true):
#   1. the Linux account (useradd), home 700, the shared-cache group
#   2. ~/.ssh ~/.claude ~/.config/gh ~/.local/{bin,share}, owned by the
#      account; claude and ori copied from the coordinator's own installs
#   3. github.com's host key in the account's known_hosts (public data)
#   4. ~/projects/agent-fabric cloned over https (the fabric is public;
#      the account has no key yet) — enrolment reads the account's own
#      checkout for fabric-secrets
#   5. Doppler enrolment: enroll.sh <login>, fill-from <coordinator>,
#      issue-openrouter-keys, issue-openai-keys, then sync — GH_TOKEN, the
#      relay token, the SSH key pair, the git identity strings, a key of
#      the account's own on each API
#   6. every --project cloned AS THE ACCOUNT over SSH from the remote the
#      registry names (the key from step 5 is what makes this work)
#   7. bootstrap.sh as the account (workspace CLAUDE.md, hooks, agent
#      files, skills, core.hooksPath on every clone)
#   8. bin/fabric-role bind <role>, from the account's login shell
#   9. toolchain per project, from its lockfile: pnpm (installed under
#      ~/.local) and `pnpm install`, or `npm install`
#  10. verify: fabric-secrets status, gh, ssh to GitHub, git identity,
#      launch --print for both providers — and print what remains for a
#      person: the GPG secret key (a passphrase prompt; the runbook §4),
#      ~/.claude/.credentials.json for the plain-claude path (a
#      credential copy a classifier refuses an agent; §5), and the
#      workspace-trust dialog at the first interactive launch.
#
# NEVER: a secret value on the terminal (enroll.sh keeps them inside
# doppler calls); a copy of the coordinator's admin or provisioning keys
# (enroll.sh fill-from excludes them); a guess at a port offset (a row in
# the project's table is devex-tooling's to add, and the registry marks
# the name per login so fill-from never inherits one).
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
REGISTRY="$ROOT/projects/registry.json"
ENROLL="$ROOT/runtime/provisioning/secrets/enroll.sh"
DRY=0; LOGIN=""; ROLE=""; PROJECTS=()
while (( $# )); do
    case "$1" in
        --dry-run) DRY=1 ;;
        --project) PROJECTS+=("$2"); shift ;;
        --project=*) PROJECTS+=("${1#--project=}") ;;
        -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "new-agent: unknown flag $1" >&2; exit 2 ;;
        *) if [[ -z "$LOGIN" ]]; then LOGIN="$1"; elif [[ -z "$ROLE" ]]; then ROLE="$1"; else echo "new-agent: unexpected argument $1" >&2; exit 2; fi ;;
    esac
    shift
done
[[ -n "$LOGIN" && -n "$ROLE" ]] || { echo "usage: new-agent.sh <login> <role> [--project <id>]... [--dry-run]" >&2; exit 2; }

say() { printf 'new-agent: %s\n' "$*" >&2; }
die() { printf 'new-agent: %s\n' "$*" >&2; exit 1; }
run() { if (( DRY )); then say "would: $*"; else "$@"; fi; }
COORD="$(id -un)"
[[ "$COORD" != root ]] || die "run this as the fabric-coordinator login, not root: the Doppler steps use your own CLI token."

# ---- what is asked for must exist in the fabric --------------------------
[[ -f "$ROOT/identities/roles/$ROLE/charter.md" ]] || die "no role '$ROLE' under identities/roles/ (bin/fabric-role list)."
declare -A REMOTE
for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
    r="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); p = (d.get("projects") or {}).get(sys.argv[2])
if not p: sys.exit(1)
print(next((x for x in p["remotes"] if x.startswith("git@")), p["remotes"][0]))' "$REGISTRY" "$pid")" || die "project '$pid' is not in projects/registry.json — register it first."
    REMOTE["$pid"]="$r"
done

as_login() { sudo -n -u "$LOGIN" -H env -i HOME="$HOME_DIR" PATH="/usr/local/bin:/usr/bin:/bin:$HOME_DIR/.local/bin" bash -lc "cd \"\$HOME\" && $*"; }
(( DRY )) || sudo -n true 2>/dev/null || die "sudo without a password is needed for the account steps (this login has none)."

# ---- 1. the account ---------------------------------------------------------
if getent passwd "$LOGIN" >/dev/null; then say "1. account $LOGIN exists"
else run sudo -n useradd -m -s /bin/bash -c "agent-fabric $ROLE" "$LOGIN"; say "1. account $LOGIN created"; fi
HOME_DIR="$(getent passwd "$LOGIN" | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/home/$LOGIN}"
run sudo -n chmod 700 "$HOME_DIR"
if getent group otscache >/dev/null && ! id -nG "$LOGIN" 2>/dev/null | tr ' ' '\n' | grep -qx otscache; then
    run sudo -n usermod -aG otscache "$LOGIN"; say "   joined otscache (the shared timestamp cache)"; fi

# ---- 2. the home skeleton and the two binaries ----------------------------
run sudo -n -u "$LOGIN" mkdir -p "$HOME_DIR"/{projects,.ssh,.claude,.config/gh,.local/bin,.local/share/claude/versions}
run sudo -n -u "$LOGIN" chmod 700 "$HOME_DIR/.ssh"
run sudo -n chown "$LOGIN:$LOGIN" "$HOME_DIR/.local" "$HOME_DIR/.local/bin" "$HOME_DIR/.local/share"
CLAUDE_BIN="$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null || true)"
[[ -n "$CLAUDE_BIN" && -x "$CLAUDE_BIN" ]] || die "no claude binary at $HOME/.local/bin/claude to copy from."
if sudo -n test -x "$HOME_DIR/.local/share/claude/versions/$(basename "$CLAUDE_BIN")"; then say "2. claude $(basename "$CLAUDE_BIN") present"
else run sudo -n install -o "$LOGIN" -g "$LOGIN" -m 755 "$CLAUDE_BIN" "$HOME_DIR/.local/share/claude/versions/"
     run sudo -n -u "$LOGIN" ln -sfn "$HOME_DIR/.local/share/claude/versions/$(basename "$CLAUDE_BIN")" "$HOME_DIR/.local/bin/claude"
     say "2. claude $(basename "$CLAUDE_BIN") installed"; fi
ORI_BIN="$(command -v ori || true)"
if [[ -n "$ORI_BIN" ]] && ! sudo -n test -x "$HOME_DIR/.local/bin/ori"; then
    run sudo -n install -o "$LOGIN" -g "$LOGIN" -m 711 "$ORI_BIN" "$HOME_DIR/.local/bin/ori"; say "   ori installed"; fi

# ---- 3. GitHub's host key --------------------------------------------------
if sudo -n grep -qs "^github.com " "$HOME_DIR/.ssh/known_hosts" 2>/dev/null; then say "3. github.com host key trusted"
else
    if (( DRY )); then say "would: ssh-keyscan github.com >> $HOME_DIR/.ssh/known_hosts"
    else ssh-keyscan -t ed25519,rsa,ecdsa github.com 2>/dev/null | sudo -n -u "$LOGIN" tee -a "$HOME_DIR/.ssh/known_hosts" >/dev/null
         sudo -n -u "$LOGIN" chmod 600 "$HOME_DIR/.ssh/known_hosts"; say "3. github.com host key trusted (ssh-keyscan)"; fi
fi

# ---- 4. the fabric checkout -------------------------------------------------
if sudo -n test -d "$HOME_DIR/projects/agent-fabric/.git"; then say "4. ~/projects/agent-fabric present"
else run as_login "git clone -q https://github.com/gzapi-org/agent-fabric.git ~/projects/agent-fabric"; say "4. agent-fabric cloned (https; the fabric is public)"; fi

# ---- 5. Doppler enrolment ---------------------------------------------------
# A key of the account's own is minted once: issue-* replaces whatever the
# name holds, so a re-run must not mint again. The name's presence in the
# account's config is the check (names only; no value is read).
config_has() {  # config_has <name> — true when the account's config carries it
    local cfg; cfg="$(sudo -n -u "$LOGIN" -H env -i HOME="$HOME_DIR" doppler configure get enclave.config --plain --scope / 2>/dev/null || true)"
    [[ -n "$cfg" ]] || return 1
    doppler secrets --only-names --json --project agent-fabric --config "$cfg" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$1"
}
if (( DRY )); then say "would: enroll.sh $LOGIN; fill-from $COORD $LOGIN; issue-openrouter-keys and issue-openai-keys $LOGIN (each once)"
else
    "$ENROLL" "$LOGIN" >/dev/null 2>&1 || true   # first pass: config + token + the strings; verification fails on the missing keys
    "$ENROLL" fill-from "$COORD" "$LOGIN" 2>&1 | grep -v "^gathered\|^upload" | sed 's/^/   /' >&2
    # Both API keys are per login (projects/registry.json agent_env), so
    # fill-from never copies them and presence means "issued".
    if config_has OPENROUTER_API_KEY; then say "   OpenRouter key: present (issued once; not minted again)"
    else "$ENROLL" issue-openrouter-keys "$LOGIN" 2>&1 | tail -1 | sed 's/^/   /' >&2; fi
    if config_has OPENAI_API_KEY; then say "   OpenAI key: present (issued once; not minted again)"
    else "$ENROLL" issue-openai-keys "$LOGIN" 2>&1 | tail -1 | sed 's/^/   /' >&2; fi
    "$ENROLL" "$LOGIN" 2>&1 | grep -E "authenticated|signing key|verification|OK$|NOT OK" | sed 's/^/   /' >&2
    say "5. enrolled; secrets synced"
fi

# ---- 6. the project clones, as the account, over SSH -----------------------
for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
    if sudo -n test -d "$HOME_DIR/projects/$pid/.git"; then say "6. ~/projects/$pid present"
    else run as_login "git clone -q '${REMOTE[$pid]}' ~/projects/'$pid'" && say "6. $pid cloned from ${REMOTE[$pid]}"; fi
done

# ---- 7. bootstrap; 8. the role ------------------------------------------------
run as_login "~/projects/agent-fabric/runtime/claude-code/bootstrap.sh" 2>&1 | tail -1 | sed 's/^/   /' >&2; say "7. bootstrap run"
bound="$(as_login "~/projects/agent-fabric/bin/fabric-role status 2>/dev/null | awk '/^role/{print \$2}'" 2>/dev/null || true)"
if [[ "$bound" == "$ROLE" ]]; then say "8. role $ROLE already bound"
else
    first="${PROJECTS[0]:-}"; where="~/projects${first:+/$first}"
    if (( DRY )); then say "would: as_login cd $where && bin/fabric-role bind '$ROLE'"
    else as_login "cd $where && ~/projects/agent-fabric/bin/fabric-role bind '$ROLE'" 2>&1 | grep -i "bound\|refus" | sed 's/^/   /' >&2; fi
    say "8. role $ROLE bound (from $where)"; fi

# ---- 9. the toolchain each project declares ----------------------------------
for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
    wc="$HOME_DIR/projects/$pid"
    if sudo -n test -f "$wc/pnpm-lock.yaml"; then
        as_login "command -v pnpm >/dev/null" || { run as_login "npm config set prefix ~/.local && npm i -g pnpm >/dev/null"; say "9. pnpm installed under ~/.local"; }
        sudo -n test -d "$wc/node_modules" && say "9. $pid: node_modules present" || { run as_login "cd ~/projects/'$pid' && pnpm install --frozen-lockfile >/dev/null 2>&1"; say "9. $pid: pnpm install"; }
    elif sudo -n test -f "$wc/package-lock.json"; then
        sudo -n test -d "$wc/node_modules" && say "9. $pid: node_modules present" || { run as_login "cd ~/projects/'$pid' && npm ci >/dev/null 2>&1"; say "9. $pid: npm ci"; }
    elif sudo -n test -f "$wc/requirements.txt"; then
        sudo -n test -d "$wc/.venv" && say "9. $pid: .venv present" || { run as_login "cd ~/projects/'$pid' && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt"; say "9. $pid: venv"; }
    fi
done

# ---- 10. verify, and what is left for a person --------------------------------
(( DRY )) && { say "dry run: nothing verified"; exit 0; }
say "10. verification"
as_login "~/projects/agent-fabric/bin/fabric-secrets status 2>&1 | grep -E 'missing|OK|NOT OK'" | sed 's/^/   /' >&2
as_login "gh auth status 2>&1 | grep -o 'Logged in.*' | head -1" | sed 's/^/   gh: /' >&2
for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
    as_login "timeout 20 git -C ~/projects/'$pid' ls-remote --heads origin >/dev/null 2>&1 && echo 'ssh to origin: ok' || echo 'ssh to origin: FAILED'" | sed "s/^/   $pid /" >&2
done
as_login "printf 'git: %s <%s> signingkey=%s gpgsign=%s\n' \"\$(git config --global user.name)\" \"\$(git config --global user.email)\" \"\$(git config --global user.signingkey | cut -c1-12)\" \"\$(git config --global commit.gpgsign)\"" | sed 's/^/   /' >&2
gpgkeys="$(as_login "gpg --list-secret-keys 2>/dev/null | grep -c ^sec; true" 2>/dev/null | tr -dc 0-9 | head -c 4)"; gpgkeys="${gpgkeys:-0}"
first="${PROJECTS[0]:-}"; where="~/projects${first:+/$first}"
for prov in anthropic openrouter; do
    as_login "cd $where && AGENT_FABRIC_NO_ANNOUNCE=1 ~/projects/agent-fabric/runtime/openrouter/launch --provider $prov --print 2>&1 | grep -E '^launch:|resolved profile' | head -1" | sed "s/^/   launch ($prov): /" >&2
done
creds="$(sudo -n test -f "$HOME_DIR/.claude/.credentials.json" && echo yes || echo no)"
cat >&2 <<EOF
new-agent: done. Left for a person, in a terminal (nothing here can do them):
   $( [[ "$gpgkeys" -gt 0 ]] && echo "- GPG secret key: present" || echo "- GPG secret key: NONE — commits will fail to sign. As the coordinator, in a terminal (the key has a passphrase):
       gpg --export-secret-keys \"\$(git config --get user.signingkey)\" | sudo -u $LOGIN gpg --batch --import
       sudo -u $LOGIN bash -c \"echo '\$(git config --get user.signingkey):6:' | gpg --import-ownertrust\"" )
   $( [[ "$creds" == yes ]] && echo "- ~/.claude/.credentials.json: present (plain-claude path ready)" || echo "- ~/.claude/.credentials.json: absent — the plain-claude path (--provider anthropic) needs it; the broker path does not:
       sudo install -o $LOGIN -g $LOGIN -m 600 ~/.claude/.credentials.json $HOME_DIR/.claude/" )
   - first launch is interactive, to accept the workspace-trust dialog:
       moveto $LOGIN${first:+ $first}   then   runtime/openrouter/launch
EOF
