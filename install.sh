#!/usr/bin/env bash
# Install/update cpu-watchdog from this repository.
# Idempotent: after bin/systemd/config changes, rerunning only applies
# changed content and reloads systemd when needed.
# An installed /etc/cpu-watchdog.conf is NEVER automatically overwritten
# (it may contain Telegram tokens and manually adjusted thresholds).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo ./install.sh)" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGED=0

install_if_changed() {
    local src="$1" dest="$2" mode="${3:-644}"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo "  unchanged: $dest"
        return 0
    fi
    install -D -m "$mode" "$src" "$dest"
    echo "  updated:  $dest"
    CHANGED=1
}

echo "==> Dependencies"
PACKAGE_MANAGER=""
if command -v pacman >/dev/null 2>&1; then
    PACKAGE_MANAGER=pacman
elif command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER=apt-get
fi

if command -v cpulimit >/dev/null 2>&1; then
    echo "  cpulimit ok"
else
    case "$PACKAGE_MANAGER" in
        apt-get)
            echo "  installing cpulimit..."
            apt-get update -qq
            apt-get install -y cpulimit
            ;;
        pacman)
            echo "  cpulimit is available from the AUR; install it as a regular user (e.g. yay -S cpulimit)."
            echo "  Continuing without cpulimit: Layers 1–2 will only log and alert."
            ;;
        *)
            echo "No supported package manager (apt-get or pacman); install cpulimit and earlyoom before rerunning." >&2
            exit 1
            ;;
    esac
fi
if command -v earlyoom >/dev/null 2>&1; then
    echo "  earlyoom ok"
else
    echo "  installing earlyoom..."
    case "$PACKAGE_MANAGER" in
        apt-get)
            apt-get update -qq
            apt-get install -y earlyoom
            ;;
        pacman)
            pacman -S --needed --noconfirm earlyoom
            ;;
        *)
            echo "No supported package manager (apt-get or pacman); install earlyoom before rerunning." >&2
            exit 1
            ;;
    esac
fi

echo "==> Main script"
install_if_changed "$REPO_DIR/bin/cpu-watchdog.sh" /usr/local/bin/cpu-watchdog.sh 755

echo "==> Management tool (status/log/unthrottle/whitelist)"
install_if_changed "$REPO_DIR/bin/cpu-watchdog-ctl.sh" /usr/local/bin/cpu-watchdog-ctl 755

echo "==> systemd units"
install_if_changed "$REPO_DIR/systemd/cpu-watchdog.service" /etc/systemd/system/cpu-watchdog.service
install_if_changed "$REPO_DIR/systemd/cpu-watchdog.timer" /etc/systemd/system/cpu-watchdog.timer

echo "==> earlyoom (Layer 4: sudden memory spikes)"
EARLYOOM_CHANGED=0
if ! cmp -s "$REPO_DIR/config/earlyoom.default" /etc/default/earlyoom; then
    install -m 644 "$REPO_DIR/config/earlyoom.default" /etc/default/earlyoom
    echo "  updated:  /etc/default/earlyoom"
    EARLYOOM_CHANGED=1
else
    echo "  unchanged: /etc/default/earlyoom"
fi
systemctl enable --now earlyoom >/dev/null 2>&1
if [ "$EARLYOOM_CHANGED" -eq 1 ]; then
    systemctl restart earlyoom
fi

if systemctl cat tailscaled.service >/dev/null 2>&1; then
    install_if_changed "$REPO_DIR/systemd/tailscaled-oom.conf" /etc/systemd/system/tailscaled.service.d/oom.conf
    # Apply live without restarting tailscaled, which would interrupt remote access.
    for p in $(pgrep -x tailscaled || true); do
        choom -p "$p" -n -900 >/dev/null 2>&1 || true
    done
fi

echo "==> Config"
if [ ! -f /etc/cpu-watchdog.conf ]; then
    install -D -m 600 "$REPO_DIR/config/cpu-watchdog.conf.example" /etc/cpu-watchdog.conf
    echo "  created: /etc/cpu-watchdog.conf from template"
    CHANGED=1
elif cmp -s "$REPO_DIR/config/cpu-watchdog.conf.example" /etc/cpu-watchdog.conf; then
    echo "  /etc/cpu-watchdog.conf ok (matches repository template)"
else
    chmod 600 /etc/cpu-watchdog.conf  # contains a Telegram token
    echo "  /etc/cpu-watchdog.conf already exists and is customized — keeping it."
    echo "  differences from template (sensitive values redacted):"
    # Never print TOKEN/CHAT_ID/SECRET/PASSWORD/API_KEY values in plain text.
    # They belong only in /etc/cpu-watchdog.conf, never the repository or stdout.
    redact() { sed -E 's/^([A-Z_]*(TOKEN|SECRET|PASSWORD|CHAT_ID|API_KEY)=).*/\1"<redacted>"/' "$1"; }
    diff -u <(redact /etc/cpu-watchdog.conf) <(redact "$REPO_DIR/config/cpu-watchdog.conf.example") || true
fi

echo "==> State"
mkdir -p /var/lib/cpu-watchdog
touch /var/lib/cpu-watchdog/counts.tsv /var/lib/cpu-watchdog/limited.tsv

echo "==> systemd"
if [ "$CHANGED" -eq 1 ]; then
    systemctl daemon-reload
fi
systemctl enable --now cpu-watchdog.timer
if [ "$CHANGED" -eq 1 ]; then
    systemctl restart cpu-watchdog.timer
    echo "  timer reloaded (changes detected)"
fi

echo
echo "==> Summary"
(
    # shellcheck disable=SC1091
    source /etc/cpu-watchdog.conf
    echo "  Config:                   /etc/cpu-watchdog.conf"
    echo "  Layer 1 (single process): ${CPU_THRESHOLD}% CPU for ${SUSTAIN_CHECKS}min -> throttle to ${LIMIT_PERCENT}%"
    echo "  Layer 2 (aggregate usage):   ${AGG_CPU_THRESHOLD_PCT}% of total capacity for ${AGG_SUSTAIN_CHECKS}min -> throttle top ${AGG_TOP_N} to ${AGG_LIMIT_PERCENT}%"
    echo "  Layer 4 (memory):        process >= ${MEM_PROC_KILL_MB:-?}MB for ${MEM_PROC_SUSTAIN_CHECKS:-?}min -> SIGTERM; available RAM <= ${MEM_AVAIL_KILL_PCT:-?}% and free swap <= ${MEM_SWAP_FREE_KILL_PCT:-?}% for ${MEM_SYS_SUSTAIN_CHECKS:-?}min -> SIGTERM to largest; earlyoom $(systemctl is-active earlyoom)"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        echo "  Telegram:                 enabled"
    else
        echo "  Telegram:                 disabled (edit TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID in /etc/cpu-watchdog.conf to enable)"
    fi
    echo "  Edit:                   sudo \$EDITOR /etc/cpu-watchdog.conf   (no restart needed; the timer reads the file on every run)"
    echo "  View/manage:            sudo cpu-watchdog-ctl   (interactive menu: view throttles, release, whitelist)"
)

echo
echo "OK."
systemctl status cpu-watchdog.timer --no-pager -l | head -5
