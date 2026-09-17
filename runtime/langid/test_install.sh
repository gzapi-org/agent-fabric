#!/usr/bin/env bash
# The language-identification installer against a sandbox: the model is
# taken only with the pinned digest, the venv step is idempotent, a dry
# run writes nothing, and an offline host is a said failure, not a crash.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
ORIG_HOME="$HOME"; export HOME="$SANDBOX/home"; mkdir -p "$HOME"
DIR="$SANDBOX/langid"; export AGENT_FABRIC_LANGID_DIR="$DIR"
fails=0; ok() { echo "  ✓ $1"; }; bad() { echo "  ✗ $1"; echo "$2" | sed 's/^/      /'; fails=$((fails+1)); }

# A fake venv: install.sh runs <venv>/bin/python -c "import fasttext" to decide; the fake python exits 0 once "installed".
fakevenv() { mkdir -p "$DIR/venv/bin"; printf '#!/bin/sh\n[ -f "%s/venv/installed" ]\n' "$DIR" > "$DIR/venv/bin/python"; chmod 755 "$DIR/venv/bin/python"; }
fakepip="$SANDBOX/fakepip"; printf '#!/bin/sh\ntouch "%s/venv/installed"\n' "$DIR" > "$fakepip"; chmod 755 "$fakepip"; export AGENT_FABRIC_LANGID_PIP="$fakepip"

echo "a wrong digest is refused, nothing installed"
printf 'not the model' > "$SANDBOX/wrong.ftz"
fakevenv
out="$(AGENT_FABRIC_LANGID_MODEL_URL="file://$SANDBOX/wrong.ftz" bash "$HERE/install.sh")"; rc=$?
[[ $rc -ne 0 ]] && grep -q "is not the pinned" <<<"$out" && [[ ! -e "$DIR/lid.176.ftz" ]] && ok "refused and said" || bad "wrong digest" "$out"
[[ -f "$DIR/venv/installed" ]] && ok "the venv step still ran (independent of the model)" || bad "venv step" "$out"

echo "the right digest is installed once, then left"
# The pinned digest cannot be forged: this path runs where the real model is (REAL_MODEL, or the account's own copy).
for cand in "${REAL_MODEL:-}" "${ORIG_HOME:-}/.cache/agent-fabric/langid/lid.176.ftz"; do [[ -n "$cand" && -f "$cand" ]] && cp "$cand" "$SANDBOX/right.ftz" && break; done
if [[ -f "$SANDBOX/right.ftz" ]]; then
    out="$(AGENT_FABRIC_LANGID_MODEL_URL="file://$SANDBOX/right.ftz" bash "$HERE/install.sh")"; rc=$?
    [[ $rc -eq 0 ]] && grep -q "+  $DIR/lid.176.ftz" <<<"$out" && [[ "$(stat -c %a "$DIR/lid.176.ftz")" == "600" ]] && ok "installed 0600" || bad "install" "$out"
    out="$(AGENT_FABRIC_LANGID_MODEL_URL="file://$SANDBOX/right.ftz" bash "$HERE/install.sh")"
    grep -q "=  $DIR/lid.176.ftz" <<<"$out" && grep -q "=  $DIR/venv" <<<"$out" && ok "idempotent" || bad "idempotence" "$out"
else
    echo "  -  (the real model is not on this host: the right-digest path is exercised where it is; set REAL_MODEL to its path)"
fi

echo "a dry run writes nothing"
rm -rf "$DIR"; fakevenv; rm -f "$DIR/venv/installed"
out="$(AGENT_FABRIC_LANGID_MODEL_URL="file://$SANDBOX/wrong.ftz" bash "$HERE/install.sh" --dry-run)"
grep -q "would fetch" <<<"$out" && grep -q "would create" <<<"$out" && [[ ! -e "$DIR/lid.176.ftz" && ! -e "$DIR/venv/installed" ]] && ok "dry run" || bad "dry run" "$out"

echo "offline: said, exit 1, nothing half-written"
out="$(AGENT_FABRIC_LANGID_MODEL_URL="file://$SANDBOX/does-not-exist" bash "$HERE/install.sh")"; rc=$?
[[ $rc -eq 1 ]] && grep -q "could not fetch" <<<"$out" && [[ ! -e "$DIR/lid.176.ftz" ]] && ! ls "$DIR"/*.tmp.* >/dev/null 2>&1 && ok "offline" || bad "offline" "$out"

echo
if (( fails )); then echo "test_install (langid): $fails FAILED"; exit 1; fi
echo "test_install (langid): OK"
