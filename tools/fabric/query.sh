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
# committed JSON the assembler writes (<working copy>/.agent-fabric/memory/
# <role>/crossref.json in each project's repository; memory/projects/
# <project>/ here while a project has not moved), and jq answers everything
# in milliseconds. Which working copies are searched: this checkout (for
# agent-fabric itself), $AGENT_FABRIC_WORKING_COPY, the working copy the
# agent's binding names, and every entry of $AGENT_FABRIC_WORKING_COPIES
# (colon-separated). A database
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
[ -d "$MEMORY" ] || die "query: no corpus at $MEMORY"

# The project-memory roots this run can see: legacy memory/projects/<id>/
# here, and .agent-fabric/memory/ in every working copy we know of.
project_roots() {
  local wc state
  [ -d "$MEMORY/projects" ] && find "$MEMORY/projects" -mindepth 1 -maxdepth 1 -type d
  {
    printf '%s\n' "$ROOT"
    [ -n "${AGENT_FABRIC_WORKING_COPY:-}" ] && printf '%s\n' "$AGENT_FABRIC_WORKING_COPY"
    [ -n "${AGENT_FABRIC_WORKING_COPIES:-}" ] && tr ':' '\n' <<<"$AGENT_FABRIC_WORKING_COPIES"
    state="${AGENT_FABRIC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-fabric/agents/$(id -un)}"
    [ -f "$state/binding.json" ] && jq -r '.working_copy // empty' "$state/binding.json"
  } | awk 'NF' | sort -u | while IFS= read -r wc; do
    [ -d "$wc/.agent-fabric/memory" ] && printf '%s\n' "$wc/.agent-fabric/memory"
  done
  return 0
}

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

# <project memory root>/<role>/crossref.json
crossrefs() { project_roots | while IFS= read -r r; do find "$r" -mindepth 2 -maxdepth 2 -name crossref.json; done | sort -u; }
# project/role: the legacy dir is named for the project; a working copy's
# .agent-fabric/memory/ is labelled by the working copy's basename.
label_of() {
  local d p; d="$(dirname "$1")"; p="$(dirname "$d")"
  case "$p" in
    */.agent-fabric/memory) p="$(dirname "$(dirname "$p")")" ;;
  esac
  printf '%s/%s' "$(basename "$p")" "$(basename "$d")"
}

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
  slices="$( { grep -rl "$hash" "$MEMORY" --include='*.md' 2>/dev/null; project_roots | while IFS= read -r r; do grep -rl "$hash" "$r" --include='*.md' 2>/dev/null; done; } | sed "s|^$ROOT/||" | sort -u || true)"
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
