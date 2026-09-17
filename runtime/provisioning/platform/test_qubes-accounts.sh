#!/usr/bin/env bash
# Behavioural tests for the account persistence on a volatile root:
# runtime/provisioning/platform/qubes/agent-fabric-accounts.rc (the boot
# script) and runtime/provisioning/persist-accounts.sh (the snapshot
# writer), against a scratch /etc, snapshot dir and a fake loginctl.
#
# What this holds still: the boot script appends every snapshotted record
# a fresh /etc lacks, verbatim, never duplicates one already there, skips
# a uid or gid the template has meanwhile taken and says so, and enables
# linger for each re-added login; the writer replaces or appends one line
# per login per file, is idempotent, installs the boot script once, and
# on a persistent platform writes no snapshot and only enables linger.
set -uo pipefail
HERE="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(cd "$HERE/../../.." && pwd)"
RC="$HERE/qubes/agent-fabric-accounts.rc"
WRITER="$ROOT/runtime/provisioning/persist-accounts.sh"
failures=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1" >&2; [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2; failures=$((failures + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc" "$T/snap" "$T/rcd" "$T/bin"
cat > "$T/bin/loginctl" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOGINCTL_LOG:?}"
F
chmod +x "$T/bin/loginctl"
export LOGINCTL_LOG="$T/loginctl.log"
export AGENT_FABRIC_ETC="$T/etc" AGENT_FABRIC_ACCOUNTS_SNAPSHOT="$T/snap" AGENT_FABRIC_RC_LOCAL_D="$T/rcd" AGENT_FABRIC_LOGINCTL="$T/bin/loginctl"

# a boot's /etc: the template's users, none of ours
printf 'root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000::/home/user:/bin/bash\n' > "$T/etc/passwd"
printf 'root:*:1:0:99999:7:::\nuser:*:1:0:99999:7:::\n' > "$T/etc/shadow"
printf 'root:x:0:\nuser:x:1000:\notscache:x:990:user\n' > "$T/etc/group"
printf 'root:::\nuser:::\n' > "$T/etc/gshadow"
printf 'user:100000:65536\n' > "$T/etc/subuid"; printf 'user:100000:65536\n' > "$T/etc/subgid"
# the snapshot: two fabric accounts, one of which collides with a template uid
printf 'db-admin:x:1004:1004:agent-fabric db-admin:/home/db-admin:/bin/bash\nbrand-comms-01:x:1000:1014:agent-fabric brand-comms:/home/brand-comms-01:/bin/bash\n' > "$T/snap/passwd"
printf 'db-admin:$6$hash:20000:0:99999:7:::\nbrand-comms-01:$6$hash2:20000:0:99999:7:::\n' > "$T/snap/shadow"
printf 'db-admin:x:1004:\nbrand-comms-01:x:1014:\n' > "$T/snap/group"
printf 'db-admin:!::\n' > "$T/snap/gshadow"
printf 'db-admin:200000:65536\nbrand-comms-01:300000:65536\n' > "$T/snap/subuid"; cp "$T/snap/subuid" "$T/snap/subgid"
printf 'db-admin:otscache,nosuchgroup\nbrand-comms-01:otscache\nweb-dev-02:otscache\n' > "$T/snap/members"
# a third whose uid is free but whose primary gid the template gave to another group
printf 'web-dev-02:x:1009:990:agent-fabric web-dev:/home/web-dev-02:/bin/bash\n' >> "$T/snap/passwd"
printf 'web-dev-02:$6$hash3:20000:0:99999:7:::\n' >> "$T/snap/shadow"; printf 'web-dev-02:x:990:\n' >> "$T/snap/group"

