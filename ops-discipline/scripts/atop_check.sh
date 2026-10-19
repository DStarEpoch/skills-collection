#!/usr/bin/env bash
# atop_check.sh — verify atop is available at takeover; suggest or perform installation.
#
# Usage:
#   atop_check.sh              check only; if missing, print the install suggestion for
#                              this host's package manager, exit 1
#   atop_check.sh --install    install atop with the detected package manager (root or sudo)
#   atop_check.sh --enable-log enable atop history sampling (systemd only)
#
# atop is the foundation for all later resource monitoring (atop_watch.sh):
# CPU/memory/disk/network in one tool, plus historical samples (/var/log/atop/)
# so the failure window can be replayed after an incident.
#
# Exit codes: 0 = verified OK; 1 = atop missing/broken (installable); 2 = history
# logging NOT enabled (no systemd, or enable failed) — insufficient evidence, do not
# read it as "fine": without history there is no incident replay.
set -euo pipefail

mode="check"
case "${1:-}" in
    "") ;;
    --install) mode="install" ;;
    --enable-log) mode="enable-log" ;;
    *) echo "usage: $0 [--install|--enable-log]" >&2; exit 2 ;;
esac

atop_ok() {
  command -v atop >/dev/null 2>&1 && command -v atopsar >/dev/null 2>&1 || return 1
  atop -V >/dev/null 2>&1 || return 1   # binary present but broken is not OK
}

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
        if atop_ok; then
            echo "[atop_check] OK: $(atop -V 2>/dev/null | head -1)"
        else
            suggest
            echo "  re-run with --install to install now"
            exit 1
        fi
        ;;
    install)
        atop_ok || install_atop
        atop_ok && echo "[atop_check] OK after install: $(atop -V | head -1)" || { echo "[atop_check] install did not yield a working atop" >&2; exit 1; }
        ;;
    enable-log)
        atop_ok || { suggest; exit 1; }
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files atop.service >/dev/null 2>&1; then
            sudo_cmd=""; [[ $(id -u) -eq 0 ]] || sudo_cmd="sudo"
            if $sudo_cmd systemctl enable --now atop >/dev/null 2>&1 && systemctl is-active --quiet atop; then
                echo "[atop_check] atop logging service active (samples in /var/log/atop/)"
            else
                echo "[atop_check] history NOT enabled: systemctl enable/start atop failed" >&2
                exit 2
            fi
        else
            # No untested init-system branches: report honestly, don't guess service names.
            echo "[atop_check] history NOT enabled (no systemd atop.service)." >&2
            echo "  incident replay unavailable; live monitoring still works." >&2
            echo "  manual: configure atop logging for your init system, then re-run --enable-log" >&2
            exit 2
        fi
        ;;
esac
