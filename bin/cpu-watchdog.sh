#!/usr/bin/env bash
# Roda a cada minuto via cpu-watchdog.timer.
#
# Camada 1: processo único sustentando CPU alta por SUSTAIN_CHECKS execuções
#           -> throttle nele.
#
# Camada 2: soma de todos os processos sustentando uso agregado alto
#           -> throttle nos top consumidores, respeitando AGG_MAX_THROTTLES.
#
# O watchdog usa flock para impedir execuções concorrentes e identifica
# processos por PID + starttime para evitar confundir PID reutilizado.
set -euo pipefail

umask 077

# Overrides de caminho para os testes (rodam sem root). Como root eles são
# ignorados: ninguém consegue apontar o `source` abaixo para outro arquivo
# via ambiente herdado (sudo com env_keep, drop-in do systemd).
if [ "$(id -u)" -eq 0 ]; then
    unset CPU_WATCHDOG_CONF CPU_WATCHDOG_LOCK CPU_WATCHDOG_PROC_DIR
fi

CONF="${CPU_WATCHDOG_CONF:-/etc/cpu-watchdog.conf}"

# shellcheck source=config/cpu-watchdog.conf.example
source "$CONF"

# Depois do source: o config não controla lock nem /proc.
LOCK_FILE="${CPU_WATCHDOG_LOCK:-/run/cpu-watchdog.lock}"
PROC_DIR="${CPU_WATCHDOG_PROC_DIR:-/proc}"

mkdir -p "$STATE_DIR"

COUNTS_FILE="$STATE_DIR/counts.tsv"
LIMITED_FILE="$STATE_DIR/limited.tsv"
AGG_COUNT_FILE="$STATE_DIR/agg_count"

touch "$COUNTS_FILE" "$LIMITED_FILE"

# Impede duas execuções simultâneas do watchdog.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG_FILE"
    logger -t cpu-watchdog "$*"
}

notify() {
    local msg="$1"

    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] &&
    [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0

    # Quebra de linha viraria diretiva nova no config do curl.
    if [[ "${TELEGRAM_BOT_TOKEN}${TELEGRAM_CHAT_ID}" =~ [[:cntrl:]] ]]; then
        log "TELEGRAM desativado: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID com caractere de controle"
        return 0
    fi

    # Token e chat_id vão pelo config do curl via stdin (-K -): no argv
    # ficariam visíveis em `ps` para qualquer usuário enquanto o curl roda.
    curl -s --max-time 10 -K - \
        --data-urlencode "text=${msg}" \
        >/dev/null 2>&1 <<CURLCFG || true
url = "$(curl_config_escape "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")"
data = "$(curl_config_escape "chat_id=${TELEGRAM_CHAT_ID}")"
CURLCFG
}

curl_config_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

is_whitelisted() {
    local comm="$1"
    local w

    for w in ${WHITELIST_COMM:-}; do
        if [ "$comm" = "$w" ]; then
            return 0
        fi
    done

    return 1
}

# Casa a linha de comando COMPLETA contra WHITELIST_CMDLINE (regex ERE).
# Usado quando o comm é genérico demais para a whitelist (ex.: "python").
is_whitelisted_cmdline() {
    local pid="$1"
    local comm="$2"

    [ -n "${WHITELIST_CMDLINE:-}" ] || return 1

    get_cmdline "$pid" "$comm" | grep -Eq -- "$WHITELIST_CMDLINE"
}

# Isento = whitelist por comm OU por linha de comando.
is_exempt() {
    local pid="$1"
    local comm="$2"

    is_whitelisted "$comm" || is_whitelisted_cmdline "$pid" "$comm"
}

pid_start_ticks() {
    local pid="$1"

    # /proc/<pid>/stat:
    #   campo 2 = comm, entre parênteses
    #   campo 22 = starttime
    #
    # Como comm pode conter espaços/parênteses, primeiro removemos tudo
    # até o último ") ". A partir daí, starttime passa a ser o campo 20.
    awk '{
        sub(/^.*\) /, "")
        print $20
    }' "$PROC_DIR/$pid/stat" 2>/dev/null
}

get_cmdline() {
    local pid="$1"
    local comm="$2"
    local cmdline

    # 2>/dev/null ANTES do "<": senão o erro do redirect (processo que
    # morreu entre o ps e aqui) vaza pro journal.
    cmdline=$(tr '\0' ' ' 2>/dev/null <"$PROC_DIR/$pid/cmdline" || true)

    if [ -n "$cmdline" ]; then
        printf '%s' "$cmdline"
    else
        printf '%s' "$comm"
    fi
}