echo "boot script: re-adds what /etc lacks, verbatim, and enables linger"
err="$(sh "$RC" 2>&1 >/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0" || bad "rc=$rc" "$err"
grep -qx 'db-admin:x:1004:1004:agent-fabric db-admin:/home/db-admin:/bin/bash' "$T/etc/passwd" && ok "passwd line appended verbatim" || bad "passwd" "$(cat "$T/etc/passwd")"
grep -qx 'db-admin:$6$hash:20000:0:99999:7:::' "$T/etc/shadow" && ok "shadow line appended verbatim" || bad "shadow" "$(cat "$T/etc/shadow")"
grep -qx 'db-admin:x:1004:' "$T/etc/group" && grep -qx 'db-admin:!::' "$T/etc/gshadow" && ok "group and gshadow appended" || bad "group/gshadow"
! grep -q '^brand-comms-01:' "$T/etc/passwd" && grep -q "uid 1000 is taken" <<<"$err" && ok "a uid the template took is skipped, loudly" || bad "collision not skipped" "$err"
! grep -q '^brand-comms-01:' "$T/etc/shadow" "$T/etc/group" "$T/etc/subuid" "$T/etc/subgid" && ok "…and none of its other records go in" || bad "orphan records for the skipped login" "$(grep -n brand-comms-01 "$T/etc"/*)"
! grep -q '^web-dev-02:' "$T/etc/passwd" "$T/etc/shadow" "$T/etc/group" && grep -q "gid 990 is taken" <<<"$err" && ok "a gid the template gave another group skips the login whole, loudly" || bad "gid collision" "$err"
! grep -q 'web-dev-02' "$T/etc/group" "$LOGINCTL_LOG" && ok "…no membership, no linger for it" || bad "gid-skipped login got membership or linger"
grep -qx 'db-admin:200000:65536' "$T/etc/subuid" && grep -qx 'db-admin:200000:65536' "$T/etc/subgid" && ok "subuid and subgid appended" || bad "subids"
grep -qx 'otscache:x:990:user,db-admin' "$T/etc/group" && ok "supplementary group membership restored (members)" || bad "members" "$(cat "$T/etc/group")"
! grep -q 'brand-comms-01' "$T/etc/group" && ok "…not for the skipped login" || bad "skipped login joined a group"
! grep -q nosuchgroup "$T/etc/group" && ok "…and a group the boot lacks is left alone" || bad "nosuchgroup"
grep -qx 'enable-linger db-admin' "$LOGINCTL_LOG" && ! grep -q 'brand-comms-01' "$LOGINCTL_LOG" && ok "linger enabled for the re-added login only" || bad "linger" "$(cat "$LOGINCTL_LOG")"
[[ "$(grep -c '^user:' "$T/etc/passwd")" == 1 && "$(grep -c '^root:' "$T/etc/passwd")" == 1 ]] && ok "the template's own lines untouched" || bad "template lines changed"
n1="$(wc -l < "$T/etc/passwd")"; sh "$RC" 2>/dev/null; n2="$(wc -l < "$T/etc/passwd")"
[[ "$n1" == "$n2" && "$(grep -c '^db-admin:' "$T/etc/passwd")" == 1 ]] && ok "a second boot appends nothing twice" || bad "duplicated on second run"
grep -qx 'otscache:x:990:user,db-admin' "$T/etc/group" && ok "…nor a membership twice" || bad "membership duplicated" "$(cat "$T/etc/group")"
: > "$LOGINCTL_LOG"; rm -rf "$T/snap"; sh "$RC"; [[ $? -eq 0 && ! -s "$LOGINCTL_LOG" ]] && ok "no snapshot: nothing done, exit 0" || bad "no snapshot"

