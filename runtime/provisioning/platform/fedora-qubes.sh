# shellcheck shell=bash
# runtime/provisioning/platform/fedora-qubes.sh — a Fedora TemplateVM's
# AppVM under Qubes OS: only /home and /usr/local survive a reboot, so a
# package is installed in the TemplateVM, never here, and sudo reaches
# the operator through the `qubes` group (which role accounts are not in).
# shellcheck source=runtime/provisioning/platform/fedora.sh
. "$(dirname "${BASH_SOURCE[0]}")/fedora.sh"
PLATFORM_ID=fedora-qubes
PERSISTS_ACROSS_REBOOT=0
PKG_INSTALL_HINT="in the TemplateVM: sudo dnf install"
SUDO_GROUP_NOTE="sudo is the qubes group's; role accounts are not in it (moveto/README.md)"
