#!/usr/bin/env bash
# atop_check.sh — verify atop is available at takeover; suggest or perform installation.
#
# Usage:
#   atop_check.sh              check only; if missing, print the install suggestion for
#                              this host's package manager, exit 1
#   atop_check.sh --install    install atop with the detected package manager (root or sudo)
#   atop_check.sh --enable-log enable atop history sampling (systemd atop.service)
#
# atop is the foundation for all later resource monitoring (atop_watch.sh):
# CPU/memory/disk/network in one tool, plus historical samples (/var/log/atop/)
# so the failure window can be replayed after an incident.

set -euo pipefail

mode="check"
case "${1:-}" in
    "") ;;
    --install) mode="install" ;;
    --enable-log) mode="enable-log" ;;
    *) echo "usage: $0 [--install|--enable-log]" >&2; exit 2 ;;
esac

have_atop() { command -v atop >/dev/null 2>&1; }

suggest() {
    echo "[atop_check] atop NOT installed."
    if   command -v apt-get >/dev/null 2>&1; then echo "  install: sudo apt-get install -y atop"
    elif command -v dnf     >/dev/null 2>&1; then echo "  install: sudo dnf install -y atop"
    elif command -v yum     >/dev/null 2>&1; then echo "  install: sudo yum install -y atop"
    elif command -v apk     >/dev/null 2>&1; then echo "  install: sudo apk add atop"
    elif command -v pacman  >/dev/null 2>&1; then echo "  install: sudo pacman -S --noconfirm atop"
    else echo "  no known package manager found; install atop manually (https://atoptool.nl)"
    fi
}

install_atop() {
    local sudo=""
    [[ $(id -u) -eq 0 ]] || sudo="sudo"
    if   command -v apt-get >/dev/null 2>&1; then $sudo apt-get update -qq && $sudo apt-get install -y atop
    elif command -v dnf     >/dev/null 2>&1; then $sudo dnf install -y atop
    elif command -v yum     >/dev/null 2>&1; then $sudo yum install -y atop
    elif command -v apk     >/dev/null 2>&1; then $sudo apk add atop
    elif command -v pacman  >/dev/null 2>&1; then $sudo pacman -S --noconfirm atop
    else echo "[atop_check] FATAL: no known package manager" >&2; exit 1
    fi
}

case "$mode" in
    check)
        if have_atop; then
            echo "[atop_check] OK: $(atop -V 2>/dev/null | head -1)"
        else
            suggest
            echo "  re-run with --install to install now"
            exit 1
        fi
        ;;
    install)
        have_atop || install_atop
        have_atop && echo "[atop_check] OK after install: $(atop -V | head -1)"
        ;;
    enable-log)
        have_atop || { suggest; exit 1; }
        if command -v systemctl >/dev/null 2>&1; then
            # Debian/Ubuntu: the package handles /etc/default/atop START=yes; just enable the service
            sudo_cmd=""; [[ $(id -u) -eq 0 ]] || sudo_cmd="sudo"
            $sudo_cmd systemctl enable --now atop 2>/dev/null \
                && echo "[atop_check] atop logging service enabled (samples in /var/log/atop/)" \
                || echo "[atop_check] WARN: systemctl enable atop failed; history logging not enabled"
        else
            echo "[atop_check] no systemd; skip history logging (live monitoring still works)"
        fi
        ;;
esac