echo "writer: one line per login per file, replace-or-append, the boot script installed once"
mkdir -p "$T/snap"; : > "$LOGINCTL_LOG"
# a live /etc with our accounts present (the writer reads from it)
printf 'edge-hosting:x:1011:1011:agent-fabric edge-hosting:/home/edge-hosting:/bin/bash\n' >> "$T/etc/passwd"
printf 'edge-hosting:$6$eh:20001:0:99999:7:::\n' >> "$T/etc/shadow"
printf 'edge-hosting:x:1011:\n' >> "$T/etc/group"
sed -i 's/^otscache:x:990:user,db-admin$/otscache:x:990:user,db-admin,edge-hosting/' "$T/etc/group"
# the platform: the Qubes profile (volatile root)
export AGENT_FABRIC_PLATFORM=fedora-qubes     # detect.sh honours the override
run_writer() { bash "$WRITER" "$@"; }
out="$(run_writer db-admin edge-hosting 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "exits 0" || bad "rc=$rc" "$out"
grep -qx 'edge-hosting:x:1011:1011:agent-fabric edge-hosting:/home/edge-hosting:/bin/bash' "$T/snap/passwd" && ok "the live passwd line is snapshotted" || bad "snapshot passwd" "$(cat "$T/snap/passwd")"
grep -qx 'edge-hosting:$6$eh:20001:0:99999:7:::' "$T/snap/shadow" && ok "…and shadow" || bad "snapshot shadow"
[[ "$(stat -c %a "$T/snap/passwd")" == 600 && "$(stat -c %a "$T/snap")" == 700 ]] && ok "snapshot files 600 in a 700 directory" || bad "modes" "$(stat -c '%a %n' "$T/snap" "$T/snap"/*)"
( exec 9>"$T/snap/.lock"; flock 9; out="$(AGENT_FABRIC_LOCK_WAIT=1 bash "$WRITER" db-admin 2>&1)"; [[ $? -ne 0 ]] && grep -q "locked by another writer" <<<"$out" ) && ok "a second writer waits for the lock and says so when it does not come" || bad "no lock"

[[ -x "$T/rcd/agent-fabric-accounts.rc" ]] && ok "the boot script is installed" || bad "boot script not installed"
grep -qx 'edge-hosting:otscache' "$T/snap/members" && grep -qx 'db-admin:otscache' "$T/snap/members" && ok "supplementary groups snapshotted (members)" || bad "members" "$(cat "$T/snap/members")"
echo '# stale' > "$T/rcd/agent-fabric-accounts.rc"; run_writer db-admin >/dev/null 2>&1
cmp -s "$RC" "$T/rcd/agent-fabric-accounts.rc" && ok "an installed boot script that differs is refreshed" || bad "stale boot script kept"
[[ -z "$(ls -A "$T/snap" | grep '^\.' | grep -v '^\.lock$')" ]] && ok "no temporary file left in the snapshot" || bad "temp files" "$(ls -A "$T/snap")"
grep -qx 'enable-linger db-admin' "$LOGINCTL_LOG" && grep -qx 'enable-linger edge-hosting' "$LOGINCTL_LOG" && ok "linger enabled for each" || bad "linger" "$(cat "$LOGINCTL_LOG")"
sed -i 's|^edge-hosting:x:1011:1011:agent-fabric edge-hosting|edge-hosting:x:1011:1011:renamed|' "$T/etc/passwd"
run_writer edge-hosting >/dev/null 2>&1
[[ "$(grep -c '^edge-hosting:' "$T/snap/passwd")" == 1 ]] && grep -q 'renamed' "$T/snap/passwd" && ok "a changed line replaces the old one, never a second" || bad "replace" "$(cat "$T/snap/passwd")"
[[ "$(grep -c '^db-admin:' "$T/snap/passwd")" == 1 ]] && ok "other logins' lines kept" || bad "other lines lost"
out="$(run_writer no-such-login 2>&1)"; [[ $? -ne 0 ]] && grep -q "no such account" <<<"$out" && ok "an unknown login is refused, named" || bad "unknown login" "$out"

echo "writer on a persistent platform: linger only, no snapshot"
rm -rf "$T/snap" "$T/rcd"; : > "$LOGINCTL_LOG"; export AGENT_FABRIC_PLATFORM=fedora
run_writer db-admin >/dev/null 2>&1
[[ ! -e "$T/snap" && ! -e "$T/rcd" ]] && grep -qx 'enable-linger db-admin' "$LOGINCTL_LOG" && ok "no snapshot written; linger enabled" || bad "persistent platform" "$(ls -la "$T"; cat "$LOGINCTL_LOG")"

if (( failures )); then echo "qubes accounts: $failures failure(s)" >&2; exit 1; fi
echo "qubes accounts: OK — all assertions passed."
