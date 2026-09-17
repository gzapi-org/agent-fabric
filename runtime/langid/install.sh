#!/usr/bin/env bash
# runtime/langid/install.sh — the language-identification model and its
# predictor for THIS account, under ~/.cache/agent-fabric/langid/:
#   lid.176.ftz     fastText's compressed model, fetched from the URL in
#                   runtime/langid/model.json and refused unless its sha256
#                   is the one pinned there
#   venv/           a Python venv with the predictor the same file pins
#                   (fasttext-predict: prebuilt wheels, no compiler)
# Idempotent; --dry-run says what it would do. Best effort from
# bootstrap.sh (a host without the network keeps what it has and says so),
# so the control agent's `script` op reports `language` as unavailable
# rather than failing. Nothing here names an agent or reads a secret.
#
# Overrides, for the test: AGENT_FABRIC_LANGID_DIR (the target),
# AGENT_FABRIC_LANGID_MODEL_URL (a file:// copy), AGENT_FABRIC_LANGID_PIP
# (a command run in place of `<venv>/bin/pip install`).
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
DRY_RUN=0; [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
DIR="${AGENT_FABRIC_LANGID_DIR:-$HOME/.cache/agent-fabric/langid}"
SPEC="$ROOT/runtime/langid/model.json"
NAME="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$SPEC")"
URL="${AGENT_FABRIC_LANGID_MODEL_URL:-$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['url'])" "$SPEC")}"
SHA="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sha256'])" "$SPEC")"
PREDICTOR="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['predictor'])" "$SPEC")"
rc=0

# 1. The model, by digest.
MODEL="$DIR/$NAME"
if [[ -f "$MODEL" ]] && [[ "$(sha256sum "$MODEL" | cut -d' ' -f1)" == "$SHA" ]]; then
    echo "  =  $MODEL"
elif (( DRY_RUN )); then
    echo "  +  $MODEL (would fetch from $URL and check sha256 $SHA)"
else
    mkdir -p "$DIR"; chmod 700 "$DIR"
    tmp="$MODEL.tmp.$$"
    if curl -fsSL --max-time 120 -o "$tmp" "$URL" 2>/dev/null; then
        got="$(sha256sum "$tmp" | cut -d' ' -f1)"
        if [[ "$got" == "$SHA" ]]; then mv -f "$tmp" "$MODEL"; chmod 600 "$MODEL"; echo "  +  $MODEL"
        else rm -f "$tmp"; echo "  !  $MODEL: fetched sha256 $got is not the pinned $SHA — refused, nothing installed"; rc=1; fi
    else
        rm -f "$tmp"; echo "  !  $MODEL: could not fetch $URL (offline?); the language section stays unavailable"; rc=1
    fi
fi

# 2. The predictor, in its own venv.
VENV="$DIR/venv"
if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c "import fasttext" 2>/dev/null; then
    echo "  =  $VENV ($PREDICTOR)"
elif (( DRY_RUN )); then
    echo "  +  $VENV (would create and install $PREDICTOR)"
else
    mkdir -p "$DIR"; chmod 700 "$DIR"
    if [[ ! -x "$VENV/bin/python" ]] && ! python3 -m venv "$VENV" >/dev/null 2>&1; then
        echo "  !  $VENV: python3 -m venv failed; the language section stays unavailable"; rc=1
    else
        if [[ -n "${AGENT_FABRIC_LANGID_PIP:-}" ]]; then read -ra pipcmd <<<"$AGENT_FABRIC_LANGID_PIP"; else pipcmd=("$VENV/bin/pip" install -q); fi
        if "${pipcmd[@]}" "$PREDICTOR" >/dev/null 2>&1 && "$VENV/bin/python" -c "import fasttext" 2>/dev/null; then echo "  +  $VENV ($PREDICTOR)"
        else echo "  !  $VENV: could not install $PREDICTOR (offline?); the language section stays unavailable"; rc=1; fi
    fi
fi
exit $rc
