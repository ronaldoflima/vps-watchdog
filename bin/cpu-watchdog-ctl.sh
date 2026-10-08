#!/usr/bin/env bash
# cpu-watchdog management CLI: inspect throttles and take action
# without memorizing file paths or systemd commands.
#
# Usage:
#   cpu-watchdog-ctl                          interactive menu
#   cpu-watchdog-ctl status                   active throttles + host snapshot
#   cpu-watchdog-ctl log [N]                   last N log lines (default 40)
#   cpu-watchdog-ctl unthrottle <PID|all>      release active throttle(s)
#   cpu-watchdog-ctl whitelist-cpu <comm>      exempt a process from CPU throttling
#   cpu-watchdog-ctl whitelist-mem <comm>      exempt a process from memory kills
#   cpu-watchdog-ctl whitelist-cmdline <regex> exempt by matching the full command line
#
# "comm" = name shown by ps -o comm (e.g. qdrant, node, php8.3).
set -euo pipefail

CONF="${CPU_WATCHDOG_CONF:-/etc/cpu-watchdog.conf}"
STATE_DIR=/var/lib/cpu-watchdog
LOG_FILE=/var/log/cpu-watchdog.log

# Load actual STATE_DIR/LOG_FILE if configuration is readable,
# so status/log queries do not require root.
if [ -r "$CONF" ]; then
    # shellcheck source=config/cpu-watchdog.conf.example
    source "$CONF"
fi

LIMITED_FILE="$STATE_DIR/limited.tsv"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This requires root: sudo cpu-watchdog-ctl ${ORIG_ARGS[*]:-}" >&2
        exit 1
    fi
}

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

# --- configuration read/write ---

get_conf_var() {
    local key="$1"
    sed -n -E "s/^${key}=\"(.*)\"\$/\1/p" "$CONF" | head -1
}

set_conf_var() {
    require_root
    local key="$1" value="$2" tmp

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    tmp=$(mktemp "$(dirname "$CONF")/.cpu-watchdog.conf.XXXXXX")
    chmod 600 "$tmp"

    awk -v key="$key" -v val="$value" '
        $0 ~ "^" key "=" { print key "=\"" val "\""; done=1; next }
        { print }
        END { if (!done) print key "=\"" val "\"" }
    ' "$CONF" >"$tmp"

    mv "$tmp" "$CONF"
}

list_contains() {
    local needle="$1" hay="$2" w
    for w in $hay; do
        [ "$w" = "$needle" ] && return 0
    done
    return 1
}

whitelist_cpu() {
    local comm="$1" cur
    require_root
    cur="$(get_conf_var WHITELIST_COMM)"
    if list_contains "$comm" "$cur"; then
        echo "'$comm' is already exempt from CPU throttling (WHITELIST_COMM). No changes needed."
        return 0
    fi
    set_conf_var WHITELIST_COMM "${cur:+$cur }$comm"
    echo "OK: '$comm' is now exempt from CPU throttling (Layers 1–3)."
    echo "No restart needed — the watchdog reads the configuration on every run (once a minute)."
}

whitelist_mem() {
    local comm="$1" cur
    require_root
    cur="$(get_conf_var MEM_WHITELIST_COMM)"
    if list_contains "$comm" "$cur"; then
        echo "'$comm' is already exempt from memory kills (MEM_WHITELIST_COMM). No changes needed."
        return 0
    fi
    set_conf_var MEM_WHITELIST_COMM "${cur:+$cur }$comm"
    echo "OK: '$comm' is now exempt from Layer 4 (memory) kills."
    echo "No restart needed — the watchdog reads the configuration on every run (once a minute)."
}

whitelist_cmdline() {
    local pattern="$1" cur
    require_root
    cur="$(get_conf_var WHITELIST_CMDLINE)"
    if [ -n "$cur" ] && grep -qF -- "$pattern" <<<"$cur"; then
        echo "This pattern is already in WHITELIST_CMDLINE. No changes needed."
        return 0
    fi
    set_conf_var WHITELIST_CMDLINE "${cur:+$cur|}$pattern"
    echo "OK: processes whose command lines match '$pattern' are now exempt from CPU throttling."
    echo "Use this instead of whitelist-cpu for generic process names (python, node, php)."
}

# --- queries / status ---

comm_of() {
    local pid="$1"
    [ -d "/proc/$pid" ] && ps -p "$pid" -o comm= 2>/dev/null || echo "?"
}

