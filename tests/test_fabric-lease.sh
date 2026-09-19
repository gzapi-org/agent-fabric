#!/usr/bin/env bash
# tests/test_fabric-lease.sh — bin/fabric-lease holds one lease per name
# across processes: a second caller is refused fast and told who holds
# it, or waits when asked; the lease outlives nothing the command leaves
# behind and is gone when the holder exits; --need-mem refuses under a
# forged /proc/meminfo; the missing directory is a refusal that names the
# fix. Against a scratch lease directory.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; ROOT="$(dirname "$HERE")"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/      /'; }
SANDBOX="$(mktemp -d)"; HOLDER=""; trap '[[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
D="$SANDBOX/leases"; mkdir -m 1777 "$D"
lease() { AGENT_FABRIC_LEASES="$D" bash "$ROOT/bin/fabric-lease" "$@"; }

echo "fabric-lease: usage"
out="$(lease 2>&1 >/dev/null)"; rc=$?; [[ $rc -eq 2 ]] && grep -q "^usage:" <<<"$out" && ok "no name: exit 2, usage on stderr" || bad "no name" "rc=$rc $out"
[[ -z "$(lease 2>/dev/null)" ]] && ok "…and nothing on stdout" || bad "usage leaked to stdout"
lease "bad name" -- true 2>/dev/null; [[ $? -eq 2 ]] && ok "a name with a space is refused" || bad "bad name accepted"
lease x --wait abc -- true 2>/dev/null; [[ $? -eq 2 ]] && ok "--wait must be a number" || bad "--wait abc"
out="$(AGENT_FABRIC_LEASES="$SANDBOX/absent" bash "$ROOT/bin/fabric-lease" x -- true 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && grep -q "persist-accounts" <<<"$out" && ok "no lease directory: refused, the fix named" || bad "absent dir" "$out"

echo "fabric-lease: a free lease runs the command and returns its status"
out="$(lease backend-test -- sh -c 'echo ran; exit 3' 2>&1)"; rc=$?
[[ $rc -eq 3 && "$out" == "ran" ]] && ok "command ran, exit status passed through" || bad "run" "rc=$rc $out"
[[ "$(stat -c %a "$D/backend-test")" == 666 ]] && ok "the lease file is 0666 (any login may record itself)" || bad "mode" "$(stat -c %a "$D/backend-test")"
lease backend-test --who >/dev/null; [[ $? -eq 0 ]] && ok "--who: free after the holder exited" || bad "not free after exit"
lease backend-test -- sh -c 'sleep 30 & exit 0' >/dev/null 2>&1
lease backend-test --who >/dev/null; [[ $? -eq 0 ]] && ok "a process the command left behind does not keep the lease" || bad "orphan kept the lease"

echo "fabric-lease: a held lease"
AGENT_FABRIC_LEASES="$D" bash "$ROOT/bin/fabric-lease" backend-test -- sh -c 'echo started; sleep 20' > "$SANDBOX/holder.out" 2>&1 &
HOLDER=$!
for _ in $(seq 50); do grep -q started "$SANDBOX/holder.out" 2>/dev/null && break; sleep 0.1; done
out="$(lease backend-test -- echo second 2>&1)"; rc=$?
[[ $rc -eq 75 ]] && ! grep -q second <<<"$out" && ok "a second caller is refused fast, exit 75, command not run" || bad "second caller" "rc=$rc $out"
grep -q "held by $(id -un) " <<<"$out" && grep -q "backend-test" <<<"$out" && ok "…told who holds it (login, pid, since, name)" || bad "holder not named" "$out"
out="$(lease backend-test --who 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "^held: $(id -un) " <<<"$out" && ok "--who: held, exit 1, the record" || bad "--who held" "rc=$rc $out"
out="$(lease backend-test --wait 1 -- echo second 2>&1)"; rc=$?
[[ $rc -eq 75 ]] && grep -q "still held" <<<"$out" && ok "--wait 1: waits, then says it is still held" || bad "wait" "rc=$rc $out"
out="$(lease other-thing -- echo other 2>&1)"; [[ "$out" == "other" ]] && ok "another name is another lease" || bad "names not independent" "$out"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
lease backend-test --who >/dev/null; [[ $? -eq 0 ]] && ok "the holder killed: the lease is free (the kernel released it)" || bad "stale after kill"
# waiting caller gets it when the holder finishes
AGENT_FABRIC_LEASES="$D" bash "$ROOT/bin/fabric-lease" backend-test -- sh -c 'echo started; sleep 1.5' > "$SANDBOX/holder.out" 2>&1 &
HOLDER=$!; for _ in $(seq 50); do grep -q started "$SANDBOX/holder.out" 2>/dev/null && break; sleep 0.1; done
out="$(lease backend-test --wait 10 -- echo got-it 2>/dev/null)"; [[ "$out" == "got-it" ]] && ok "--wait: runs once the holder finishes" || bad "wait did not acquire" "$out"
wait "$HOLDER" 2>/dev/null; HOLDER=""

