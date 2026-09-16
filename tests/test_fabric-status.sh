#!/usr/bin/env bash
# tests/test_fabric-status.sh — bin/fabric-status says what this session was
# launched as, and says DRIFT when the binding, the session default or the
# prompt file moved under it. Runs the real script against a throwaway
# state dir; the stamps a launch exports are forged in the environment.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; ROOT="$(dirname "$HERE")"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/      /'; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
STATE="$SANDBOX/state"; LOGIN="$(id -un)"
mkdir -p "$STATE/agents/$LOGIN"
printf '{"agent":"%s","host":"'"$(hostname -s)"'","role":"db-admin","updated_at":"x"}\n' "$LOGIN" > "$STATE/agents/$LOGIN/binding.json"
printf 'prompt text\n' > "$STATE/agents/$LOGIN/launch-prompt.md"
DIGEST="sha256:$(sha256sum "$STATE/agents/$LOGIN/launch-prompt.md" | cut -d' ' -f1)"

# Nothing a real session exported may leak into the forged one.
status() { env -u AGENT_FABRIC_LAUNCH_ROLE -u AGENT_FABRIC_LAUNCH_PROMPT_DIGEST -u AGENT_FABRIC_LAUNCH_SESSION_MODEL \
               -u AGENT_FABRIC_LAUNCH_PROVIDER -u AGENT_FABRIC_LAUNCH_PROFILE -u ANTHROPIC_BASE_URL \
               AGENT_FABRIC_STATE_DIR="$STATE" "$@" bash "$ROOT/bin/fabric-status" "${MODE[@]}"; }
MODE=()

echo "fabric-status: unlaunched — nothing to drift from"
out="$(status 2>&1)"
grep -q "^role         db-admin" <<<"$out" && ok "the bound role" || bad "role missing" "$out"
! grep -q "DRIFT\|launched as" <<<"$out" && ok "no launch stamp: no drift line, no 'launched as'" || bad "drift without a stamp" "$out"

echo "fabric-status: launched as the bound role, prompt intact"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROMPT_DIGEST="$DIGEST" AGENT_FABRIC_LAUNCH_PROVIDER=anthropic 2>&1)"
grep -q "^launched as  db-admin    prompt $DIGEST" <<<"$out" && ok "says what it was launched as, with the prompt digest" || bad "no launched-as line" "$out"
! grep -q "DRIFT" <<<"$out" && ok "…and no drift" || bad "false drift" "$out"

echo "fabric-status: the binding moved under the session"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=backend-dev AGENT_FABRIC_LAUNCH_PROMPT_DIGEST="$DIGEST" 2>&1)"
grep -q "^DRIFT        launched as backend-dev, binding now db-admin" <<<"$out" && grep -q "relaunch to hold db-admin" <<<"$out" && ok "role drift is one DRIFT line naming both and the fix" || bad "role drift not said" "$out"
MODE=(--json); out="$(status AGENT_FABRIC_LAUNCH_ROLE=backend-dev 2>&1)"; MODE=()
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["launched_role"]=="backend-dev" and any("binding now db-admin" in x for x in d["drift"])' <<<"$out" && ok "…and in the JSON report" || bad "json report lacks drift" "$out"

echo "fabric-status: the prompt file moved under the session"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROMPT_DIGEST=sha256:0000 2>&1)"
grep -q "^DRIFT        the prompt file was rewritten since launch" <<<"$out" && ok "a digest mismatch is said" || bad "prompt drift not said" "$out"
rm "$STATE/agents/$LOGIN/launch-prompt.md"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROMPT_DIGEST="$DIGEST" 2>&1)"
grep -q "^DRIFT        the launched prompt file is gone" <<<"$out" && ok "a missing file is said, not a crash" || bad "missing prompt file" "$out"

echo "fabric-status: the session default moved under the session"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROVIDER=anthropic AGENT_FABRIC_LAUNCH_SESSION_MODEL=claude-sonnet-5 2>&1)"
grep -q "^DRIFT        launched on claude-sonnet-5, the anthropic session now resolves to" <<<"$out" && grep -q "relaunch to apply" <<<"$out" && ok "a changed session default is said with the current resolution" || bad "session drift not said" "$out"
current="$(grep "the anthropic session now resolves to" <<<"$out" | sed 's/.*resolves to \([^ ]*\) .*/\1/')"
out="$(status AGENT_FABRIC_LAUNCH_ROLE=db-admin AGENT_FABRIC_LAUNCH_PROVIDER=anthropic AGENT_FABRIC_LAUNCH_SESSION_MODEL="$current" 2>&1)"
! grep -q "launched on" <<<"$out" && ok "launched on what now resolves: no drift" || bad "false session drift" "$out"

