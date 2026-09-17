#!/usr/bin/env bash
# runtime/langid/install.sh — the language detector for THIS account, under
# ~/.cache/agent-fabric/langid/venv/: a Python venv with the package
# runtime/langid/detector.json pins (pycld2 — CLD2's tables are compiled
# into the binding, so there is no model file to fetch; the binding
# builds from source and needs a C++ compiler). Idempotent; --dry-run says
# what it would do. Best effort from bootstrap.sh: a host without the
# network or a compiler keeps what it has and says so, and the control
# agent's `script` op reports `language` as unavailable rather than
# failing. Nothing here names an agent or reads a secret.
#
# Overrides, for the test: AGENT_FABRIC_LANGID_DIR (the target),
# AGENT_FABRIC_LANGID_PIP (a command run in place of `<venv>/bin/pip install`).
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
DRY_RUN=0; [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
DIR="${AGENT_FABRIC_LANGID_DIR:-$HOME/.cache/agent-fabric/langid}"
PACKAGE="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['package'])" "$ROOT/runtime/langid/detector.json")"
rc=0
# The fastText model an earlier version fetched here is not read any more.
[[ -f "$DIR/lid.176.ftz" ]] && { (( DRY_RUN )) && echo "  -  $DIR/lid.176.ftz (would remove: the detector is CLD2 now)" || { rm -f "$DIR/lid.176.ftz"; echo "  -  $DIR/lid.176.ftz (removed: the detector is CLD2 now)"; }; }
VENV="$DIR/venv"
if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c "import pycld2" 2>/dev/null; then
    echo "  =  $VENV ($PACKAGE)"
elif (( DRY_RUN )); then
    echo "  +  $VENV (would create and install $PACKAGE)"
else
    mkdir -p "$DIR"; chmod 700 "$DIR"
    if [[ ! -x "$VENV/bin/python" ]] && ! python3 -m venv "$VENV" >/dev/null 2>&1; then
        echo "  !  $VENV: python3 -m venv failed; the language section stays unavailable"; rc=1
    else
        if [[ -n "${AGENT_FABRIC_LANGID_PIP:-}" ]]; then read -ra pipcmd <<<"$AGENT_FABRIC_LANGID_PIP"; else pipcmd=("$VENV/bin/pip" install -q); fi
        if "${pipcmd[@]}" "$PACKAGE" >/dev/null 2>&1 && "$VENV/bin/python" -c "import pycld2" 2>/dev/null; then echo "  +  $VENV ($PACKAGE)"
        else echo "  !  $VENV: could not install $PACKAGE (offline, or no C++ compiler on this host); the language section stays unavailable"; rc=1; fi
    fi
fi
exit $rc
