#!/usr/bin/env bash
# runtime/hostexec/test_hostexec.sh — one command, two backends, the same
# result. A fixture registry with the local host and a remote one; a fake
# ssh that records what it was asked and runs the remote line in a local
# shell (so the SAME worker runs, as it would on the target); a fake sudo
# that drops `-n -u X -H` and runs the rest. What is proved: the backend
# is the registry's choice, the remote line quotes every word, stdin and
# the exit status pass through both backends, --as reaches the worker,
# @fabric/ resolves on the target, a host absent from the registry is a
# refusal, and fabric-host's check compares what the host reports with
# the id it was reached as.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
HX="$HERE/hostexec"; FH="$ROOT/bin/fabric-host"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/      /'; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"; mkdir -p "$BIN"; SSHLOG="$SANDBOX/ssh.log"
ME="$(id -un)"; LOCAL="$(hostname -s)"
REG="$SANDBOX/registry.json"
cat > "$REG" <<EOF
{"version": 1,
 "hosts": {"$LOCAL": {"platform": "fedora-qubes", "ssh": null, "operator": "$ME", "fabric": "$ROOT"},
           "far-host": {"platform": "debian", "ssh": "op@far.example", "operator": "op", "fabric": "$ROOT"}},
 "placement": {"$ME": "$LOCAL", "zz-far-login": "far-host"}}
