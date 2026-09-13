#!/usr/bin/env bash
# tools/fabric/query.sh
#
# >>> help
# Ask the corpus what it knows about an artifact.
#
#   tools/fabric/query.sh adr ADR-054       # who learned from it, where it landed
#   tools/fabric/query.sh pr 428
#   tools/fabric/query.sh migration 0007
#   tools/fabric/query.sh file apps/status_web
#   tools/fabric/query.sh obs <content-hash>
#   tools/fabric/query.sh roles             # what roles exist, per project, and how big they are
#
# The citation graph is small — thousands of edges — so it lives in the
# committed JSON the assembler writes (memory/projects/<project>/<role>/
# crossref.json), and jq answers everything in milliseconds. A database
# would buy nothing here and would cost the one property that matters
# most: the graph is reviewable in a pull request, because it is a diff
# like everything else.
#
# If multi-hop queries ever become routine, the next step is a generated
# SQLite edge cache rebuilt from these files — derived, never authoritative.
# Git stays the source of truth.
# <<< help

set -euo pipefail

ROOT="${AGENT_FABRIC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MEMORY="$ROOT/memory"

die() { printf '%s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null || die "query: jq is required"
[ -d "$MEMORY/projects" ] || die "query: no corpus at $MEMORY"

usage() {
  sed -n '/^# >>> help/,/^# <<< help/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^>>> help$/d; /^<<< help$/d'
}

kind_key() {
  case "$1" in
    adr|adrs)             echo adrs ;;
    arch|archs)           echo archs ;;
    pr|prs)               echo prs ;;
    commit|commits)       echo commits ;;
    contract|contracts)   echo contracts ;;
    error|error_codes)    echo error_codes ;;
    migration|migrations) echo migrations ;;
    file|files)           echo files ;;
    *) die "query: unknown artifact kind '$1' (adr arch pr commit contract error migration file)" ;;
  esac
}

# memory/projects/<project>/<role>/crossref.json
crossrefs() { find "$MEMORY/projects" -mindepth 3 -maxdepth 3 -name crossref.json | sort; }
label_of() { local d; d="$(dirname "$1")"; printf '%s/%s' "$(basename "$(dirname "$d")")" "$(basename "$d")"; }

cmd_roles() {
  printf '%-28s %-8s %-8s %s\n' project/role project domain citations
  for f in $(crossrefs); do
    local dir role proj_slices dom_slices cites
    dir="$(dirname "$f")"; role="$(basename "$dir")"
    proj_slices="$(find "$dir" -name '*.md' ! -name INDEX.md | wc -l | tr -d ' ')"
    dom_slices="$( [ -d "$MEMORY/domains/$role" ] && find "$MEMORY/domains/$role" -name '*.md' ! -name INDEX.md | wc -l | tr -d ' ' || echo 0)"
    cites="$(jq '[.index[]? | length] | add // 0' "$f")"
    printf '%-28s %-8s %-8s %s\n' "$(label_of "$f")" "$proj_slices" "$dom_slices" "$cites"
  done
}

cmd_lookup() {
  local key="$1" needle="$2" found=0
  for f in $(crossrefs); do
    local role hit
    role="$(label_of "$f")"
    hit="$(jq -r --arg k "$key" --arg n "$needle" '
      (.index[$k] // {}) | to_entries[]
      | select(.key == $n or (.key | ascii_downcase | contains($n | ascii_downcase)))
      | "\(.key)\t\(.value.slices | join(", "))\t\(.value.observations | length)"
    ' "$f")"
    [ -z "$hit" ] && continue
    found=1
    printf '\n%s\n' "$role"
    printf '%s\n' "$hit" | while IFS=$'\t' read -r artifact slices n; do
      printf '  %-44s %s obs\n' "$artifact" "$n"
      printf '      slices: %s\n' "${slices:-none}"
    done
  done
  [ "$found" = 1 ] || printf 'nothing in the corpus cites %s\n' "$needle"
}

cmd_obs() {
  local hash="$1" found=0
  for f in $(crossrefs); do
    local role hit
    role="$(label_of "$f")"
    hit="$(jq -r --arg h "$hash" '
      .index | to_entries[] | .key as $kind | .value | to_entries[]
      | select(.value.observations | index($h))
      | "\($kind)\t\(.key)"
    ' "$f")"
    [ -z "$hit" ] && continue
    found=1
    printf '\n%s cites:\n' "$role"
    printf '%s\n' "$hit" | while IFS=$'\t' read -r kind artifact; do
      printf '  %-12s %s\n' "$kind" "$artifact"
    done
  done
  # Provenance runs the other way too: which slices were built from this row.
  local slices
  slices="$(grep -rl "$hash" "$MEMORY" --include='*.md' 2>/dev/null | sed "s|^$ROOT/||" | sort || true)"
  if [ -n "$slices" ]; then
    found=1
    printf '\nevidence for:\n'
    printf '  %s\n' $slices
  fi
  [ "$found" = 1 ] || printf 'observation %s is not referenced in the corpus\n' "$hash"
}

case "${1:-}" in
  ""|-h|--help|help) usage ;;
  roles)             cmd_roles ;;
  obs)               [ $# -ge 2 ] || die "query: obs needs a content hash"; cmd_obs "$2" ;;
  *)
    [ $# -ge 2 ] || die "query: need an artifact, e.g. 'adr ADR-054'"
    key="$(kind_key "$1")"; shift
    needle="$1"
    case "$key" in
      prs)        [[ "$needle" == \#* ]] || needle="#$needle" ;;
      migrations) [[ "$needle" == migration-* || "$needle" == infra/* ]] || needle="$needle" ;;
    esac
    cmd_lookup "$key" "$needle"
    ;;
esac
