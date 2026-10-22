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
#   cpu-watchdog-ctl free <session[:window[.pane]]> [--undo]
#                                             lift every limit from a tmux target's processes
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
FREED_FILE="$STATE_DIR/freed.tsv"
AGENT_SLICE="${AGENT_SLICE:-cpu-watchdog-agents.slice}"
PROC_DIR="${CPU_WATCHDOG_PROC_DIR:-/proc}"
CGROUP_DIR="${CPU_WATCHDOG_CGROUP_DIR:-/sys/fs/cgroup}"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This requires root: sudo cpu-watchdog-ctl ${ORIG_ARGS[*]:-}" >&2
        exit 1
    fi
}

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
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

    agent_status

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

# --- agent CPU quota (cgroup) ---

agent_slice_dir() {
    local cg
    cg=$(systemctl show -p ControlGroup --value "$AGENT_SLICE" 2>/dev/null) || true
    [ -n "$cg" ] && [ -d "$CGROUP_DIR$cg" ] && printf '%s' "$CGROUP_DIR$cg"
}

agent_status() {
    local dir quota periods throttled freed=0

    echo
    echo "########################################"
    echo "# AGENT CPU QUOTA ($AGENT_SLICE)"
    echo "########################################"
    if [ "${AGENT_CPU_QUOTA_PCT:-0}" -le 0 ] || [ -z "${AGENT_COMM:-}" ]; then
        echo "  disabled (AGENT_COMM / AGENT_CPU_QUOTA_PCT)."
        return 0
    fi
    if ! dir=$(agent_slice_dir); then
        echo "  slice not created yet (no agent process adopted)."
        return 0
    fi
    quota=$(awk '{ print ($1 == "max") ? "none" : int($1 * 100 / $2) "%" }' "$dir/cpu.max" 2>/dev/null || echo "?")
    periods=$(awk '$1 == "nr_periods" { print $2 }' "$dir/cpu.stat" 2>/dev/null || true)
    throttled=$(awk '$1 == "nr_throttled" { print $2 }' "$dir/cpu.stat" 2>/dev/null || true)
    [ -f "$FREED_FILE" ] && freed=$(grep -c . "$FREED_FILE" || true)
    echo "  cap: $quota  (configured: ${AGENT_CPU_QUOTA_PCT}%)"
    echo "  throttled periods: ${throttled:-?} of ${periods:-?} since the slice started"
    echo "  agent processes in the slice: $(cat "$dir"/*.scope/cgroup.procs 2>/dev/null | grep -c . || true)"
    echo "  freed by hand (cpu-watchdog-ctl free): ${freed:-0}"
}

# --- free a tmux session ---

proc_start() {
    awk '{ rec = rec $0 "?" }
        END { sub(/^.*\) /, "", rec); split(rec, f, " "); if (f[20] ~ /^[0-9]+$/) print f[20] }' \
        "$PROC_DIR/$1/stat" 2>/dev/null
}

proc_state() {
    awk '{ rec = rec $0 "?" }
        END { sub(/^.*\) /, "", rec); split(rec, f, " "); print f[1] }' "$PROC_DIR/$1/stat" 2>/dev/null
}

# PIDs of the target's panes plus all of their descendants. The target is a
# session ("work"), a window ("work:2") or a pane ("work:2.1"); tmux does not
# allow ":" or "." in session names.
session_pids() {
    local target="$1" user="$2" panes
    local -a tmux_cmd=(tmux) args
    [ "$user" = "$(id -un)" ] || tmux_cmd=(sudo -u "$user" tmux)
    case "$target" in
        *:*.*) args=(display-message -p -t "$target" '#{pane_pid}') ;;
        *:*) args=(list-panes -t "$target" -F '#{pane_pid}') ;;
        *) args=(list-panes -s -t "$target" -F '#{pane_pid}') ;;
    esac
    panes=$("${tmux_cmd[@]}" "${args[@]}" 2>/dev/null) || return 1
    [ -n "$panes" ] || return 1
    ps -e -o pid=,ppid= | awk -v roots="$panes" '
        BEGIN { n = split(roots, r, "\n"); for (i = 1; i <= n; i++) keep[r[i] + 0] = 1 }
        { parent[$1 + 0] = $2 + 0 }
        END {
            do {
                changed = 0
                for (p in parent) if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; changed = 1 }
            } while (changed)
            for (p in keep) if (p in parent) print p
        }' | sort -n
}

free_session() {
    local target="$1" undo="${2:-}" user pids pid key start comm actions cl_pid lkey
    require_root
    user="${TMUX_USER:-${SUDO_USER:-$(id -un)}}"

    if ! pids=$(session_pids "$target" "$user"); then
        echo "tmux target '$target' not found for user $user (set TMUX_USER for another user)." >&2
        exit 1
    fi

    touch "$FREED_FILE"

    if [ "$undo" = "--undo" ]; then
        local keys=""
        for pid in $pids; do
            start=$(proc_start "$pid") || continue
            [ -n "$start" ] && keys+="$pid:$start"$'\n'
        done
        grep -vxF -f <(printf '%s' "$keys") "$FREED_FILE" >"$FREED_FILE.new" || true
        mv "$FREED_FILE.new" "$FREED_FILE"
        echo "Session '$target' is back under the watchdog; agents are re-adopted on the next run (within 1 minute)."
        return 0
    fi

    for pid in $pids; do
        start=$(proc_start "$pid") || continue
        [ -n "$start" ] || continue
        key="$pid:$start"
        comm=$(comm_of "$pid")
        actions=""

        if [ -f "$LIMITED_FILE" ]; then
            while IFS=$'\t' read -r lkey cl_pid _; do
                if [ "$lkey" = "$key" ]; then
                    unthrottle_one "$pid" "${cl_pid:-}" "$key" >/dev/null
                    actions+=" cpulimit-removed"
                fi
            done <"$LIMITED_FILE"
        fi

        if [ "$(proc_state "$pid")" = T ]; then
            kill -CONT "$pid" 2>/dev/null && actions+=" resumed"
        fi

        if grep -qF "/${AGENT_SLICE}/" "$PROC_DIR/$pid/cgroup" 2>/dev/null &&
           busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
               org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
               "cpu-watchdog-free-${pid}-${start}.scope" fail \
               2 PIDs au 1 "$pid" Slice s cpu-watchdog-free.slice 0 >/dev/null 2>&1; then
            actions+=" moved-out-of-agent-slice"
        fi

        grep -qxF "$key" "$FREED_FILE" || printf '%s\n' "$key" >>"$FREED_FILE"
        printf '  pid %-8s %-16s%s\n' "$pid" "$comm" "${actions:- no active limit}"
    done

    echo "Session '$target' freed: these processes are exempt until they exit or 'free $target --undo'."
    echo "Processes started later in the session are not covered."
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
    free)
        [ $# -ge 1 ] || { echo "usage: cpu-watchdog-ctl free <session[:window[.pane]]> [--undo]" >&2; exit 2; }
        free_session "$1" "${2:-}"
        ;;
    menu) menu ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
