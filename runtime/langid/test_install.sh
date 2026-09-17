#!/usr/bin/env bash
# The language-detector installer against a sandbox: the venv step is
# idempotent, a dry run writes nothing, a stale fastText model is removed,
# and a host that cannot install the package is a said failure, not a crash.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
DIR="$SANDBOX/langid"; export AGENT_FABRIC_LANGID_DIR="$DIR"
fails=0; ok() { echo "  ✓ $1"; }; bad() { echo "  ✗ $1"; echo "$2" | sed 's/^/      /'; fails=$((fails+1)); }
# A fake venv: install.sh runs <venv>/bin/python -c "import pycld2" to decide; the fake python exits 0 once "installed".
fakevenv() { mkdir -p "$DIR/venv/bin"; printf '#!/bin/sh\n[ -f "%s/venv/installed" ]\n' "$DIR" > "$DIR/venv/bin/python"; chmod 755 "$DIR/venv/bin/python"; }
fakepip="$SANDBOX/fakepip"; printf '#!/bin/sh\ntouch "%s/venv/installed"\n' "$DIR" > "$fakepip"; chmod 755 "$fakepip"

echo "the detector is installed once, then left; a stale fastText model goes"
fakevenv; printf 'old model' > "$DIR/lid.176.ftz"
out="$(AGENT_FABRIC_LANGID_PIP="$fakepip" bash "$HERE/install.sh")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "+  $DIR/venv (pycld2==" <<<"$out" && [[ ! -e "$DIR/lid.176.ftz" ]] && grep -q "removed: the detector is CLD2 now" <<<"$out"; then ok "installed, the old model removed"; else bad "install" "$out"; fi
out="$(AGENT_FABRIC_LANGID_PIP="$fakepip" bash "$HERE/install.sh")"
if grep -q "=  $DIR/venv" <<<"$out"; then ok "idempotent"; else bad "idempotence" "$out"; fi

echo "a dry run writes nothing"
rm -rf "$DIR"; fakevenv
out="$(AGENT_FABRIC_LANGID_PIP="$fakepip" bash "$HERE/install.sh" --dry-run)"
if grep -q "would create" <<<"$out" && [[ ! -e "$DIR/venv/installed" ]]; then ok "dry run"; else bad "dry run" "$out"; fi

echo "the package cannot be installed (offline, no compiler): said, exit 1"
out="$(AGENT_FABRIC_LANGID_PIP=/bin/false bash "$HERE/install.sh")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "could not install" <<<"$out"; then ok "said"; else bad "offline" "$out"; fi

echo
if (( fails )); then echo "test_install (langid): $fails FAILED"; exit 1; fi
echo "test_install (langid): OK"
