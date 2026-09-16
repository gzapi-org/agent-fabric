#!/usr/bin/env bash
# runtime/provisioning/new-agent-worker.sh — the host half of new-agent.sh:
# everything that touches THIS machine (the account, its home, the
# installers, the host keys, the clones, bootstrap, the binding, the
# toolchain, the verification), run on the host the account is placed on
# — directly by new-agent.sh for its own host, through
# runtime/hostexec/hostexec for any other. It knows nothing of Doppler or
# the API keys: those are the coordinator's, between its two phases.
#
#   new-agent-worker.sh prepare <login> <role> [--claude VERSION|stable|latest] [--dry-run]
#       steps 0-4: host audit, account, home + claude + ori, GitHub's host keys, the fabric clone
#   new-agent-worker.sh finish <login> <role> [--clone <id>=<remote>]... [--dry-run]
#       steps 6-10: project clones, bootstrap, the role bound, toolchains, verification
#   new-agent-worker.sh host-check <login> [--project <id>]...
#       what this host reports about itself and the account (hostname -s first)
#
# Runs as the host's operator (sudo, no password); as_login runs one
# shell line as the account. Every step is must, probe or best_effort
# (new-agent.sh's failure semantics; test_new-agent.sh injects a failure
# at each must and asserts nothing after it ran).
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
PHASE="${1:-}"; shift || true
LOGIN="${1:-}"; ROLE=""; DRY=0; CLAUDE_TARGET=""; PROJECTS=(); declare -A REMOTE
case "$PHASE" in
    prepare|finish) ROLE="${2:-}"; shift 2 || true ;;
    host-check) shift || true ;;
    *) echo "usage: new-agent-worker.sh prepare|finish <login> <role> ... | host-check <login> [--project <id>]..." >&2; exit 2 ;;
esac
while (( $# )); do
    case "$1" in
        --dry-run) DRY=1 ;;
        --claude) CLAUDE_TARGET="$2"; shift ;;
        --claude=*) CLAUDE_TARGET="${1#--claude=}" ;;
        --clone) pid="${2%%=*}"; REMOTE["$pid"]="${2#*=}"; PROJECTS+=("$pid"); shift ;;
        --clone=*) v="${1#--clone=}"; pid="${v%%=*}"; REMOTE["$pid"]="${v#*=}"; PROJECTS+=("$pid") ;;
        --project) PROJECTS+=("$2"); shift ;;
        *) echo "new-agent-worker: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$LOGIN" ]] || { echo "new-agent-worker: no login" >&2; exit 2; }
[[ "$PHASE" == host-check || -n "$ROLE" ]] || { echo "new-agent-worker: no role" >&2; exit 2; }

say() { printf 'new-agent: %s\n' "$*" >&2; }
die() { printf 'new-agent: %s\n' "$*" >&2; exit 1; }
run() { if (( DRY )); then say "would: $*"; else "$@"; fi; }
must() { run "$@" || die "step failed: $* — nothing after it ran; fix the cause and re-run (every step is idempotent)"; }
probe() { "$@"; }
best_effort() { run "$@" || say "warning: $* failed; continuing"; }
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
SUDO="${SUDO:-sudo}"   # a test puts a fake here; the real one is sudo
HOME_DIR="$(getent passwd "$LOGIN" 2>/dev/null | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/home/$LOGIN}"
GROUP="$(id -gn "$LOGIN" 2>/dev/null || echo "$LOGIN")"   # the primary group, whatever the host's policy names it
# One shell line as the account; `must as_login '…'` when the line must succeed.
as_login() { $SUDO -n -u "$LOGIN" -H env -i HOME="$HOME_DIR" PATH="/usr/local/bin:/usr/bin:/bin:$HOME_DIR/.local/bin" bash -lc "cd \"\$HOME\" && $*"; }
(( DRY )) || $SUDO -n true 2>/dev/null || die "sudo without a password is needed for the account steps (the operator on $(hostname -s) has none)."

if [[ "$PHASE" == host-check ]]; then
    # The host names itself; the coordinator compares this with the
    # registry id it reached the host as, and never stamps a host it is not on.
    hostname -s
    getent passwd "$LOGIN" >/dev/null && echo "account: present" || echo "account: absent"
    for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do $SUDO -n test -d "$HOME_DIR/projects/$pid/.git" && echo "clone $pid: present" || echo "clone $pid: absent"; done
    exit 0
