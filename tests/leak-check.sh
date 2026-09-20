#!/usr/bin/env bash
# tests/leak-check.sh — sourced by tests/run.sh: did the run leave anything
# under the temporary directory?
#
#   leak_snapshot <dir>              → the directory's entries, one per line
#   leak_report <dir> <snapshot>     → prints every entry not in the snapshot,
#                                      indented; returns 1 if there was one
#
# A test run leaves behind nothing it did not find (the owner, 2026-09-19).
# The directory is resolved as Node's os.tmpdir() does — TMPDIR, then TMP,
# then TEMP, then /tmp. Python's tempfile reads TEMP before TMP, so with
# TMPDIR unset and the two pointing at different directories a python
# suite's leak would go unwatched; the fabric sets TMPDIR on every account
# (the value both libraries agree on), and the fallbacks are for a shell
# that has none of it.
# Names are handled as whole lines: an entry with a space or a glob
# character is printed as itself, never split or expanded.
leak_dir() { printf '%s\n' "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"; }
leak_snapshot() { ls -A -- "$1" 2>/dev/null | LC_ALL=C sort; }
leak_report() {
    local dir="$1" before="$2" left
    left="$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(ls -A -- "$dir" 2>/dev/null | LC_ALL=C sort) | grep -v '^$' || true)"
    [[ -n "$left" ]] || return 0
    echo "== scratch left behind under $dir (a suite did not clean up):"
    printf '%s\n' "$left" | sed 's/^/   /'
    return 1
}
