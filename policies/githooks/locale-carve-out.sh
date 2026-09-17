#!/usr/bin/env bash
# policies/githooks/locale-carve-out.sh — do these paths fall, all of them,
# under one locale's translations: identities/roles/<role>/locale/<suffix>/?
# Sourced by pre-commit and by the CI authority check; sets `locale_role`
# and `locale_suffix` and returns 0 when they do, 1 otherwise (any other
# path, two roles, two suffixes, a path deeper than the locale directory,
# or no path at all).
locale_carve_out_role() {
    locale_role=""; locale_suffix=""
    (( $# )) || return 1
    local p role suffix
    for p in "$@"; do
        [[ "$p" =~ ^identities/roles/([a-z][a-z0-9-]*)/locale/([a-z][a-z0-9-]*)/[^/]+$ ]] || return 1
        role="${BASH_REMATCH[1]}"; suffix="${BASH_REMATCH[2]}"
        if [[ -z "$locale_role" ]]; then locale_role="$role"; locale_suffix="$suffix"
        elif [[ "$role" != "$locale_role" || "$suffix" != "$locale_suffix" ]]; then locale_role=""; locale_suffix=""; return 1
        fi
    done
    return 0
}