status() {
    local timer_state="active"
    systemctl is-active --quiet cpu-watchdog.timer 2>/dev/null || timer_state="INACTIVE"

    # Show active throttles first, then details such as log,
    # host snapshot and timer state.
    echo "########################################"
    echo "# CURRENTLY THROTTLED PROCESSES"
    echo "########################################"
    local any=0
    if [ -f "$LIMITED_FILE" ]; then
        while IFS=$'\t' read -r key cl_pid limit applied_at reason; do
            [ -n "${key:-}" ] || continue
            local pid="${key%%:*}"
            if [ -n "${cl_pid:-}" ] && kill -0 "$cl_pid" 2>/dev/null; then
                any=1
                printf '  >> pid %-8s (%s) limited to %s%% since %s\n     reason: %s\n' \
                    "$pid" "$(comm_of "$pid")" "$limit" "$applied_at" "$reason"
            fi
        done <"$LIMITED_FILE"
    fi
    if [ "$any" -eq 0 ]; then
        echo "  none — no active throttles."
    fi

    echo
    echo "----------------------------------------"
    echo "details"
    echo "----------------------------------------"
    echo "timer: $timer_state"

    echo
    echo "-- Last 10 log lines --"
    if [ -r "$LOG_FILE" ]; then
        tail -n 10 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  (no log yet, or no read permission — run with sudo)"
    fi

    echo
    echo "-- Host snapshot --"
    echo "  Top 5 CPU:"
    ps -eo pid,pcpu,comm --sort=-pcpu --no-headers 2>/dev/null | head -5 | sed 's/^/    /'
    echo "  Memory:"
    free -h | sed 's/^/    /'
}

show_log() {
    local n="${1:-40}"
    if [ -r "$LOG_FILE" ]; then
        tail -n "$n" "$LOG_FILE"
    else
        echo "Cannot read $LOG_FILE (run with sudo)." >&2
        exit 1
    fi
}

# --- actions ---

unthrottle_one() {
    local pid="$1" cl_pid="$2" key="$3"
    local scope="cpu-watchdog-limit-${key/:/-}.scope"

    if systemctl stop "$scope" >/dev/null 2>&1; then
        echo "Throttle removed: pid $pid ($scope stopped)."
        return 0
    fi

    if kill -0 "$cl_pid" 2>/dev/null; then
        kill "$cl_pid" 2>/dev/null || true
        echo "Throttle removed: pid $pid (cpulimit pid $cl_pid killed)."
    else
        echo "pid $pid no longer had an active throttle."
    fi
}

unthrottle() {
    local target="$1"
    require_root

    if [ ! -f "$LIMITED_FILE" ]; then
        echo "No entries in $LIMITED_FILE."
        return 0
    fi

    local found=0
    while IFS=$'\t' read -r key cl_pid limit applied_at reason; do
        [ -n "${key:-}" ] || continue
        local pid="${key%%:*}"
        if [ "$target" = "all" ] || [ "$pid" = "$target" ]; then
            found=1
            unthrottle_one "$pid" "${cl_pid:-}" "$key"
        fi
    done <"$LIMITED_FILE"

    [ "$found" -eq 1 ] || echo "No entry for pid '$target' in $LIMITED_FILE (see 'status' for active PIDs)."
    echo "The entry in $LIMITED_FILE is cleaned up on the next run (within 1 minute)."
}

# --- interactive menu for users unfamiliar with bash/systemd ---

menu() {
    local opt n t c r
    while true; do
        echo
        echo "=== cpu-watchdog — menu ==="
        echo "1) View active throttles"
        echo "2) View history (log)"
        echo "3) Stop a throttle (release a process)"
        echo "4) Exempt a process from CPU throttling (by name)"
        echo "5) Exempt a process from memory kills (by name)"
        echo "6) Exempt from CPU throttling (command line/regex — use for python/node/php)"
        echo "0) Exit"
        read -rp "Choice: " opt
        case "$opt" in
            1) status ;;
            2) read -rp "How many lines? [40] " n; show_log "${n:-40}" ;;
            3)
                status
                read -rp "PID to release (or 'all' to release all): " t
                [ -n "$t" ] && unthrottle "$t"
                ;;
            4)
                read -rp "Process name (comm, e.g. qdrant): " c
                [ -n "$c" ] && whitelist_cpu "$c"
                ;;
            5)
                read -rp "Process name (comm): " c
                [ -n "$c" ] && whitelist_mem "$c"
                ;;
            6)
                read -rp "ERE regex against the command line: " r
                [ -n "$r" ] && whitelist_cmdline "$r"
                ;;
            0) exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

ORIG_ARGS=("$@")
cmd="${1:-menu}"
[ $# -gt 0 ] && shift

case "$cmd" in
    status) status ;;
    log) show_log "${1:-40}" ;;
    unthrottle)
        [ $# -ge 1 ] || { echo "usage: cpu-watchdog-ctl unthrottle <PID|all>" >&2; exit 2; }
        unthrottle "$1"
        ;;
    whitelist-cpu)
        [ $# -ge 1 ] || { echo "usage: cpu-watchdog-ctl whitelist-cpu <comm>" >&2; exit 2; }
        whitelist_cpu "$1"
        ;;
    whitelist-mem)
        [ $# -ge 1 ] || { echo "usage: cpu-watchdog-ctl whitelist-mem <comm>" >&2; exit 2; }
        whitelist_mem "$1"
        ;;
    whitelist-cmdline)
        [ $# -ge 1 ] || { echo "usage: cpu-watchdog-ctl whitelist-cmdline <regex>" >&2; exit 2; }
        whitelist_cmdline "$1"
        ;;
    menu) menu ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
