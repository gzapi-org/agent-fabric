#!/usr/bin/env bash
# projects/gzapp/integration/provisioning/host-check.sh — what a host must
# carry for an account that works on gzapp, beyond the fabric's own
# contract. Run by runtime/provisioning/new-agent-worker.sh on the
# account's host for each --project it clones; prints one line per item,
# exits 0 — a missing item is named for the person, never a stop (the
# fabric provisions the account; the project's toolchain is its own).
#
# gzapp: commit signing goes through the OpenTimestamps gpg wrapper that
# devex-tooling installs (gzapp infra/signing/install-shim.sh); the local
# stack runs rootless podman; the decks and site tooling render with
# ImageMagick.
say() { printf 'host-check gzapp: %s\n' "$*" >&2; }
[[ -x /usr/local/bin/ots-git-gpg-wrapper.sh ]] && say "gpg wrapper: /usr/local/bin/ots-git-gpg-wrapper.sh" \
    || say "gpg wrapper: MISSING — commit signing needs it; devex-tooling installs it (infra/signing/install-shim.sh)"
for tool in podman magick; do
    command -v "$tool" >/dev/null 2>&1 && say "$tool: present" || say "$tool: MISSING (a TemplateVM package on Qubes)"
done
exit 0