echo "fabric-lease: --need-mem"
printf 'MemTotal:       18152000 kB\nMemAvailable:    2048000 kB\n' > "$SANDBOX/meminfo"
out="$(AGENT_FABRIC_MEMINFO="$SANDBOX/meminfo" lease backend-test --need-mem 4096 -- echo ran 2>&1)"; rc=$?
[[ $rc -eq 75 ]] && ! grep -q '^ran$' <<<"$out" && grep -q "needs 4096 MB" <<<"$out" && grep -q "2000 MB available" <<<"$out" && ok "short of memory: refused, exit 75, the numbers said" || bad "need-mem refuse" "rc=$rc $out"
lease backend-test --who >/dev/null; [[ $? -eq 0 ]] && ok "…and the lease released" || bad "lease kept after memory refusal"
out="$(AGENT_FABRIC_MEMINFO="$SANDBOX/meminfo" lease backend-test --need-mem 1024 -- echo ran 2>&1)"
[[ "$out" == "ran" ]] && ok "enough memory: runs" || bad "need-mem pass" "$out"
out="$(AGENT_FABRIC_MEMINFO="$SANDBOX/absent" lease backend-test --need-mem 1024 -- echo ran 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ! grep -q '^ran$' <<<"$out" && grep -q "MemAvailable cannot be read" <<<"$out" && ok "MemAvailable unreadable: refused, exit 2, never skipped" || bad "unreadable meminfo" "rc=$rc $out"
printf 'MemTotal:       18152000 kB\n' > "$SANDBOX/meminfo-noavail"
out="$(AGENT_FABRIC_MEMINFO="$SANDBOX/meminfo-noavail" lease backend-test --need-mem 1024 -- echo ran 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ! grep -q '^ran$' <<<"$out" && ok "no MemAvailable line: the same refusal" || bad "missing MemAvailable" "rc=$rc $out"

echo "fabric-lease: signals and names"
AGENT_FABRIC_LEASES="$D" bash "$ROOT/bin/fabric-lease" backend-test -- sh -c 'echo started; trap "echo child-got-term; exit 0" TERM; while :; do sleep 0.2; done' > "$SANDBOX/holder.out" 2>&1 &
HOLDER=$!; for _ in $(seq 50); do grep -q started "$SANDBOX/holder.out" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
sleep 0.5; grep -q child-got-term "$SANDBOX/holder.out" && ok "TERM to the wrapper reaches the command" || bad "TERM not forwarded" "$(cat "$SANDBOX/holder.out")"
lease backend-test --who >/dev/null; [[ $? -eq 0 ]] && ok "…and the lease is free afterwards" || bad "lease held after TERM"
out="$(lease backend-test -- record 2>&1)"; rc=$?; [[ $rc -eq 127 ]] && ok "a function of the script is not a command (exit 127)" || bad "function ran as command" "rc=$rc $out"

echo
if (( FAIL )); then echo "fabric-lease: $FAIL failure(s), $PASS passed"; exit 1; fi
echo "fabric-lease: $PASS passed"
