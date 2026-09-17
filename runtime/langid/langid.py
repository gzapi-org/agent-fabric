#!/usr/bin/env python3
"""runtime/langid/langid.py — the languages of each paragraph, by CLD2.

    <venv>/bin/python runtime/langid/langid.py < paragraphs.json > detections.json

stdin: a JSON array of strings. stdout: a JSON array, one entry per string
in order: [reliable, bytes, [[code, percent], ...]] — CLD2's verdict on
the text (Google's Compact Language Detector 2 through pycld2), up to
three languages with the share of the text each covers, `reliable` false
when the detector would only be guessing (a code line, two letters,
Georgian in Latin letters). Exit 3, with a line on stderr, when the
detector is missing: the caller reports the section as unavailable rather
than guessing. Nothing of the text leaves this process but the labels.
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    try:
        import pycld2
    except ImportError:
        print("langid: no pycld2 in this interpreter (runtime/langid/install.sh)", file=sys.stderr)
        return 3
    try:
        paragraphs = json.load(sys.stdin)
    except ValueError as exc:
        print(f"langid: stdin is not a JSON array: {exc}", file=sys.stderr)
        return 2
    if not isinstance(paragraphs, list) or not all(isinstance(p, str) for p in paragraphs):
        print("langid: stdin must be a JSON array of strings", file=sys.stderr)
        return 2
    out = []
    for p in paragraphs:
        try:
            reliable, nbytes, details = pycld2.detect(p)
        except pycld2.error:
            out.append([False, 0, []])
            continue
        out.append([bool(reliable), int(nbytes), [[d[1], int(d[2])] for d in details if d[1] != "un" and d[2] > 0]])
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
