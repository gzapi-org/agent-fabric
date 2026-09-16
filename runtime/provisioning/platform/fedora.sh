# shellcheck shell=bash
# runtime/provisioning/platform/fedora.sh — Fedora, a plain install.
PLATFORM_ID=fedora
PERSISTS_ACROSS_REBOOT=1
PKG_INSTALL_HINT="sudo dnf install"
GLOBAL_BASHRC=/etc/bashrc
SUDO_GROUP_NOTE="sudo is the wheel group's"
pkg_for() {
    case "$1" in
        git) echo git-core ;; gh) echo gh ;; node) echo nodejs ;; npm) echo nodejs-npm ;;
        python3) echo python3 ;; jq) echo jq ;; gpg) echo gnupg2 ;; curl) echo curl ;;
        sudo) echo sudo ;; ssh) echo openssh-clients ;; getent|useradd|usermod) echo shadow-utils ;;
        pgrep) echo procps-ng ;; timeout|stat|sha256sum|shred|install) echo coreutils ;; flock) echo util-linux ;;
        cmp) echo diffutils ;; bash) echo bash ;; *) echo "$1" ;;
    esac
}
