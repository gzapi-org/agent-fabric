#!/usr/bin/env bash
# runtime/provisioning/new-agent.sh — give a role its own account on this
# host: everything the control plane can do without a person at a
# terminal, in order, idempotently, then the short list of what only a
# person can do. Run by a fabric-coordinator holder from its own login
# (the account steps go through sudo; the Doppler steps use the
# coordinator's own CLI token).
#
#   runtime/provisioning/new-agent.sh <login> <role> [--project <id>]... [--claude VERSION|stable|latest] [--dry-run]
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
#   0. the host: what this AppVM must already have and what it can hold.
#      A Qubes AppVM keeps only /home and /usr/local across a reboot; a
#      package is the TemplateVM's (dnf there, not here). So: the rpm
#      tools the fabric and the projects use (git, gh, node, npm,
#      python3, jq, gpg, podman, magick) are audited and a missing one is
#      named with its package for the template; doppler goes to
#      /usr/local/bin once (persistent), the account's own tools go under
#      its ~/.local; gzapp's gpg wrapper in /usr/local/bin is checked and
#      named as devex-tooling's to install when absent.
#   1. the Linux account (useradd), home 700, the shared-cache group
#   2. ~/.ssh ~/.claude ~/.config/gh ~/.local/{bin,share}, owned by the
#      account; claude and ori installed AS THE ACCOUNT the way their
#      vendors say — `curl -fsSL https://claude.ai/install.sh | bash -s --
#      latest` — every account, the coordinator included, runs the
#      vendor's latest and the fabric is fixed where latest breaks it
#      (owner, 2026-09-16); --claude pins a version or stable — and `curl -fsSL
#      https://openrouter.ai/labs/ori/install.sh | bash` (stable channel;
#      it has no version pin) — both land in ~/.local/bin. An installer
#      that fails fails the script: nothing is copied from another
#      account in its place (owner, 2026-09-16).
#   3. github.com's published host keys (runtime/provisioning/github-host-keys)
#      in the account's known_hosts — never a keyscan
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
#
# FAILURE SEMANTICS (review, 2026-09-16 — before this, `run x; say done`
# announced success whatever x returned, and a failed useradd, clone,
# bootstrap or bind left a half-made account while later steps went on).
# Not `set -e`: half the lines here are questions. Every step names one
# of three:
#   must         the step is the account: a failure stops the script,
#                naming the step; nothing after it runs
#   probe        a question, never an error (is X present?)
#   best_effort  worth doing, not worth stopping for: a failure is one
#                warning line and the script goes on
# A pipeline that ends in sed/grep is judged by its FIRST command's
# status (${PIPESTATUS[0]}), never by the filter's.
# test_new-agent.sh runs the real sequence against fakes and injects a
# failure at each must.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
REGISTRY="$ROOT/projects/registry.json"
ENROLL="$ROOT/runtime/provisioning/secrets/enroll.sh"
DRY=0; LOGIN=""; ROLE=""; PROJECTS=(); CLAUDE_TARGET=""
while (( $# )); do
    case "$1" in
        --dry-run) DRY=1 ;;
        --claude) CLAUDE_TARGET="$2"; shift ;;
        --claude=*) CLAUDE_TARGET="${1#--claude=}" ;;
        --project) PROJECTS+=("$2"); shift ;;
        --project=*) PROJECTS+=("${1#--project=}") ;;
        -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "new-agent: unknown flag $1" >&2; exit 2 ;;
        *) if [[ -z "$LOGIN" ]]; then LOGIN="$1"; elif [[ -z "$ROLE" ]]; then ROLE="$1"; else echo "new-agent: unexpected argument $1" >&2; exit 2; fi ;;
    esac
    shift