# A cmdline de processos alheios pode carregar segredos (tokens em URL,
# --password, DB_PASSWORD=...). Tudo que vai para log/journal passa por
# get_safe_cmdline; a cmdline crua só é usada para casar WHITELIST_CMDLINE e
# agrupar a Camada 3, nunca é gravada. É heurística: prefere redigir demais.
REDACTED="<redacted>"
SECRET_NAME_RE="pass|pwd|secret|token|key|auth|credential|cookie|session|signature"
CMDLINE_LOG_MAX=1024

# Regras aplicadas a cada palavra já separada por sanitize_words (sed -z: uma
# palavra por registro). Rodam com LC_ALL=C para byte inválido não escapar.
SANITIZE_SED=(
    -e "s/^(-{0,2}[A-Za-z0-9_.-]*($SECRET_NAME_RE)[A-Za-z0-9_.-]*=).+/\\1$REDACTED/I"
    -e "s/^([A-Za-z0-9-]*($SECRET_NAME_RE)[A-Za-z0-9-]*:).+/\\1$REDACTED/I"
    -e "s/(\"[A-Za-z0-9_.-]*($SECRET_NAME_RE)[A-Za-z0-9_.-]*\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\\1$REDACTED\"/Ig"
    -e "s#(://[^/:@[:space:]]*:)[^/[:space:]]*@#\\1$REDACTED@#g"
    -e "s#(://)[^/:@[:space:]]{16,}@#\\1$REDACTED@#g"
    -e "s/^([A-Za-z0-9_.-]+:)[^/@[:space:]]+@(tcp|udp|unix)\\(/\\1$REDACTED@\\2(/"
    -e "s/([?&;#][A-Za-z0-9_.-]*($SECRET_NAME_RE|sig)[A-Za-z0-9_.-]*=)[^&#[:space:]]*/\\1$REDACTED/Ig"
    -e "s/bot[0-9]+:[A-Za-z0-9_-]+/bot$REDACTED/g"
    -e "s/(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|(AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,})/\\1$REDACTED/g"
    -e "s/[[:cntrl:]]/?/g"
)

SANITIZED=()
SANITIZED_BYTES=0

sanitized_add() {
    SANITIZED+=("$1")
    SANITIZED_BYTES=$(( SANITIZED_BYTES + ${#1} + 1 ))
}

# Percorre argumentos (depth 0) ou as palavras de um argumento com espaços
# (depth 1: `sh -c '...'`, argv reescrito por setproctitle) e acumula em
# SANITIZED. Trata o que depende da palavra anterior: flag sensível seguida
# do valor, user:senha e flags curtas de senha de programas conhecidos.
sanitize_words() {
    local depth="$1"
    shift
    local word lower next="" prog="" prog_open=1 saw_login=0
    local -a words

    for word in "$@"; do
        if [ "$SANITIZED_BYTES" -gt $(( CMDLINE_LOG_MAX * 2 )) ]; then
            return 0
        fi

        lower="${word,,}"

        case "$next" in
            secret)
                if [[ "$lower" =~ ^[\'\"]?(bearer|basic|token|digest|negotiate)$ ]]; then
                    sanitized_add "$word"
                    continue
                fi
                next=""
                if [[ "$word" != -* ]]; then
                    sanitized_add "$REDACTED"
                    continue
                fi
                ;;
            user)
                next=""
                if [[ "$word" == *:* ]]; then
                    sanitized_add "${word%%:*}:$REDACTED"
                    continue
                fi
                ;;
        esac

        if [[ "$word" =~ [[:space:]] ]]; then
            if [[ "$lower" =~ ^-{0,2}[a-z0-9_.-]*($SECRET_NAME_RE)[a-z0-9_.-]*= ]]; then
                sanitized_add "${word%%=*}=$REDACTED"
            elif [[ "$lower" =~ ^[a-z0-9-]*($SECRET_NAME_RE)[a-z0-9-]*[[:space:]]*: ]]; then
                sanitized_add "${word%%:*}: $REDACTED"
            elif [ "$depth" -eq 0 ]; then
                read -r -d '' -a words <<<"$word" || true
                sanitize_words 1 "${words[@]}"
            else
                sanitized_add "$word"
            fi
            continue
        fi

        if [ "$prog_open" -eq 1 ] && [[ "$word" != *=* ]] && [[ "$word" != -* ]]; then
            prog="${word##*/}"
            prog_open=0
            case "$prog" in
                env|sudo|exec|nohup|nice|command|time) prog_open=1 ;;
            esac
        fi
        [ "$word" = "login" ] && saw_login=1

        case "$prog:$word" in
            mysql*:-p?*|mariadb*:-p?*|sshpass:-p?*)
                sanitized_add "-p$REDACTED"
                continue
                ;;
            sshpass:-p|redis-cli:-a)
                next=secret
                ;;
            docker:-p|podman:-p|nerdctl:-p|buildah:-p|skopeo:-p|helm:-p)
                [ "$saw_login" -eq 1 ] && next=secret
                ;;
        esac

        if [[ "$lower" =~ ^--?[a-z0-9_.-]*($SECRET_NAME_RE)[a-z0-9_.-]*$ ]] ||
           [[ "$lower" =~ ($SECRET_NAME_RE|authorization)[a-z0-9_.-]*:$ ]]; then
            next=secret
        elif [[ "$word" =~ ^(--user|-u|--proxy-user|-U)$ ]]; then
            next=user
        elif [[ "$word" =~ ^(--user=|--proxy-user=|-u).*: ]]; then
            sanitized_add "${word%%:*}:$REDACTED"
            continue
        fi

        case "$word" in
            "&&"|"||"|";"|"|"|*";")
                prog_open=1
                saw_login=0
                ;;
        esac

        sanitized_add "$word"
    done
}