EOF
# The fake ssh: `ssh -o BatchMode=yes [-t] <dest> -- <line>` → record, then
# run <line> through a local shell, as the remote operator's shell would.
cat > "$BIN/ssh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSHLOG"
args=("\$@"); line="\${args[-1]}"
grep -qsxF down "$SANDBOX/fault" && { echo "ssh: connect to host far.example port 22: Connection refused" >&2; exit 255; }
exec bash -c "\$line"
STUB
cat > "$BIN/sudo" <<STUB
#!/usr/bin/env bash
[[ "\$1" == -n ]] && shift; [[ "\$1" == -u ]] && { echo "sudo-as \$2" >> "$SANDBOX/sudo.log"; shift 2; }; [[ "\$1" == -H ]] && shift
exec "\$@"
STUB
cat > "$BIN/getent" <<STUB
#!/usr/bin/env bash
[[ "\$1" == passwd && "\$2" == zz-far-login ]] && { echo "zz-far-login:x:1000:1000::$SANDBOX/home/zz-far-login:/bin/bash"; exit 0; }
exec /usr/bin/getent "\$@"
STUB
chmod +x "$BIN"/*; mkdir -p "$SANDBOX/home/zz-far-login"
export PATH="$BIN:/usr/bin:/bin" AGENT_FABRIC_HOSTS_REGISTRY="$REG" SUDO="$BIN/sudo" SSH="$BIN/ssh"

echo "hostexec: the backend is the registry's choice"
out="$("$HX" --resolve "$LOCAL")"; grep -q "backend local" <<<"$out" && ok "the local host resolves to the local backend" || bad "local resolve" "$out"
out="$("$HX" --resolve far-host)"; grep -q "backend ssh, destination op@far.example" <<<"$out" && ok "another host resolves to ssh with its destination" || bad "ssh resolve" "$out"
out="$("$HX" nowhere -- true 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && grep -q "unknown host 'nowhere'" <<<"$out" && grep -q "far-host" <<<"$out" && ok "an unregistered host is a refusal naming the known ones" || bad "unknown host not refused (rc=$rc)" "$out"

echo "hostexec: the same command, both backends"
out="$("$HX" "$LOCAL" -- sh -c 'echo "local:$(id -un)"')"; [[ "$out" == "local:$ME" ]] && ok "local: runs as the operator" || bad "local run" "$out"
[[ ! -s "$SSHLOG" ]] && ok "…and ssh was never called for the local host" || bad "ssh called for the local host" "$(cat "$SSHLOG")"
out="$("$HX" far-host -- sh -c 'echo "far:$(id -un)"')"; [[ "$out" == "far:$ME" ]] && ok "ssh: the worker ran on the far side (here, through the fake)" || bad "ssh run" "$out"
grep -q -- "-o BatchMode=yes op@far.example -- $ROOT/runtime/hostexec/worker" "$SSHLOG" && ok "…as: ssh -o BatchMode=yes <destination> -- <fabric>/runtime/hostexec/worker" || bad "ssh argv" "$(cat "$SSHLOG")"
: > "$SSHLOG"
out="$("$HX" far-host -- printf '%s|' 'two words' "it's" 'a"b' '$HOME')"; [[ "$out" == "two words|it's|a\"b|\$HOME|" ]] && ok "every word reaches the far side whole (spaces, quotes, no expansion)" || bad "quoting" "$out"
for h in "$LOCAL" far-host; do
    out="$(printf 'secret-on-stdin\n' | "$HX" "$h" -- cat)"; [[ "$out" == "secret-on-stdin" ]] && ok "$h: stdin passes through" || bad "$h stdin" "$out"
    "$HX" "$h" -- sh -c 'exit 7'; rc=$?; [[ $rc -eq 7 ]] && ok "$h: the exit status is the command's" || bad "$h exit status" "rc=$rc"
done
! grep -q "secret-on-stdin" "$SSHLOG" && ok "…and never in argv" || bad "stdin value reached argv" "$(cat "$SSHLOG")"

echo "hostexec: --as, --cwd, @fabric/"
out="$("$HX" far-host --as zz-far-login -- sh -c 'echo "$HOME|$PWD"')"
[[ "$out" == "$SANDBOX/home/zz-far-login|$SANDBOX/home/zz-far-login" ]] && grep -q "sudo-as zz-far-login" "$SANDBOX/sudo.log" && ok "--as reaches the worker: sudo -u, HOME and cwd the account's" || bad "--as" "$out"
out="$("$HX" "$LOCAL" --cwd /tmp -- pwd)"; [[ "$out" == /tmp ]] && ok "--cwd sets the directory (operator)" || bad "--cwd" "$out"
out="$("$HX" far-host -- @fabric/runtime/hostexec/worker -- echo via-fabric)"; [[ "$out" == via-fabric ]] && ok "@fabric/<rel> resolves on the target host (the operator's checkout)" || bad "@fabric" "$out"
out="$("$HX" far-host --as zz-far-login -- @fabric/x 2>&1)"; rc=$?; [[ $rc -eq 2 ]] && grep -q "no fabric checkout at $SANDBOX/home/zz-far-login/projects/agent-fabric" <<<"$out" && ok "…as an account: the account's own checkout, refused when it has none" || bad "@fabric as account (rc=$rc)" "$out"
mkdir -p "$SANDBOX/home/zz-far-login/projects/agent-fabric/bin"; printf '#!/usr/bin/env bash\necho mine\n' > "$SANDBOX/home/zz-far-login/projects/agent-fabric/bin/probe"; chmod +x "$SANDBOX/home/zz-far-login/projects/agent-fabric/bin/probe"
out="$("$HX" far-host --as zz-far-login -- @fabric/bin/probe)"; [[ "$out" == mine ]] && ok "…and resolves there when it exists" || bad "@fabric as account resolve" "$out"
: > "$SSHLOG"; "$HX" far-host --tty -- true; grep -q -- " -t op@far.example " "$SSHLOG" && ok "--tty asks ssh for a terminal (-t)" || bad "--tty" "$(cat "$SSHLOG")"

echo "hostexec: the connection drops"
printf 'down\n' > "$SANDBOX/fault"
out="$("$HX" far-host -- true 2>&1)"; rc=$?; [[ $rc -eq 255 ]] && grep -q "Connection refused" <<<"$out" && ok "ssh's failure is the caller's, with its status" || bad "ssh down (rc=$rc)" "$out"
rm -f "$SANDBOX/fault"

echo "fabric-host"
out="$("$FH" list)"; grep -q "far-host.*ssh op@far.example" <<<"$out" && grep -q "accounts: zz-far-login" <<<"$out" && ok "list: hosts with their placements" || bad "list" "$out"
out="$("$FH" "$LOCAL" check)"; [[ $? -eq 0 ]] && grep -q "answers as $LOCAL" <<<"$out" && ok "check: this host answers as its id" || bad "check local" "$out"
out="$("$FH" far-host check 2>&1)"; rc=$?; [[ $rc -eq 1 ]] && grep -q "answers as '$LOCAL'" <<<"$out" && grep -q "registry id is the host's short hostname" <<<"$out" \
  && ok "check: a host answering under another name is refused (the fake far host is this machine)" || bad "check far (rc=$rc)" "$out"
out="$("$FH" far-host run --as zz-far-login -- sh -c 'echo "$HOME"')"; [[ "$out" == "$SANDBOX/home/zz-far-login" ]] && ok "run: hostexec with --as" || bad "run" "$out"
: > "$SSHLOG"; "$FH" far-host rename zz-far-login old new --dry-run >/dev/null 2>&1
grep -q "@fabric/runtime/provisioning/rename-working-copy.sh zz-far-login old new --dry-run" "$SSHLOG" && ok "rename: the target's own rename-working-copy.sh" || bad "rename argv" "$(cat "$SSHLOG")"
: > "$SSHLOG"; "$FH" far-host drain zz-far-login --dry-run >/dev/null 2>&1
grep -q -- "--as zz-far-login -- python3 @fabric/tools/fabric/harvest_memory.py --bundle - --dry-run" "$SSHLOG" && ok "drain: the account's own harvest, as the account, bundle to stdout" || bad "drain argv" "$(cat "$SSHLOG")"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_hostexec: OK — $PASS assertion(s) passed."; else echo "test_hostexec: FAILED — $FAIL assertion(s) failed."; exit 1; fi
