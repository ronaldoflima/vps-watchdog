#!/usr/bin/env bash
# CLI de gerenciamento do cpu-watchdog: ver o que está sendo limitado e agir,
# sem precisar saber de cor os caminhos de arquivo nem comandos de systemd.
#
# Uso:
#   cpu-watchdog-ctl                          menu interativo
#   cpu-watchdog-ctl status                   o que está limitado agora + snapshot da máquina
#   cpu-watchdog-ctl log [N]                   últimas N linhas do log (default 40)
#   cpu-watchdog-ctl unthrottle <PID|all>      libera throttle(s) ativo(s)
#   cpu-watchdog-ctl whitelist-cpu <comm>      nunca mais limitar esse processo por CPU
#   cpu-watchdog-ctl whitelist-mem <comm>      nunca mais matar esse processo por memória
#   cpu-watchdog-ctl whitelist-cmdline <regex> idem, casando pela linha de comando completa
#
# "comm" = nome como aparece em `ps -o comm` (ex.: qdrant, node, php8.3).
set -euo pipefail

CONF="${CPU_WATCHDOG_CONF:-/etc/cpu-watchdog.conf}"
STATE_DIR=/var/lib/cpu-watchdog
LOG_FILE=/var/log/cpu-watchdog.log

# Carrega STATE_DIR/LOG_FILE reais se o config for legível (evita exigir root
# só para consultar status/log).
if [ -r "$CONF" ]; then
    # shellcheck source=config/cpu-watchdog.conf.example
    source "$CONF"
fi

LIMITED_FILE="$STATE_DIR/limited.tsv"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Isso precisa de root: sudo cpu-watchdog-ctl ${ORIG_ARGS[*]:-}" >&2
        exit 1
    fi
}

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

# --- leitura/escrita do config ---

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
        echo "'$comm' já está isento de throttle de CPU (WHITELIST_COMM). Nada a fazer."
        return 0
    fi
    set_conf_var WHITELIST_COMM "${cur:+$cur }$comm"
    echo "OK: '$comm' nunca mais será throttled por CPU (Camadas 1-3)."
    echo "Não precisa reiniciar nada — o watchdog lê o config a cada execução (1x/min)."
}

whitelist_mem() {
    local comm="$1" cur
    require_root
    cur="$(get_conf_var MEM_WHITELIST_COMM)"
    if list_contains "$comm" "$cur"; then
        echo "'$comm' já está isento de kill por memória (MEM_WHITELIST_COMM). Nada a fazer."
        return 0
    fi
    set_conf_var MEM_WHITELIST_COMM "${cur:+$cur }$comm"
    echo "OK: '$comm' nunca mais será morto pela Camada 4 (memória)."
    echo "Não precisa reiniciar nada — o watchdog lê o config a cada execução (1x/min)."
}

whitelist_cmdline() {
    local pattern="$1" cur
    require_root
    cur="$(get_conf_var WHITELIST_CMDLINE)"
    if [ -n "$cur" ] && grep -qF -- "$pattern" <<<"$cur"; then
        echo "Esse padrão já está em WHITELIST_CMDLINE. Nada a fazer."
        return 0
    fi
    set_conf_var WHITELIST_CMDLINE "${cur:+$cur|}$pattern"
    echo "OK: processos cuja linha de comando casar com '$pattern' nunca mais serão throttled por CPU."
    echo "Use isso (em vez de whitelist-cpu) quando o nome do processo for genérico (python, node, php)."
}

# --- consulta / status ---

comm_of() {
    local pid="$1"
    [ -d "/proc/$pid" ] && ps -p "$pid" -o comm= 2>/dev/null || echo "?"
}