echo "fabric-status: the account's placement"
HOSTS="$SANDBOX/hosts.json"
printf '{"version":1,"hosts":{"%s":{"platform":"fedora-qubes","ssh":null,"operator":"%s","fabric":"x"},"other-host":{"platform":"debian","ssh":"op@other","operator":"op","fabric":"x"}},"placement":{"%s":"%s"}}\n' "$(hostname -s)" "$LOGIN" "$LOGIN" "$(hostname -s)" > "$HOSTS"
out="$(status AGENT_FABRIC_HOSTS_REGISTRY="$HOSTS" 2>&1)"
! grep -q "registered on\|not placed" <<<"$out" && ok "placed on this host: no drift" || bad "false placement drift" "$out"
printf '{"version":1,"hosts":{"%s":{"platform":"fedora-qubes","ssh":null,"operator":"%s","fabric":"x"},"other-host":{"platform":"debian","ssh":"op@other","operator":"op","fabric":"x"}},"placement":{"%s":"other-host"}}\n' "$(hostname -s)" "$LOGIN" "$LOGIN" > "$HOSTS"
out="$(status AGENT_FABRIC_HOSTS_REGISTRY="$HOSTS" 2>&1)"
grep -q "^DRIFT        registered on other-host, running on $(hostname -s)" <<<"$out" && ok "placed elsewhere: one DRIFT line naming both hosts" || bad "placement drift not said" "$out"
MODE=(--json); out="$(status AGENT_FABRIC_HOSTS_REGISTRY="$HOSTS" 2>&1)"; MODE=()
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["placement"]=="other-host" and any("registered on other-host" in x for x in d["drift"])' <<<"$out" && ok "…and in the JSON report" || bad "json lacks placement" "$out"
printf '{"version":1,"hosts":{"%s":{"platform":"fedora-qubes","ssh":null,"operator":"%s","fabric":"x"}},"placement":{}}\n' "$(hostname -s)" "$LOGIN" > "$HOSTS"
out="$(status AGENT_FABRIC_HOSTS_REGISTRY="$HOSTS" 2>&1)"
grep -q "^DRIFT        not placed in runtime/hosts/registry.json" <<<"$out" && ok "not placed at all: said" || bad "missing placement not said" "$out"

echo "fabric-status: moveto installed from this repository, or behind it"
PREFIX="$SANDBOX/usr-local"
MOVETO_PREFIX="$PREFIX" sh "$ROOT/runtime/provisioning/moveto/install.sh" >/dev/null && ok "install.sh installs under \$MOVETO_PREFIX" || bad "install.sh failed"
[[ -s "$PREFIX/share/moveto/installed.sha256" ]] && ( cd "$PREFIX" && sha256sum -c --quiet share/moveto/installed.sha256 ) && ok "…and records a manifest that checks out" || bad "no manifest, or it does not check out"
out="$(status MOVETO_PREFIX="$PREFIX" 2>&1)"
grep -q "^moveto       in sync" <<<"$out" && ok "a fresh install is in sync" || bad "fresh install reported otherwise" "$out"
printf '\n# local edit\n' >> "$PREFIX/share/moveto/enter"
out="$(status MOVETO_PREFIX="$PREFIX" 2>&1)"
grep -q "^moveto       drift: behind the repository: share/moveto/enter" <<<"$out" && grep -q "edited in place since install: share/moveto/enter" <<<"$out" \
  && grep -q "install.sh" <<<"$out" && ok "an installed copy that differs is said, with the file, the cause and the fix" || bad "moveto drift not said" "$out"
MODE=(--json); out="$(status MOVETO_PREFIX="$PREFIX" 2>&1)"; MODE=()
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["host_tools"]["moveto"]["status"]=="drift"' <<<"$out" && ok "…and in the JSON report" || bad "json lacks host_tools" "$out"
out="$(status MOVETO_PREFIX="$SANDBOX/nowhere" 2>&1)"
! grep -q "^moveto" <<<"$out" && ok "no moveto under the prefix: no line" || bad "a line for an absent tool" "$out"

echo "fabric-status: memories written and not yet drained"
WC="$SANDBOX/gzapp"; git init -q "$WC"; git -C "$WC" remote add origin git@github.com:gzapi-org/gzapp.git
MEM="$SANDBOX/home/.claude/projects/$(printf '%s' "$WC" | tr / -)/memory"; mkdir -p "$MEM" "$WC/.agent-fabric/memory"
printf '{"watermarks":{"%s":1000}}\n' "$(hostname -s)" > "$WC/.agent-fabric/memory/last-drain-report.json"
printf -- '---\nname: a\ndescription: d\nmetadata:\n  type: project\n  roles_class: solution\n---\nfact\n' > "$MEM/a.md"
printf -- '---\nname: b\ndescription: d\nmetadata:\n  type: user\n---\nmine\n' > "$MEM/b.md"
printf '# index\n' > "$MEM/MEMORY.md"
out="$(cd "$WC" && HOME="$SANDBOX/home" status 2>&1)"
grep -q "^memory       1 drainable (roles_class set) and 1 private (none) written since the last drain" <<<"$out" && ok "counts drainable and private memories newer than the watermark; MEMORY.md is not a memory" || bad "memory line wrong" "$out"
rm "$WC/.agent-fabric/memory/last-drain-report.json"
out="$(cd "$WC" && HOME="$SANDBOX/home" status 2>&1)"
grep -q "written since ever (no drain report)" <<<"$out" && ok "no report: counted since ever, said so" || bad "no-report case" "$out"
out="$(cd "$SANDBOX" && status 2>&1)"
! grep -q "^memory " <<<"$out" && ok "outside a working copy: no memory line" || bad "memory line without a working copy" "$out"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_fabric-status: OK — $PASS assertion(s) passed."; else echo "test_fabric-status: FAILED — $FAIL assertion(s) failed."; exit 1; fi