done
[[ -n "$LOGIN" && -n "$ROLE" ]] || { echo "usage: new-agent.sh <login> <role> [--project <id>]... [--claude VERSION|stable|latest] [--dry-run]" >&2; exit 2; }
[[ -z "$CLAUDE_TARGET" || "$CLAUDE_TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+([-.][^[:space:]]+)?)$ ]] || { echo "new-agent: --claude takes stable, latest or a version" >&2; exit 2; }

say() { printf 'new-agent: %s\n' "$*" >&2; }
die() { printf 'new-agent: %s\n' "$*" >&2; exit 1; }
run() { if (( DRY )); then say "would: $*"; else "$@"; fi; }
must() { run "$@" || die "step failed: $* — nothing after it ran; fix the cause and re-run (every step is idempotent)"; }
probe() { "$@"; }
best_effort() { run "$@" || say "warning: $* failed; continuing"; }
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

LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
SUDO="${SUDO:-sudo}"   # a test puts a fake here; the real one is sudo
# One shell line as the account; `must as_login '…'` when the line must succeed.
as_login() { $SUDO -n -u "$LOGIN" -H env -i HOME="$HOME_DIR" PATH="/usr/local/bin:/usr/bin:/bin:$HOME_DIR/.local/bin" bash -lc "cd \"\$HOME\" && $*"; }
(( DRY )) || $SUDO -n true 2>/dev/null || die "sudo without a password is needed for the account steps (this login has none)."

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

# ---- 5. Doppler enrolment ---------------------------------------------------
# A key of the account's own is minted once: issue-* replaces whatever the
# name holds, so a re-run must not mint again. The name's presence in the
# account's config is the check (names only; no value is read).
config_has() {  # config_has <name> — true when the account's config carries it
    # PATH is set explicitly: `env -i` leaves execvp its built-in default
    # (/bin:/usr/bin), which does not reach /usr/local/bin/doppler.
    local cfg; cfg="$($SUDO -n -u "$LOGIN" -H env -i HOME="$HOME_DIR" PATH="/usr/local/bin:/usr/bin:/bin" doppler configure get enclave.config --plain --scope / 2>/dev/null || true)"
    [[ -n "$cfg" ]] || return 1
    doppler secrets --only-names --json --project agent-fabric --config "$cfg" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$1"
}
if (( DRY )); then say "would: enroll.sh $LOGIN; fill-from $COORD $LOGIN; issue-openrouter-keys and issue-openai-keys $LOGIN (each once)"
else
    # First pass: config + token + the strings. Its verification is
    # EXPECTED to report the keys missing (they are issued below), so its
    # exit status is not the fact here — what is, is that a config exists
    # for the account afterwards, which config_has proves through it.
    "$ENROLL" "$LOGIN" >"$LOG" 2>&1
    probe config_has AGENT_LOGIN || { tail -5 "$LOG" >&2; die "step failed: enroll.sh $LOGIN — no Doppler config holds the account (see above); nothing after it ran"; }
    "$ENROLL" fill-from "$COORD" "$LOGIN" 2>&1 | grep -v "^gathered\|^upload" | sed 's/^/   /' >&2
    (( PIPESTATUS[0] == 0 )) || die "step failed: enroll.sh fill-from $COORD $LOGIN; nothing after it ran"
    # Both API keys are per login (projects/registry.json agent_env), so
    # fill-from never copies them and presence means "issued".
    if probe config_has OPENROUTER_API_KEY; then say "   OpenRouter key: present (issued once; not minted again)"
    else "$ENROLL" issue-openrouter-keys "$LOGIN" 2>&1 | tail -1 | sed 's/^/   /' >&2; (( PIPESTATUS[0] == 0 )) || die "step failed: enroll.sh issue-openrouter-keys $LOGIN; nothing after it ran"; fi
    if probe config_has OPENAI_API_KEY; then say "   OpenAI key: present (issued once; not minted again)"
    else "$ENROLL" issue-openai-keys "$LOGIN" 2>&1 | tail -1 | sed 's/^/   /' >&2; (( PIPESTATUS[0] == 0 )) || die "step failed: enroll.sh issue-openai-keys $LOGIN; nothing after it ran"; fi
    "$ENROLL" "$LOGIN" 2>&1 | grep -E "authenticated|signing key|verification|OK$|NOT OK" | sed 's/^/   /' >&2
    (( PIPESTATUS[0] == 0 )) || die "step failed: enroll.sh $LOGIN (sync and verify); nothing after it ran"
    say "5. enrolled; secrets synced"
fi

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
