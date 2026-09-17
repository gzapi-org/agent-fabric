#!/usr/bin/env bash
# runtime/provisioning/persist-accounts.sh — make the named accounts
# survive this host's reboot, the way this platform needs. Root, via sudo,
# on the host the accounts live on; idempotent; run by new-agent-worker.sh
# after useradd and by `bin/fabric-host <host> persist` for every
# placement (the one-time migration of accounts made before this
# existed, 2026-09-17).
#
#   persist-accounts.sh <login>...
#
# Every platform: `loginctl enable-linger <login>`, so the account's user
# manager — and the control agent under it — runs without a login. On a
# Qubes AppVM (platform/fedora-qubes.sh, PERSISTS_ACROSS_REBOOT=0) the
# account records themselves are volatile too: each login's line from
# /etc/{passwd,shadow,group,gshadow,subuid,subgid} is written into the
# snapshot /rw/config/agent-fabric/accounts/ (root, 0600), replacing an
# older line for the same name, and the boot script
# platform/qubes/agent-fabric-accounts.rc is installed under
# /rw/config/rc.local.d/ when absent. Nothing on a persistent platform
# writes a snapshot. Secrets: the shadow line carries a hash, never a
# password; the snapshot directory is root's alone.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
SNAP="${AGENT_FABRIC_ACCOUNTS_SNAPSHOT:-/rw/config/agent-fabric/accounts}"
RCD="${AGENT_FABRIC_RC_LOCAL_D:-/rw/config/rc.local.d}"
ETC="${AGENT_FABRIC_ETC:-/etc}"
LOGINCTL="${AGENT_FABRIC_LOGINCTL:-loginctl}"
[[ $# -ge 1 ]] || { echo "usage: persist-accounts.sh <login>..." >&2; exit 2; }
# shellcheck source=runtime/provisioning/platform/detect.sh
. "$ROOT/runtime/provisioning/platform/detect.sh"
rc=0
for login in "$@"; do
    if ! getent passwd "$login" >/dev/null 2>&1 && ! grep -q "^$login:" "$ETC/passwd" 2>/dev/null; then
        echo "persist-accounts: no such account: $login" >&2; rc=1; continue
    fi
    if (( PERSISTS_ACROSS_REBOOT == 0 )); then
        install -d -m 700 "$SNAP" || { rc=1; continue; }
        for f in passwd shadow group gshadow subuid subgid; do
            [[ -f "$ETC/$f" ]] || continue
            line="$(grep "^$login:" "$ETC/$f" | head -1)"
            [[ -n "$line" ]] || continue
            tmp="$(mktemp "$SNAP/.$f.XXXXXX")"
            { [[ -f "$SNAP/$f" ]] && grep -v "^$login:" "$SNAP/$f"; printf '%s\n' "$line"; } > "$tmp"
            install -m 600 "$tmp" "$SNAP/$f"; rm -f "$tmp"
        done
        if [[ ! -f "$RCD/agent-fabric-accounts.rc" ]]; then
            install -d -m 755 "$RCD"
            install -m 755 "$ROOT/runtime/provisioning/platform/qubes/agent-fabric-accounts.rc" "$RCD/agent-fabric-accounts.rc"
        fi
    fi
    "$LOGINCTL" enable-linger "$login" 2>/dev/null || { echo "persist-accounts: enable-linger failed for $login" >&2; rc=1; }
done
exit "$rc"