status() {
    echo "== cpu-watchdog =="
    if systemctl is-active --quiet cpu-watchdog.timer 2>/dev/null; then
        echo "timer: ativo"
    else
        echo "timer: INATIVO — nada está sendo monitorado agora"
    fi

    echo
    echo "-- Throttle de CPU ativo agora --"
    local any=0
    if [ -f "$LIMITED_FILE" ]; then
        while IFS=$'\t' read -r key cl_pid limit applied_at reason; do
            [ -n "${key:-}" ] || continue
            local pid="${key%%:*}"
            if [ -n "${cl_pid:-}" ] && kill -0 "$cl_pid" 2>/dev/null; then
                any=1
                printf '  pid %-8s (%s) limitado a %s%% desde %s\n      motivo: %s\n' \
                    "$pid" "$(comm_of "$pid")" "$limit" "$applied_at" "$reason"
            fi
        done <"$LIMITED_FILE"
    fi
    [ "$any" -eq 1 ] || echo "  (nenhum)"

    echo
    echo "-- Últimas 10 linhas do log --"
    if [ -r "$LOG_FILE" ]; then
        tail -n 10 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  (sem log ainda, ou sem permissão de leitura — rode com sudo)"
    fi

    echo
    echo "-- Snapshot da máquina --"
    echo "  Top 5 CPU:"
    ps -eo pid,pcpu,comm --sort=-pcpu --no-headers 2>/dev/null | head -5 | sed 's/^/    /'
    echo "  Memória:"
    free -h | sed 's/^/    /'
}

show_log() {
    local n="${1:-40}"
    if [ -r "$LOG_FILE" ]; then
        tail -n "$n" "$LOG_FILE"
    else
        echo "Não consigo ler $LOG_FILE (rode com sudo)." >&2
        exit 1
    fi
}

# --- ação ---

unthrottle_one() {
    local pid="$1" cl_pid="$2" key="$3"
    local scope="cpu-watchdog-limit-${key/:/-}.scope"

    if systemctl stop "$scope" >/dev/null 2>&1; then
        echo "Throttle removido: pid $pid ($scope parado)."
        return 0
    fi

    if kill -0 "$cl_pid" 2>/dev/null; then
        kill "$cl_pid" 2>/dev/null || true
        echo "Throttle removido: pid $pid (cpulimit pid $cl_pid morto)."
    else
        echo "pid $pid já não tinha throttle ativo."
    fi
}

unthrottle() {
    local target="$1"
    require_root

    if [ ! -f "$LIMITED_FILE" ]; then
        echo "Nada registrado em $LIMITED_FILE."
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

    [ "$found" -eq 1 ] || echo "Nenhum registro para pid '$target' em $LIMITED_FILE (veja 'status' para os pids ativos)."
    echo "O registro em $LIMITED_FILE se limpa sozinho na próxima execução (até 1min)."
}

# --- menu interativo (pensado para quem não conhece bash/systemd) ---

menu() {
    local opt n t c r
    while true; do
        echo
        echo "=== cpu-watchdog — menu ==="
        echo "1) Ver o que está sendo limitado agora"
        echo "2) Ver histórico (log)"
        echo "3) Parar um throttle (liberar um processo)"
        echo "4) Nunca mais limitar um processo por CPU (por nome)"
        echo "5) Nunca mais matar um processo por memória (por nome)"
        echo "6) Nunca mais limitar por CPU (por linha de comando/regex — use para python/node/php)"
        echo "0) Sair"
        read -rp "Escolha: " opt
        case "$opt" in
            1) status ;;
            2) read -rp "Quantas linhas? [40] " n; show_log "${n:-40}" ;;
            3)
                status
                read -rp "PID a liberar (ou 'all' para liberar todos): " t
                [ -n "$t" ] && unthrottle "$t"
                ;;
            4)
                read -rp "Nome do processo (comm, ex.: qdrant): " c
                [ -n "$c" ] && whitelist_cpu "$c"
                ;;
            5)
                read -rp "Nome do processo (comm): " c
                [ -n "$c" ] && whitelist_mem "$c"
                ;;
            6)
                read -rp "Regex ERE contra a linha de comando: " r
                [ -n "$r" ] && whitelist_cmdline "$r"
                ;;
            0) exit 0 ;;
            *) echo "Opção inválida." ;;
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
        [ $# -ge 1 ] || { echo "uso: cpu-watchdog-ctl unthrottle <PID|all>" >&2; exit 2; }
        unthrottle "$1"
        ;;
    whitelist-cpu)
        [ $# -ge 1 ] || { echo "uso: cpu-watchdog-ctl whitelist-cpu <comm>" >&2; exit 2; }
        whitelist_cpu "$1"
        ;;
    whitelist-mem)
        [ $# -ge 1 ] || { echo "uso: cpu-watchdog-ctl whitelist-mem <comm>" >&2; exit 2; }
        whitelist_mem "$1"
        ;;
    whitelist-cmdline)
        [ $# -ge 1 ] || { echo "uso: cpu-watchdog-ctl whitelist-cmdline <regex>" >&2; exit 2; }
        whitelist_cmdline "$1"
        ;;
    menu) menu ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