sanitize_args() {
    local LC_ALL=C
    local joined

    SANITIZED=()
    SANITIZED_BYTES=0
    sanitize_words 0 "$@"

    joined=$(printf '%s\0' "${SANITIZED[@]}" | sed -z -E "${SANITIZE_SED[@]}" | tr '\0' ' ') ||
        joined="$REDACTED"
    joined="${joined% }"

    if [ "${#joined}" -gt "$CMDLINE_LOG_MAX" ]; then
        joined="${joined:0:$CMDLINE_LOG_MAX}…"
    fi

    printf '%s' "$joined"
}

get_safe_cmdline() {
    local pid="$1"
    local comm="$2"
    local -a args=()

    mapfile -d '' -t args 2>/dev/null <"$PROC_DIR/$pid/cmdline" || true

    if [ "${#args[@]}" -eq 0 ]; then
        args=("$comm")
    fi

    sanitize_args "${args[@]}"
}

declare -A LIMITED

while IFS=$'\t' read -r key cpulimit_pid limit applied_at reason; do
    if [ -n "${key:-}" ]; then
        LIMITED["$key"]="${cpulimit_pid:-}"
    fi
done <"$LIMITED_FILE"

# Aplica cpulimit num PID, se ainda não estiver limitado.
#
# key = "pid:starttime", usado para deduplicação e identificação segura
# do processo mesmo quando o kernel reutiliza um PID.
apply_throttle() {
    local pid="$1"
    local key="$2"
    local limit="$3"
    local comm="$4"
    local reason="$5"

    if [ -n "${LIMITED[$key]:-}" ]; then
        return 0
    fi

    if [ ! -d "$PROC_DIR/$pid" ]; then
        return 0
    fi

    local cmdline
    cmdline=$(get_safe_cmdline "$pid" "$comm")

    if command -v cpulimit >/dev/null 2>&1; then
        # O cpulimit precisa sair do cgroup do cpu-watchdog.service: é um
        # oneshot com KillMode=control-group, então o systemd mata tudo que
        # sobrou no cgroup quando o script termina — o throttle morria em
        # segundos. Com systemd-run --scope ele ganha um scope próprio
        # (systemd-run faz exec, então $! é o PID do próprio cpulimit).
        if command -v systemd-run >/dev/null 2>&1; then
            systemd-run --scope --quiet --collect \
                --unit="cpu-watchdog-limit-${key/:/-}" \
                cpulimit -p "$pid" -l "$limit" -z >/dev/null 2>&1 &
        else
            cpulimit -p "$pid" -l "$limit" -z >/dev/null 2>&1 &
        fi
        local cl_pid=$!
        sleep 0.3

        # Pequena validação para evitar registrar um processo cpulimit que
        # tenha terminado imediatamente.
        if ! kill -0 "$cl_pid" 2>/dev/null; then
            log "ERRO ao iniciar cpulimit pid=$pid comm=$comm"
            notify "⚠️ cpu-watchdog: falha ao iniciar cpulimit para '$comm' (pid $pid)."
            return 1
        fi

        disown "$cl_pid" 2>/dev/null || true

        local applied_at
        applied_at=$(date '+%Y-%m-%d %H:%M:%S')

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$key" \
            "$cl_pid" \
            "$limit" \
            "$applied_at" \
            "$reason" \
            >>"$LIMITED_FILE"

        LIMITED["$key"]="$cl_pid"

        log "$reason pid=$pid comm=$comm -> limitado a ${limit}% (cpulimit pid=$cl_pid) cmd=[$cmdline]"

        # Mesmo sanitizada, a cmdline fica só no log local — nunca vai pro
        # Telegram.
        notify "⚠️ cpu-watchdog: $reason
processo '$comm' (pid $pid) limitado a ${limit}%.
detalhes completos: ${LOG_FILE}"
    else
        log "ALERTA (cpulimit ausente) $reason pid=$pid comm=$comm cmd=[$cmdline]"
        notify "⚠️ cpu-watchdog: $reason — processo '$comm' (pid $pid). cpulimit não instalado, nenhuma ação tomada."
    fi
}

