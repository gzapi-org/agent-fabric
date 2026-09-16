#!/usr/bin/env bash
# runtime/provisioning/test_rename-working-copy.sh — the shell half of
# the rename: it refuses before touching anything, stops where a step
# fails, and hands the history to rename_history.py only once the tree
# is at its new path. Fakes for sudo (runs the rest as this user),
# getent (a sandbox home), pgrep (a live session, when asked) and mv (a
# failure, when asked); the Python half is tests/test_rename_history.py.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
UNDER_TEST="$HERE/rename-working-copy.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/      /'; }
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"; mkdir -p "$BIN"; FAULT="$SANDBOX/fault"
LOGIN="zz-rename-fixture"; HOME_L="$SANDBOX/home/$LOGIN"
cat > "$BIN/sudo" <<STUB
#!/usr/bin/env bash
[[ "\$1" == -u ]] && shift 2; [[ "\$1" == -H ]] && shift
args=(); for a in "\$@"; do [[ "\$a" == PATH=* ]] && a="PATH=$BIN:\${a#PATH=}"; args+=("\$a"); done
exec "\${args[@]}"
STUB
cat > "$BIN/getent" <<STUB
#!/usr/bin/env bash
[[ "\$1" == passwd && "\$2" == "$LOGIN" ]] && { echo "$LOGIN:x:1000:1000::$HOME_L:/bin/bash"; exit 0; }; exit 2
STUB
cat > "$BIN/pgrep" <<STUB
#!/usr/bin/env bash
grep -qsxF live "$FAULT"
STUB
cat > "$BIN/mv" <<STUB
#!/usr/bin/env bash
grep -qsxF mv "$FAULT" && { echo "mv: injected failure" >&2; exit 1; }
exec /usr/bin/mv "\$@"
STUB
chmod +x "$BIN"/*
export PATH="$BIN:/usr/bin:/bin"

reset() {
  rm -rf "$HOME_L" "$FAULT"; mkdir -p "$HOME_L/projects/old" "$HOME_L/.claude/projects" "$HOME_L/state/agents/$LOGIN"
  git -C "$HOME_L/projects/old" init -q -b main; printf 'x\n' > "$HOME_L/projects/old/f"; git -C "$HOME_L/projects/old" add f
  git -C "$HOME_L/projects/old" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m init
  ln -s "$ROOT" "$HOME_L/projects/agent-fabric"
  local k; k="$(printf '%s' "$HOME_L/projects/old" | tr / -)"; mkdir -p "$HOME_L/.claude/projects/$k"
  printf '{"cwd":"%s"}\n' "$HOME_L/projects/old" > "$HOME_L/.claude/projects/$k/s.jsonl"
}
rename() { SUDO="$BIN/sudo" AGENT_FABRIC_STATE_DIR="$HOME_L/state" bash "$UNDER_TEST" "$LOGIN" old new "$@" 2>&1; }
old_key() { printf '%s' "$HOME_L/projects/old" | tr / -; }
new_key() { printf '%s' "$HOME_L/projects/new" | tr / -; }

echo "rename: the whole path"
reset; out="$(rename)"; rc=$?
[[ $rc -eq 0 && -d "$HOME_L/projects/new/.git" && ! -e "$HOME_L/projects/old" ]] && ok "the tree moved" || bad "tree not moved (rc=$rc)" "$out"
[[ -d "$HOME_L/.claude/projects/$(new_key)" && ! -d "$HOME_L/.claude/projects/$(old_key)" ]] && grep -q "projects/new" "$HOME_L/.claude/projects/$(new_key)/s.jsonl" \
  && ok "…and the history followed, cwd rewritten" || bad "history not moved" "$out"
out="$(rename)"; rc=$?; [[ $rc -eq 0 ]] && grep -q "already at" <<<"$out" && ok "a second run says already at the new path" || bad "not idempotent" "$out"

echo "rename: refusals before anything moves"
reset; printf 'live\n' > "$FAULT"; out="$(rename)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "live claude session" <<<"$out" && [[ -d "$HOME_L/projects/old" && -d "$HOME_L/.claude/projects/$(old_key)" ]] && ok "a live session refuses first; nothing touched" || bad "live session not refused" "$out"
reset; printf 'y\n' >> "$HOME_L/projects/old/f"; out="$(rename)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "uncommitted change" <<<"$out" && [[ -d "$HOME_L/projects/old" ]] && ok "a dirty tree refuses; nothing touched" || bad "dirty tree not refused" "$out"
reset; mkdir -p "$HOME_L/projects/new"; out="$(rename)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "both .* exist" <<<"$out" && [[ -d "$HOME_L/projects/old/.git" ]] && ok "old and new both present: refused, nothing moved" || bad "collision not refused" "$out"

echo "rename: the mv fails"
reset; printf 'mv\n' > "$FAULT"; out="$(rename)"; rc=$?
[[ $rc -eq 1 ]] && grep -q "step failed: .*mv" <<<"$out" && ok "stops at the mv, named" || bad "mv failure not a stop (rc=$rc)" "$out"
[[ -d "$HOME_L/projects/old/.git" && -d "$HOME_L/.claude/projects/$(old_key)" && ! -d "$HOME_L/.claude/projects/$(new_key)" ]] \
  && grep -q "projects/old" "$HOME_L/.claude/projects/$(old_key)/s.jsonl" && ok "…and the history was not rewritten" || bad "history rewritten after a failed mv"
rm -f "$FAULT"; out="$(rename)"; rc=$?
[[ $rc -eq 0 && -d "$HOME_L/.claude/projects/$(new_key)" ]] && ok "…and the retry completes" || bad "retry failed" "$out"

echo "rename: dry run"
reset; out="$(rename --dry-run)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "would: mv" <<<"$out" && [[ -d "$HOME_L/projects/old" && -d "$HOME_L/.claude/projects/$(old_key)" ]] && ok "reports, touches nothing" || bad "dry run touched something" "$out"

echo
if [[ $FAIL -eq 0 ]]; then echo "test_rename-working-copy: OK — $PASS assertion(s) passed."; else echo "test_rename-working-copy: FAILED — $FAIL assertion(s) failed."; exit 1; fi
