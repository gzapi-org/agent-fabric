#!/usr/bin/env bash
# runtime/provisioning/platform/packages.sh [platform] — the packages that
# provide the fabric's host contract on a platform (default: the one this
# runs on), one per line, sorted. What a person installs, and what the CI
# smoke containers install before running the suites — so the map is
# proven by being used.
set -uo pipefail
[[ -n "${1:-}" ]] && export AGENT_FABRIC_PLATFORM="$1"
# shellcheck source=runtime/provisioning/platform/detect.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/detect.sh"
[[ "$PLATFORM_ID" != unknown ]] || { echo "packages.sh: unknown platform (AGENT_FABRIC_PLATFORM=fedora|fedora-qubes|debian|debian-qubes)" >&2; exit 2; }
for tool in "${FABRIC_HOST_TOOLS[@]}"; do pkg_for "$tool"; done | sort -u