MY_PID=$$
MY_PPID=$PPID

# Snapshot único para que as duas camadas trabalhem sobre a mesma medição.
#
# Arredonda %CPU para inteiro sem criar um fork por processo no loop.
PS_SNAPSHOT=$(
    ps -eo pid=,pcpu=,comm= --no-headers |
        awk '{ printf "%s %d %s\n", $1, $2 + 0.5, $3 }'
)

### Camada 1: processo único sustentado acima de CPU_THRESHOLD ###

declare -A OLD_COUNT

while IFS=$'\t' read -r key count; do
    if [ -n "${key:-}" ]; then
        OLD_COUNT["$key"]="$count"
    fi
done <"$COUNTS_FILE"

: >"${COUNTS_FILE}.new"

while read -r pid pcpu comm; do
    if [ -z "${pid:-}" ]; then
        continue
    fi

    if [ "$pid" = "$MY_PID" ] || [ "$pid" = "$MY_PPID" ]; then
        continue
    fi

    if [ "$pid" = "1" ]; then
        continue
    fi

    if [ "$pcpu" -lt "$CPU_THRESHOLD" ]; then
        continue
    fi

    if is_exempt "$pid" "$comm"; then
        continue
    fi

    start=$(pid_start_ticks "$pid") || true

    if [ -z "${start:-}" ]; then
        continue
    fi

    key="${pid}:${start}"

    new_count=$(( ${OLD_COUNT[$key]:-0} + 1 ))

    printf '%s\t%s\n' "$key" "$new_count" >>"${COUNTS_FILE}.new"

    if [ "$new_count" -ge "$SUSTAIN_CHECKS" ]; then
        if ! apply_throttle \
            "$pid" \
            "$key" \
            "$LIMIT_PERCENT" \
            "$comm" \
            "THROTTLE cpu=${pcpu}% por >=${SUSTAIN_CHECKS}min"; then

            log "Falha ao aplicar throttle pid=$pid comm=$comm"
        fi
    fi
done <<<"$PS_SNAPSHOT"

mv "${COUNTS_FILE}.new" "$COUNTS_FILE"

### Camada 2: uso agregado da máquina ###

NPROC=$(nproc)

AGG_THRESHOLD_ABS=$(( AGG_CPU_THRESHOLD_PCT * NPROC ))

TOTAL_PCPU=$(
    awk '{ s += $2 } END { printf "%d", s + 0 }' <<<"$PS_SNAPSHOT"
)

old_agg_count=0

if [ -f "$AGG_COUNT_FILE" ]; then
    old_agg_count=$(cat "$AGG_COUNT_FILE" 2>/dev/null || echo 0)
fi

if ! [[ "$old_agg_count" =~ ^[0-9]+$ ]]; then
    old_agg_count=0
fi

if [ "$TOTAL_PCPU" -ge "$AGG_THRESHOLD_ABS" ]; then
    new_agg_count=$(( old_agg_count + 1 ))
else
    new_agg_count=0