fi

if [[ "$PHASE" == prepare ]]; then
    # ---- 0. the host ----------------------------------------------------------------
    # tool:package — what the fabric's hooks and scripts and the managed
    # projects' toolchains call; the package is the TemplateVM's (Fedora).
    HOST_TOOLS=(git:git-core gh:gh node:nodejs npm:nodejs-npm python3:python3 jq:jq gpg:gnupg2 podman:podman magick:ImageMagick curl:curl)
    missing_pkgs=()
    for spec in "${HOST_TOOLS[@]}"; do
        tool="${spec%%:*}"; pkg="${spec##*:}"
        command -v "$tool" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
    done
    if (( ${#missing_pkgs[@]} )); then
        say "0. TEMPLATE: this AppVM lacks ${missing_pkgs[*]} — a package does not survive a reboot here;"
        say "   in the TemplateVM: sudo dnf install ${missing_pkgs[*]}   (then restart this AppVM)"
    else say "0. host tools present (${#HOST_TOOLS[@]} from the template)"; fi
    # doppler: a static binary; /usr/local persists in an AppVM, and enroll.sh
    # reads it from there for every account.
    if [[ -x /usr/local/bin/doppler ]]; then say "   doppler: /usr/local/bin/doppler"
    elif command -v doppler >/dev/null 2>&1; then
        best_effort $SUDO -n install -m 755 "$(command -v doppler)" /usr/local/bin/doppler; say "   doppler: copied to /usr/local/bin (persistent)"
    else
        if (( DRY )); then say "would: install doppler to /usr/local/bin with its vendor script (curl -Ls https://cli.doppler.com/install.sh | sudo sh)"
        else curl -Ls -m 60 https://cli.doppler.com/install.sh | $SUDO -n sh >/dev/null 2>&1 && say "   doppler: installed to /usr/local/bin" || say "   warning: doppler NOT installed (vendor script failed); step 5 will stop there"; fi
    fi
    [[ -x /usr/local/bin/ots-git-gpg-wrapper.sh ]] && say "   gpg wrapper: /usr/local/bin/ots-git-gpg-wrapper.sh" \
        || say "   gpg wrapper: MISSING — commit signing needs it; devex-tooling installs it (gzapp infra/signing/install-shim.sh)"


    # ---- 1. the account ---------------------------------------------------------
    if getent passwd "$LOGIN" >/dev/null; then say "1. account $LOGIN exists"
    else must $SUDO -n useradd -m -s /bin/bash -c "agent-fabric $ROLE" "$LOGIN"; say "1. account $LOGIN created"; fi
    HOME_DIR="$(getent passwd "$LOGIN" | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/home/$LOGIN}"
    # The account's primary group, whatever the host's policy names it (not
    # necessarily the login: user-private groups are a distribution choice).
    GROUP="$(id -gn "$LOGIN" 2>/dev/null || echo "$LOGIN")"
    must $SUDO -n chmod 700 "$HOME_DIR"
    if probe getent group otscache >/dev/null && ! id -nG "$LOGIN" 2>/dev/null | tr ' ' '\n' | grep -qx otscache; then
        best_effort $SUDO -n usermod -aG otscache "$LOGIN"; say "   otscache (the shared timestamp cache): joined"; fi


    # ---- 2. the home skeleton and the two binaries ----------------------------
    must $SUDO -n -u "$LOGIN" mkdir -p "$HOME_DIR"/{projects,.ssh,.claude,.config/gh,.local/bin,.local/share/claude/versions}
    must $SUDO -n -u "$LOGIN" chmod 700 "$HOME_DIR/.ssh"
    must $SUDO -n chown "$LOGIN:$GROUP" "$HOME_DIR/.local" "$HOME_DIR/.local/bin" "$HOME_DIR/.local/share"
    # claude: the vendor's installer, as the account, on the vendor's latest —
    # resolved against the release pointer so a re-run upgrades an account
    # that fell behind — unless --claude pins a version or stable. Its layout
    # is the one this script and the runbook assume:
    # ~/.local/bin/claude -> ~/.local/share/claude/versions/<v>.
    want="${CLAUDE_TARGET:-latest}"
    resolved="$want"
    if [[ "$want" == latest ]]; then
        resolved="$(curl -fsSL -m 20 https://downloads.claude.ai/claude-code-releases/latest 2>/dev/null | tr -d '[:space:]')"
        [[ "$resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || resolved=""
    fi
    have="$(as_login 'test -e ~/.local/bin/claude && readlink -f ~/.local/bin/claude | xargs -r basename' 2>/dev/null || true)"
    if [[ -n "$have" && -n "$resolved" && "$have" == "$resolved" ]]; then say "2. claude $have present (= $want)"
    else
        if (( DRY )); then say "would: as $LOGIN: curl -fsSL https://claude.ai/install.sh | bash -s -- $want"
        else
            as_login "curl -fsSL --proto '=https' -m 120 https://claude.ai/install.sh | bash -s -- '$want'" >"$LOG" 2>&1 \
                && as_login "claude --version" >/dev/null 2>&1 \
                || { tail -5 "$LOG" >&2; die "step failed: claude — the vendor's installer failed for $LOGIN (target $want); nothing after it ran"; }
            say "2. claude $(as_login 'claude --version' | cut -d' ' -f1) installed by the vendor's installer ($want${have:+, was $have})"
        fi
    fi
    # ori: the vendor's installer (stable channel; no version pin exists), into
    # ~/.local/bin as it does by default.
    if as_login "test -x ~/.local/bin/ori" 2>/dev/null; then say "   ori $(as_login 'ori --version 2>/dev/null | head -1' | tr -d '\n' | cut -c1-24) present"
    else
        if (( DRY )); then say "would: as $LOGIN: curl -fsSL https://openrouter.ai/labs/ori/install.sh | bash"
        else
            as_login "curl -fsSL --proto '=https' -m 120 https://openrouter.ai/labs/ori/install.sh | bash" >"$LOG" 2>&1 \
                && as_login "test -x ~/.local/bin/ori" \
                || { tail -5 "$LOG" >&2; die "step failed: ori — the vendor's installer failed for $LOGIN; nothing after it ran"; }
            say "   ori installed by the vendor's installer"
        fi
    fi


    # ---- 3. GitHub's host keys --------------------------------------------------
    # From the committed copy of GitHub's PUBLISHED keys (github-host-keys,
    # api.github.com/meta, fingerprints checked against docs.github.com when
    # the file was written — docs/live-checks/2026-09-16-github-host-keys.md),
    # never ssh-keyscan: a scan trusts whatever answers on the network the
    # bootstrap is about to use (review, 2026-09-16). Every key line the
    # account does not hold yet is appended; a changed key at GitHub is a
    # change to the committed file, reviewed like any other.
    HOST_KEYS="$ROOT/runtime/provisioning/github-host-keys"
    [[ -s "$HOST_KEYS" ]] || die "step failed: $HOST_KEYS is missing or empty; nothing after it ran"
    missing_keys="$(while IFS= read -r line; do [[ -n "$line" ]] && ! $SUDO -n grep -qsxF "$line" "$HOME_DIR/.ssh/known_hosts" 2>/dev/null && printf '%s\n' "$line"; done < "$HOST_KEYS")"
    if [[ -z "$missing_keys" ]]; then say "3. github.com host keys trusted ($(grep -c . "$HOST_KEYS") published keys)"
    else
        if (( DRY )); then say "would: append GitHub's published host keys (runtime/provisioning/github-host-keys) to $HOME_DIR/.ssh/known_hosts"
        else must bash -c 'printf "%s\n" "$1" | '"$SUDO"' -n -u "$2" tee -a "$3/.ssh/known_hosts" >/dev/null' _ "$missing_keys" "$LOGIN" "$HOME_DIR"
             must $SUDO -n -u "$LOGIN" chmod 600 "$HOME_DIR/.ssh/known_hosts"; say "3. github.com host keys trusted (from the committed published set)"; fi
    fi


    # ---- 4. the fabric checkout -------------------------------------------------
    if $SUDO -n test -d "$HOME_DIR/projects/agent-fabric/.git"; then say "4. ~/projects/agent-fabric present"
    else must as_login "git clone -q '${AGENT_FABRIC_CLONE_URL:-https://github.com/gzapi-org/agent-fabric.git}' ~/projects/agent-fabric"; say "4. agent-fabric cloned (https; the fabric is public)"; fi

    exit 0
fi

# ---- finish: after the coordinator's Doppler steps --------------------------
# ---- 6. the project clones, as the account, over SSH -----------------------
for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
    if $SUDO -n test -d "$HOME_DIR/projects/$pid/.git"; then say "6. ~/projects/$pid present"
    else must as_login "git clone -q '${REMOTE[$pid]}' ~/projects/'$pid'"; say "6. $pid cloned from ${REMOTE[$pid]}"; fi
done


# ---- 7. bootstrap; 8. the role ------------------------------------------------
if (( DRY )); then say "would: as $LOGIN: bootstrap.sh"
else
    as_login "~/projects/agent-fabric/runtime/claude-code/bootstrap.sh" >"$LOG" 2>&1 || { tail -5 "$LOG" >&2; die "step failed: bootstrap.sh as $LOGIN; nothing after it ran"; }
    tail -1 "$LOG" | sed 's/^/   /' >&2
fi
say "7. bootstrap run"
bound="$(as_login "~/projects/agent-fabric/bin/fabric-role status 2>/dev/null | awk '/^role/{print \$2}'" 2>/dev/null || true)"
if [[ "$bound" == "$ROLE" ]]; then say "8. role $ROLE already bound"
else
    first="${PROJECTS[0]:-}"; where="~/projects${first:+/$first}"
    if (( DRY )); then say "would: as_login cd $where && bin/fabric-role bind '$ROLE'"
    else
        as_login "cd $where && ~/projects/agent-fabric/bin/fabric-role bind '$ROLE'" >"$LOG" 2>&1 || { tail -5 "$LOG" >&2; die "step failed: fabric-role bind $ROLE as $LOGIN; nothing after it ran"; }
        grep -i "bound\|refus" "$LOG" | sed 's/^/   /' >&2
    fi
    say "8. role $ROLE bound (from $where)"; fi


# ---- 9. the toolchain each project declares ----------------------------------
for pid in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
    wc="$HOME_DIR/projects/$pid"
    if probe $SUDO -n test -f "$wc/pnpm-lock.yaml"; then
        probe as_login "command -v pnpm >/dev/null" || { must as_login "npm config set prefix ~/.local && npm i -g pnpm >/dev/null"; say "9. pnpm installed under ~/.local"; }
        probe $SUDO -n test -d "$wc/node_modules" && say "9. $pid: node_modules present" || { must as_login "cd ~/projects/'$pid' && pnpm install --frozen-lockfile >/dev/null 2>&1"; say "9. $pid: pnpm install"; }
    elif probe $SUDO -n test -f "$wc/package-lock.json"; then
        probe $SUDO -n test -d "$wc/node_modules" && say "9. $pid: node_modules present" || { must as_login "cd ~/projects/'$pid' && npm ci >/dev/null 2>&1"; say "9. $pid: npm ci"; }
    elif probe $SUDO -n test -f "$wc/requirements.txt"; then
        probe $SUDO -n test -d "$wc/.venv" && say "9. $pid: .venv present" || { must as_login "cd ~/projects/'$pid' && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt"; say "9. $pid: venv"; }
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
creds="$($SUDO -n test -f "$HOME_DIR/.claude/.credentials.json" && echo yes || echo no)"
cat >&2 <<EOF
new-agent: done. Left for a person, in a terminal (nothing here can do them):
   $( [[ "$gpgkeys" -gt 0 ]] && echo "- GPG secret key: present" || echo "- GPG secret key: NONE — commits will fail to sign. As the coordinator, in a terminal (the key has a passphrase):
       gpg --export-secret-keys \"\$(git config --get user.signingkey)\" | sudo -u $LOGIN gpg --batch --import
       sudo -u $LOGIN bash -c \"echo '\$(git config --get user.signingkey):6:' | gpg --import-ownertrust\"" )
   $( [[ "$creds" == yes ]] && echo "- ~/.claude/.credentials.json: present (plain-claude path ready)" || echo "- ~/.claude/.credentials.json: absent — the plain-claude path (--provider anthropic) needs it; the broker path does not:
       sudo install -o $LOGIN -g $GROUP -m 600 ~/.claude/.credentials.json $HOME_DIR/.claude/" )
   - first launch is interactive, to accept the workspace-trust dialog:
       moveto $LOGIN${first:+ $first}   then   runtime/openrouter/launch
EOF

