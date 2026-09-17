#!/usr/bin/env python3
"""runtime/langid/langid.py — the language of each paragraph, by fastText.

    <venv>/bin/python runtime/langid/langid.py < paragraphs.json > labels.json

stdin: a JSON array of strings. stdout: a JSON array, one [label, prob]
per string (the top label of lid.176.ftz, ISO 639 as the model spells
it, and its probability), in order. The model is ~/.cache/agent-fabric/
langid/lid.176.ftz (AGENT_FABRIC_LANGID_MODEL overrides), installed by
runtime/langid/install.sh with the digest runtime/langid/model.json
pins. Exit 3, with a line on stderr, when the model or the predictor
is missing: the caller reports the section as unavailable rather than
guessing. Nothing of the text leaves this process but the labels.
"""
from __future__ import annotations

import json
import os
import sys


def main() -> int:
    model_path = os.environ.get("AGENT_FABRIC_LANGID_MODEL") or os.path.expanduser("~/.cache/agent-fabric/langid/lid.176.ftz")
    try:
        import fasttext  # fasttext-predict: the predictor alone, prebuilt wheels
    except ImportError:
        print("langid: no fasttext predictor in this interpreter (runtime/langid/install.sh)", file=sys.stderr)
        return 3
    if not os.path.isfile(model_path):
        print(f"langid: no model at {model_path} (runtime/langid/install.sh)", file=sys.stderr)
        return 3
    try:
        paragraphs = json.load(sys.stdin)
    except ValueError as exc:
        print(f"langid: stdin is not a JSON array: {exc}", file=sys.stderr)
        return 2
    if not isinstance(paragraphs, list) or not all(isinstance(p, str) for p in paragraphs):
        print("langid: stdin must be a JSON array of strings", file=sys.stderr)
        return 2
    model = fasttext.load_model(model_path)
    out = []
    for p in paragraphs:
        labels, probs = model.predict(p.replace("\n", " ").strip() or " ", k=1)
        out.append([labels[0].replace("__label__", ""), round(float(probs[0]), 4)] if labels else ["", 0.0])
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