fi

echo "$new_agg_count" >"$AGG_COUNT_FILE"

if [ "$new_agg_count" -ge "$AGG_SUSTAIN_CHECKS" ]; then

    MAX_THROTTLES="${AGG_MAX_THROTTLES:-${AGG_TOP_N:-3}}"

    log "AGG_HIGH uso agregado ${TOTAL_PCPU}% (limite ${AGG_THRESHOLD_ABS}% = ${AGG_CPU_THRESHOLD_PCT}% de ${NPROC} CPUs) sustentado >=${AGG_SUSTAIN_CHECKS}min -> throttling de até ${MAX_THROTTLES} processos"

    picked=0

    while read -r pid pcpu comm && [ "$picked" -lt "$MAX_THROTTLES" ]; do

        if [ -z "${pid:-}" ]; then
            continue
        fi

        if [ "$pid" = "$MY_PID" ] || [ "$pid" = "$MY_PPID" ]; then
            continue
        fi

        if [ "$pid" = "1" ]; then
            continue
        fi

        if is_exempt "$pid" "$comm"; then
            continue
        fi

        start=$(pid_start_ticks "$pid") || true

        if [ -z "${start:-}" ]; then
            continue
        fi

        key="${pid}:${start}"

        if [ -n "${LIMITED[$key]:-}" ]; then
            continue
        fi

        if apply_throttle \
            "$pid" \
            "$key" \
            "$AGG_LIMIT_PERCENT" \
            "$comm" \
            "AGG_THROTTLE (uso agregado ${TOTAL_PCPU}% sustentado)"; then

            picked=$(( picked + 1 ))
        fi

    done < <(sort -k2,2 -rn <<<"$PS_SNAPSHOT")
fi

### Camada 3: fork bomb (várias cópias idênticas do mesmo comando) ###
#
# Cobre o caso de N processos com a MESMA linha de comando completa, cada um
# sozinho já acima de CPU_THRESHOLD (ex.: um `while :; do :; done` disparado
# várias vezes). Throttle não escala nesse caso -- com processos suficientes,
# sempre sobra gente rodando a todo vapor. Sustentado, mata todos (SIGTERM).
#
# Cuidado: pools legítimos de workers (php-fpm, gunicorn, etc.) sob carga
# pesada podem, em tese, casar com esse padrão. Se acontecer um falso
# positivo, adicione o comando à WHITELIST_COMM.

FORKBOMB_COUNT_FILE="$STATE_DIR/forkbomb_counts.tsv"
touch "$FORKBOMB_COUNT_FILE"

declare -A OLD_FB_COUNT
while IFS=$'\t' read -r sig count; do
    if [ -n "${sig:-}" ]; then
        OLD_FB_COUNT["$sig"]="$count"
    fi
done <"$FORKBOMB_COUNT_FILE"

declare -A FB_GROUP_PIDS
declare -A FB_GROUP_COMM

while read -r pid pcpu comm; do
    if [ -z "${pid:-}" ]; then
        continue
    fi

    if [ "$pid" = "$MY_PID" ] || [ "$pid" = "$MY_PPID" ]; then
        continue
    fi

    if [ "$pid" = "1" ]; then
        continue
    fi

    if [ "$pcpu" -lt "$CPU_THRESHOLD" ]; then
        continue
    fi

    if is_exempt "$pid" "$comm"; then
        continue
    fi

    cmdline=$(get_cmdline "$pid" "$comm")

    FB_GROUP_PIDS["$cmdline"]="${FB_GROUP_PIDS[$cmdline]:-}${FB_GROUP_PIDS[$cmdline]:+ }$pid"
    FB_GROUP_COMM["$cmdline"]="$comm"
done <<<"$PS_SNAPSHOT"

: >"${FORKBOMB_COUNT_FILE}.new"

