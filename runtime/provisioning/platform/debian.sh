# shellcheck shell=bash
# runtime/provisioning/platform/debian.sh — Debian (and a derivative that
# reports ID_LIKE=debian). Not yet read back on a live host: the profile
# and the CI smoke container are what stands behind it.
PLATFORM_ID=debian
PERSISTS_ACROSS_REBOOT=1
PKG_INSTALL_HINT="sudo apt-get install --no-install-recommends"
GLOBAL_BASHRC=/etc/bash.bashrc
SUDO_GROUP_NOTE="sudo is the sudo group's"
pkg_for() {
    case "$1" in
        git) echo git ;; gh) echo gh ;; node) echo nodejs ;; npm) echo npm ;;
        python3) echo python3 ;; jq) echo jq ;; gpg) echo gnupg ;; curl) echo curl ;;
        sudo) echo sudo ;; ssh) echo openssh-client ;; getent) echo libc-bin ;; useradd|usermod) echo passwd ;;
        pgrep) echo procps ;; timeout|stat|sha256sum|shred|install) echo coreutils ;; flock) echo util-linux ;;
        cmp) echo diffutils ;; bash) echo bash ;; *) echo "$1" ;;
    esac
}