for cmdline in "${!FB_GROUP_PIDS[@]}"; do
    pids="${FB_GROUP_PIDS[$cmdline]}"
    count=$(wc -w <<<"$pids")

    if [ "$count" -lt "$FORKBOMB_MIN_COUNT" ]; then
        continue
    fi

    sig=$(printf '%s' "$cmdline" | sha256sum | cut -d' ' -f1)

    new_fb_count=$(( ${OLD_FB_COUNT[$sig]:-0} + 1 ))
    printf '%s\t%s\n' "$sig" "$new_fb_count" >>"${FORKBOMB_COUNT_FILE}.new"

    if [ "$new_fb_count" -ge "$FORKBOMB_SUSTAIN_CHECKS" ]; then
        comm="${FB_GROUP_COMM[$cmdline]}"
        safe_cmdline=$(get_safe_cmdline "${pids%% *}" "$comm")

        log "FORKBOMB $count processos idênticos ('$comm') sustentado >=${FORKBOMB_SUSTAIN_CHECKS}min -> matando pids=[$pids] cmd=[$safe_cmdline]"

        for kpid in $pids; do
            kill -TERM "$kpid" 2>/dev/null || true
        done

        notify "🚨 cpu-watchdog: FORKBOMB detectado — $count processos idênticos ('$comm') encerrados (SIGTERM).
detalhes completos: ${LOG_FILE}"
    fi
done

mv "${FORKBOMB_COUNT_FILE}.new" "$FORKBOMB_COUNT_FILE"

### Camada 4: memória ###
#
# O cron de 1 minuto é lento demais para segurar um pico súbito de memória —
# isso é trabalho do earlyoom (reage em ~1s). Esta camada cobre o que o
# earlyoom não vê bem:
#
#   4a. processo único vazando (RSS >= MEM_PROC_KILL_MB por
#       MEM_PROC_SUSTAIN_CHECKS minutos) -> SIGTERM, e SIGKILL na execução
#       seguinte se ele ignorar;
#   4b. máquina toda pressionada por MUITOS processos médios (ex.: 20 sessões
#       claude de ~300 MB) -> alerta cedo e, sustentado, SIGTERM no maior
#       processo, priorizando MEM_PREFER_REGEX. Um por vez, dando tempo da
#       memória voltar antes de escolher outro;
#   4c. relata no Telegram os kills que o earlyoom fez desde a última
#       execução (o earlyoom roda com DynamicUser e não lê este .conf).

MEM_COUNTS_FILE="$STATE_DIR/mem_counts.tsv"
MEM_SYS_COUNT_FILE="$STATE_DIR/mem_sys_count"
MEM_ALERT_FILE="$STATE_DIR/mem_last_alert"
EARLYOOM_CURSOR_FILE="$STATE_DIR/earlyoom.cursor"

touch "$MEM_COUNTS_FILE"

# Whitelist própria da memória: "claude" sai daqui de propósito (é isento de
# throttle de CPU, mas pode ser morto por memória). Bancos e infra ficam.
is_mem_exempt() {
    local pid="$1"
    local comm="$2"
    local w

    for w in ${MEM_WHITELIST_COMM:-}; do
        if [ "$comm" = "$w" ]; then
            return 0
        fi
    done

    is_whitelisted_cmdline "$pid" "$comm"
}

meminfo_kb() {
    awk -v k="$1:" '$1 == k { print $2 }' "$PROC_DIR/meminfo"
}

# Top grupos por nome de processo, ex.: "20×claude=5361MB, 16×node=2318MB".
mem_top_groups() {
    awk '{
        rss = $2
        $1 = ""; $2 = ""
        sub(/^ +/, "")
        s[$0] += rss; c[$0]++
    } END {
        for (k in s) printf "%d\t%d\t%s\n", s[k], c[k], k
    }' <<<"$MEM_SNAPSHOT" |
        sort -t$'\t' -k1,1rn |
        head -n "${1:-5}" |
        awk -F'\t' '{ printf "%s%s×%s=%dMB", (NR > 1 ? ", " : ""), $2, $3, $1 }'
}

# Alerta de memória com cooldown, pra não mandar Telegram todo minuto.
mem_alert() {
    local msg="$1"
    local now last

    now=$(date +%s)
    last=$(cat "$MEM_ALERT_FILE" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    if [ $(( now - last )) -ge $(( ${MEM_ALERT_COOLDOWN_MIN:-30} * 60 )) ]; then
        echo "$now" >"$MEM_ALERT_FILE"
        log "MEM_WARN $msg"
        notify "🟠 cpu-watchdog: $msg"
    fi
}

mem_kill() {
    local pid="$1"
    local comm="$2"
    local rss="$3"
    local sig="$4"
    local reason="$5"
    local cmdline

    [ -d "$PROC_DIR/$pid" ] || return 1

    cmdline=$(get_safe_cmdline "$pid" "$comm")

    kill "-$sig" "$pid" 2>/dev/null || return 1

    log "$reason pid=$pid comm=$comm rss=${rss}MB -> SIG$sig cmd=[$cmdline]"
    notify "🚨 cpu-watchdog: $reason
processo '$comm' (pid $pid, ${rss} MB) recebeu SIG$sig.
detalhes completos: ${LOG_FILE}"
}

# RSS em MB. comm pode ter espaços (ex.: "tmux: server"), por isso vai no fim.
MEM_SNAPSHOT=$(
    ps -eo pid=,rss=,comm= --no-headers |
        awk '{ $2 = int($2 / 1024); print }'
)

MEM_TOTAL_KB=$(meminfo_kb MemTotal)
MEM_AVAIL_KB=$(meminfo_kb MemAvailable)
SWAP_TOTAL_KB=$(meminfo_kb SwapTotal)
SWAP_FREE_KB=$(meminfo_kb SwapFree)

MEM_AVAIL_PCT=$(( MEM_AVAIL_KB * 100 / MEM_TOTAL_KB ))

# Sem swap, trata como "swap esgotado" para o critério depender só da RAM.
if [ "${SWAP_TOTAL_KB:-0}" -gt 0 ]; then
    SWAP_FREE_PCT=$(( SWAP_FREE_KB * 100 / SWAP_TOTAL_KB ))
else
    SWAP_FREE_PCT=0
fi
SWAP_USED_PCT=$(( 100 - SWAP_FREE_PCT ))

PSI_MEM_AVG60=$(
    awk '$1 == "some" { sub(/avg60=/, "", $3); print $3 }' \
        "$PROC_DIR/pressure/memory" 2>/dev/null || echo "?"
)

MEM_STATUS="RAM livre ${MEM_AVAIL_PCT}% ($(( MEM_AVAIL_KB / 1024 ))MB), swap usado ${SWAP_USED_PCT}%, PSI mem avg60=${PSI_MEM_AVG60}"

## 4a: processo único acima de MEM_PROC_KILL_MB ##

declare -A OLD_MEM_COUNT
declare -A OLD_MEM_TERMED

while IFS=$'\t' read -r key count termed; do
    if [ -n "${key:-}" ]; then
        OLD_MEM_COUNT["$key"]="$count"
        OLD_MEM_TERMED["$key"]="$termed"
    fi
done <"$MEM_COUNTS_FILE"

: >"${MEM_COUNTS_FILE}.new"

while read -r pid rss comm; do
    if [ -z "${pid:-}" ]; then
        continue
    fi

    if [ "$pid" = "$MY_PID" ] || [ "$pid" = "$MY_PPID" ] || [ "$pid" = "1" ]; then
        continue
    fi

    if [ "$rss" -lt "$MEM_PROC_KILL_MB" ]; then
        continue
    fi

    if is_mem_exempt "$pid" "$comm"; then
        continue
    fi

    start=$(pid_start_ticks "$pid") || true

    if [ -z "${start:-}" ]; then
        continue
    fi

    key="${pid}:${start}"

    new_count=$(( ${OLD_MEM_COUNT[$key]:-0} + 1 ))
    termed="${OLD_MEM_TERMED[$key]:-0}"

    if [ "$new_count" -ge "$MEM_PROC_SUSTAIN_CHECKS" ]; then
        if [ "$termed" = "1" ]; then
            mem_kill "$pid" "$comm" "$rss" KILL \
                "MEM_PROC ignorou SIGTERM, ainda com ${rss}MB" || true
        elif mem_kill "$pid" "$comm" "$rss" TERM \
            "MEM_PROC ${rss}MB >= ${MEM_PROC_KILL_MB}MB por >=${MEM_PROC_SUSTAIN_CHECKS}min"; then
            termed=1
        fi
    fi

    printf '%s\t%s\t%s\n' "$key" "$new_count" "$termed" >>"${MEM_COUNTS_FILE}.new"
done <<<"$MEM_SNAPSHOT"

mv "${MEM_COUNTS_FILE}.new" "$MEM_COUNTS_FILE"

## 4b: pressão de memória da máquina toda ##

old_sys_count=$(cat "$MEM_SYS_COUNT_FILE" 2>/dev/null || echo 0)
[[ "$old_sys_count" =~ ^[0-9]+$ ]] || old_sys_count=0

if [ "$MEM_AVAIL_PCT" -le "$MEM_AVAIL_KILL_PCT" ] &&
   [ "$SWAP_FREE_PCT" -le "$MEM_SWAP_FREE_KILL_PCT" ]; then
    new_sys_count=$(( old_sys_count + 1 ))
else
    new_sys_count=0
fi

if [ "$new_sys_count" -ge "$MEM_SYS_SUSTAIN_CHECKS" ]; then
    log "MEM_SYS_HIGH $MEM_STATUS sustentado >=${MEM_SYS_SUSTAIN_CHECKS}min — top: $(mem_top_groups 5)"

    # Candidatos: preferidos primeiro, depois por RSS decrescente.
    killed=0
    while read -r _pref rss pid comm; do
        if [ "$pid" = "$MY_PID" ] || [ "$pid" = "$MY_PPID" ] || [ "$pid" = "1" ]; then
            continue
        fi

        if is_mem_exempt "$pid" "$comm"; then
            continue
        fi

        if mem_kill "$pid" "$comm" "$rss" TERM \
            "MEM_SYS máquina sem memória (${MEM_STATUS})"; then
            killed=1
            break
        fi
    done < <(
        awk -v re="${MEM_PREFER_REGEX:-^$}" -v min="${MEM_VICTIM_MIN_MB:-200}" '
            $2 >= min {
                pid = $1; rss = $2
                $1 = ""; $2 = ""
                sub(/^ +/, "")
                printf "%d %d %s %s\n", ($0 ~ re), rss, pid, $0
            }' <<<"$MEM_SNAPSHOT" |
            sort -k1,1rn -k2,2rn
    )

    if [ "$killed" -eq 0 ]; then
        log "MEM_SYS_HIGH nenhum candidato fora da whitelist com >=${MEM_VICTIM_MIN_MB:-200}MB"
    fi

    # Zera o contador: dá MEM_SYS_SUSTAIN_CHECKS minutos para a memória voltar
    # antes de escolher a próxima vítima.
    new_sys_count=0
elif [ "$MEM_AVAIL_PCT" -le "$MEM_AVAIL_WARN_PCT" ] ||
     { [ "${SWAP_TOTAL_KB:-0}" -gt 0 ] &&
       [ "$SWAP_USED_PCT" -ge "$MEM_SWAP_USED_WARN_PCT" ]; }; then
    mem_alert "memória baixa — ${MEM_STATUS}.
top: $(mem_top_groups 5)"
fi

echo "$new_sys_count" >"$MEM_SYS_COUNT_FILE"

## 4c: relatar kills do earlyoom ##

# --cursor-file retoma exatamente de onde a execução anterior parou (sem
# duplicar nem perder eventos). Sem cursor ainda, olha só o último minuto.
if command -v journalctl >/dev/null 2>&1 &&
   systemctl is-active --quiet earlyoom 2>/dev/null; then
    eo_args=(--cursor-file="$EARLYOOM_CURSOR_FILE")
    [ -f "$EARLYOOM_CURSOR_FILE" ] || eo_args+=(--since "-65s")

    eo_kills=$(
        journalctl -u earlyoom "${eo_args[@]}" -o cat --no-pager -q 2>/dev/null |
            grep -E 'sending SIG(TERM|KILL) to process' || true
    )

    if [ -n "$eo_kills" ]; then
        log "EARLYOOM $(tr '\n' ';' <<<"$eo_kills")"
        notify "🚨 earlyoom matou processo(s) por falta de memória:
$(head -n 5 <<<"$eo_kills")
agora: ${MEM_STATUS}"
    fi
fi

### Limpeza de estados antigos ###

: >"${LIMITED_FILE}.new"

while IFS=$'\t' read -r key cpulimit_pid limit applied_at reason; do

    if [ -z "${key:-}" ]; then
        continue
    fi

    pid="${key%%:*}"

    # Mantém apenas se o processo alvo e o cpulimit ainda existem.
    if [ -d "$PROC_DIR/$pid" ] &&
       [ -n "${cpulimit_pid:-}" ] &&
       [ -d "$PROC_DIR/$cpulimit_pid" ]; then

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$key" \
            "$cpulimit_pid" \
            "${limit:-}" \
            "${applied_at:-}" \
            "${reason:-}" \
            >>"${LIMITED_FILE}.new"
    fi

done <"$LIMITED_FILE"

mv "${LIMITED_FILE}.new" "$LIMITED_FILE"
