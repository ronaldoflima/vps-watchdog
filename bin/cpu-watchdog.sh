#!/usr/bin/env bash
# Runs every minute through cpu-watchdog.timer.
#
# Layer 1: one process sustaining high CPU for SUSTAIN_CHECKS runs
#          -> throttle that process.
#
# Layer 2: sustained high actual host CPU usage (/proc/stat deltas)
#          -> throttle top consumers, respecting AGG_MAX_THROTTLES.
#
# Uses flock to prevent concurrent runs and identifies processes by
# PID + starttime to handle PID reuse safely.
set -euo pipefail

umask 077

# Path overrides for tests (run without root). Ignored when running as root:
# no inherited environment can redirect the source below to another file
# (sudo with env_keep, systemd drop-ins).
if [ "$(id -u)" -eq 0 ]; then
    unset CPU_WATCHDOG_CONF CPU_WATCHDOG_LOCK CPU_WATCHDOG_PROC_DIR
fi

CONF="${CPU_WATCHDOG_CONF:-/etc/cpu-watchdog.conf}"

# shellcheck source=config/cpu-watchdog.conf.example
source "$CONF"

# After source: configuration cannot control the lock or /proc.
LOCK_FILE="${CPU_WATCHDOG_LOCK:-/run/cpu-watchdog.lock}"
PROC_DIR="${CPU_WATCHDOG_PROC_DIR:-/proc}"

mkdir -p "$STATE_DIR"

COUNTS_FILE="$STATE_DIR/counts.tsv"
LIMITED_FILE="$STATE_DIR/limited.tsv"
AGG_COUNT_FILE="$STATE_DIR/agg_count"
AGG_SAMPLE_FILE="$STATE_DIR/agg_sample.tsv"
RELEASE_FILE="$STATE_DIR/release.tsv"
GRACE_FILE="$STATE_DIR/released.tsv"

touch "$COUNTS_FILE" "$LIMITED_FILE" "$RELEASE_FILE" "$GRACE_FILE"

# Prevent concurrent watchdog runs.
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

    # A newline would become a new curl configuration directive.
    if [[ "${TELEGRAM_BOT_TOKEN}${TELEGRAM_CHAT_ID}" =~ [[:cntrl:]] ]]; then
        log "TELEGRAM disabled: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID contains a control character"
        return 0
    fi

    # Pass token and chat_id through curl configuration on stdin (-K -).
    # In argv, they would be visible to any local user through ps while curl runs.
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
    # comm can contain spaces (e.g. "tmux: server", "tmux: client").
    # WHITELIST_COMM is space-separated, so entries can only be single words.
    # Compare the first word of comm rather than the full value, otherwise
    # "tmux: server" could never match a configurable entry.
    local comm="${1%% *}"
    local w

    for w in ${WHITELIST_COMM:-}; do
        if [ "$comm" = "$w" ]; then
            return 0
        fi
    done

    return 1
}

# Match the FULL command line against WHITELIST_CMDLINE (ERE regex).
# Used when comm is too generic for a whitelist (e.g. "python").
is_whitelisted_cmdline() {
    local pid="$1"
    local comm="$2"

    [ -n "${WHITELIST_CMDLINE:-}" ] || return 1

    get_cmdline "$pid" "$comm" | grep -Eq -- "$WHITELIST_CMDLINE"
}

# Exempt = whitelisted by comm OR command line.
is_exempt() {
    local pid="$1"
    local comm="$2"

    is_whitelisted "$comm" || is_whitelisted_cmdline "$pid" "$comm"
}

pid_start_ticks() {
    local pid="$1"

    # /proc/<pid>/stat:
    #   field 2 = comm, in parentheses
    #   field 22 = starttime
    #
    # comm can contain spaces/parentheses, so strip everything through the
    # last ") ". After that, starttime is field 20.
    awk '{
        sub(/^.*\) /, "")
        print $20
    }' "$PROC_DIR/$pid/stat" 2>/dev/null
}

get_cmdline() {
    local pid="$1"
    local comm="$2"
    local cmdline

    # Put 2>/dev/null BEFORE "<" to suppress redirect errors if the process
    # died after ps took its snapshot; otherwise errors leak to the journal.
    cmdline=$(tr '\0' ' ' 2>/dev/null <"$PROC_DIR/$pid/cmdline" || true)

    if [ -n "$cmdline" ]; then
        printf '%s' "$cmdline"
    else
        printf '%s' "$comm"
    fi
}

# Other processes' command lines may contain secrets (URL tokens,
# --password, DB_PASSWORD=...). Everything written to logs/journal passes
# through get_safe_cmdline. Raw command lines are only used for whitelist
# matching and Layer 3 grouping, never stored. Favor over-redaction.
REDACTED="<redacted>"
SECRET_NAME_RE="pass|pwd|secret|token|key|auth|credential|cookie|session|signature"
CMDLINE_LOG_MAX=1024

# Rules applied to each word split by sanitize_words (sed -z: one word
# per record). Use LC_ALL=C so invalid bytes cannot bypass the rules.
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

# Walk arguments (depth 0) or words within arguments containing spaces
# (depth 1: sh -c, argv rewritten by setproctitle), accumulating SANITIZED.
# Handle context from the preceding word: sensitive flags followed by values,
# user:password and short password flags for known programs.
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

NOW=$(date +%s)

# Processes released due to idle usage are exempt from throttling for
# RELEASE_GRACE_MIN minutes: ps reports a lifetime CPU average that would
# otherwise remain high and immediately trigger another throttle.
declare -A GRACE

while IFS=$'\t' read -r key until_epoch; do
    if [ -n "${key:-}" ] && [ "${until_epoch:-0}" -gt "$NOW" ]; then
        GRACE["$key"]="$until_epoch"
    fi
done <"$GRACE_FILE"

# Apply cpulimit to a PID unless it is already throttled.
#
# key = "pid:starttime", used for deduplication and safe identification
# even when the kernel reuses a PID.
apply_throttle() {
    local pid="$1"
    local key="$2"
    local limit="$3"
    local comm="$4"
    local reason="$5"

    if [ -n "${LIMITED[$key]:-}" ] || [ -n "${GRACE[$key]:-}" ]; then
        return 0
    fi

    if [ ! -d "$PROC_DIR/$pid" ]; then
        return 0
    fi

    local cmdline
    cmdline=$(get_safe_cmdline "$pid" "$comm")

    if command -v cpulimit >/dev/null 2>&1; then
        # cpulimit must leave the cpu-watchdog.service cgroup. The service is
        # oneshot with KillMode=control-group, so systemd kills remaining
        # processes when the script exits, ending throttling within seconds.
        # systemd-run --scope gives it a separate scope (systemd-run uses exec,
        # so $! is the cpulimit PID).
        # Closing fd 9 is essential: cpulimit can live for hours/days. Inheriting
        # the watchdog flock would keep the lock held, making every later run
        # exit at flock -n and leaving the watchdog blind while throttling.
        if command -v systemd-run >/dev/null 2>&1; then
            systemd-run --scope --quiet --collect \
                --unit="cpu-watchdog-limit-${key/:/-}" \
                cpulimit -p "$pid" -l "$limit" -z >/dev/null 2>&1 9>&- &
        else
            cpulimit -p "$pid" -l "$limit" -z >/dev/null 2>&1 9>&- &
        fi
        local cl_pid=$!
        sleep 0.3

        # Avoid recording a cpulimit process that exited immediately.
        if ! kill -0 "$cl_pid" 2>/dev/null; then
            log "ERROR starting cpulimit pid=$pid comm=$comm"
            notify "⚠️ cpu-watchdog: failed to start cpulimit for '$comm' (pid $pid)."
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

        log "$reason pid=$pid comm=$comm -> limited to ${limit}% (cpulimit pid=$cl_pid) cmd=[$cmdline]"

        # Even sanitized command lines stay in the local log, never Telegram.
        notify "⚠️ cpu-watchdog: $reason
process '$comm' (pid $pid) limited to ${limit}%.
full details: ${LOG_FILE}"
    else
        log "ALERT (cpulimit missing) $reason pid=$pid comm=$comm cmd=[$cmdline]"
        notify "⚠️ cpu-watchdog: $reason — process '$comm' (pid $pid). cpulimit is not installed; no action taken."
    fi
}

MY_PID=$$
MY_PPID=$PPID

# Use one snapshot so both CPU layers share the same measurement.
#
# Round %CPU to an integer without forking once per process. comm can
# contain spaces (e.g. "tmux: server"). Reassigning $2 lets awk rebuild
# $0 while preserving fields after pcpu, so read -r pid pcpu comm gets
# the full name in its final field. Keeping only the first word broke
# comm whitelist matching.
PS_SNAPSHOT=$(
    ps -eo pid=,pcpu=,comm= --no-headers |
        awk '{ $2 = int($2 + 0.5); print }'
)

### Layer 1: single process sustained above CPU_THRESHOLD ###

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
            "THROTTLE cpu=${pcpu}% for >=${SUSTAIN_CHECKS}min"; then

            log "Failed to apply throttle pid=$pid comm=$comm"
        fi
    fi
done <<<"$PS_SNAPSHOT"

mv "${COUNTS_FILE}.new" "$COUNTS_FILE"

### Layer 2: aggregate host usage ###
#
# Measure ACTUAL CPU usage between runs (/proc/stat and per-process
# utime+stime deltas). ps %CPU is a lifetime average and includes the
# watchdog's own ps: it does not track current host load and previously
# caused innocent processes to be throttled on nearly idle hosts.

NPROC=$(nproc)

AGG_THRESHOLD_ABS=$(( AGG_CPU_THRESHOLD_PCT * NPROC ))

# Aggregate "cpu" line from /proc/stat. busy excludes idle, iowait and
# steal (guest is already included in user/nice).
AGG_BUSY=""
AGG_TOTAL=""
read -r AGG_BUSY AGG_TOTAL <<<"$(
    awk '$1 == "cpu" && NF >= 8 {
        printf "%.0f %.0f\n", $2 + $3 + $4 + $7 + $8, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
        exit
    }' "$PROC_DIR/stat" 2>/dev/null
)" || true

AGG_SAMPLED=0
AGG_USAGE=""
AGG_D_TOTAL=0
AGG_PROCS=""

if [[ "$AGG_BUSY" =~ ^[0-9]+$ && "$AGG_TOTAL" =~ ^[0-9]+$ ]]; then
    AGG_SAMPLED=1
    AGG_PREV_BUSY=""
    AGG_PREV_TOTAL=""

    if [ -r "$AGG_SAMPLE_FILE" ]; then
        IFS=$'\t' read -r AGG_PREV_BUSY AGG_PREV_TOTAL <"$AGG_SAMPLE_FILE" || true
    fi

    # No previous sample or a regressed counter (reboot): skip evaluation.
    if [[ "$AGG_PREV_BUSY" =~ ^[0-9]+$ && "$AGG_PREV_TOTAL" =~ ^[0-9]+$ ]] &&
       [ "$AGG_TOTAL" -gt "$AGG_PREV_TOTAL" ] &&
       [ "$AGG_BUSY" -ge "$AGG_PREV_BUSY" ]; then
        AGG_D_TOTAL=$(( AGG_TOTAL - AGG_PREV_TOTAL ))
        AGG_USAGE=$(( (AGG_BUSY - AGG_PREV_BUSY) * 100 * NPROC / AGG_D_TOTAL ))
    fi

    # pid:starttime, utime+stime and comm for each process, excluding kernel
    # threads (PF_KTHREAD). Read each stat as a unit: the kernel prints raw
    # comm, whose newlines could split records and hide the process. Files
    # that disappear during reading simply return -1 from getline.
    AGG_PROCS=$(
        awk '
            BEGIN {
                for (i = 1; i < ARGC; i++) {
                    rec = ""
                    while ((getline line < ARGV[i]) > 0) rec = (rec == "" ? line : rec "?" line)
                    close(ARGV[i])
                    if (rec !~ /^[0-9]+ \(/) continue
                    pid = rec
                    sub(/ .*$/, "", pid)
                    comm = rec
                    sub(/^[^(]*\(/, "", comm)
                    sub(/\)[^)]*$/, "", comm)
                    gsub(/[[:cntrl:]]/, "?", comm)
                    sub(/^.*\) /, "", rec)
                    if (split(rec, f, " ") < 20) continue
                    if (int(f[7] / 2097152) % 2 == 1) continue
                    printf "%s:%s\t%.0f\t%s\n", pid, f[20], f[12] + f[13], comm
                }
            }' "$PROC_DIR"/[0-9]*/stat
    )
fi

# Top consumers in the last interval as "usage pid comm" (usage as a
# percentage of one core). Only include processes present in both samples
# with the same pid:starttime (exclude new processes and reused PIDs)
# and usage above the limit that would be applied.
agg_top_consumers() {
    awk -F'\t' -v dtotal="$AGG_D_TOTAL" -v nproc="$NPROC" -v min="$AGG_LIMIT_PERCENT" '
        NR == FNR { if (FNR > 1) prev[$1] = $2; next }
        $1 in prev {
            used = int(($2 - prev[$1]) * 100 * nproc / dtotal)
            if (used > min) {
                split($1, k, ":")
                printf "%d %s %s\n", used, k[1], $3
            }
        }' "$AGG_SAMPLE_FILE" - <<<"$AGG_PROCS" |
        sort -k1,1 -rn
}

old_agg_count=0

if [ -f "$AGG_COUNT_FILE" ]; then
    old_agg_count=$(cat "$AGG_COUNT_FILE" 2>/dev/null || echo 0)
fi

if ! [[ "$old_agg_count" =~ ^[0-9]+$ ]]; then
    old_agg_count=0
fi

if [ -n "$AGG_USAGE" ] && [ "$AGG_USAGE" -ge "$AGG_THRESHOLD_ABS" ]; then
    new_agg_count=$(( old_agg_count + 1 ))
else
    new_agg_count=0
fi

echo "$new_agg_count" >"$AGG_COUNT_FILE"

if [ "$new_agg_count" -ge "$AGG_SUSTAIN_CHECKS" ]; then

    MAX_THROTTLES="${AGG_MAX_THROTTLES:-${AGG_TOP_N:-3}}"

    log "AGG_HIGH aggregate usage ${AGG_USAGE}% (threshold ${AGG_THRESHOLD_ABS}% = ${AGG_CPU_THRESHOLD_PCT}% of ${NPROC} CPUs) sustained >=${AGG_SUSTAIN_CHECKS}min -> throttling up to ${MAX_THROTTLES} processes"

    picked=0

    while read -r _used pid comm && [ "$picked" -lt "$MAX_THROTTLES" ]; do

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

        if [ -n "${LIMITED[$key]:-}" ] || [ -n "${GRACE[$key]:-}" ]; then
            continue
        fi

        if apply_throttle \
            "$pid" \
            "$key" \
            "$AGG_LIMIT_PERCENT" \
            "$comm" \
            "AGG_THROTTLE (aggregate usage ${AGG_USAGE}% sustained)"; then

            picked=$(( picked + 1 ))
        fi

    done < <(agg_top_consumers)

    if [ "$picked" -eq 0 ]; then
        log "AGG_HIGH no process above ${AGG_LIMIT_PERCENT}% eligible for throttling"
    fi
fi

if [ "$AGG_SAMPLED" -eq 1 ]; then
    printf '%s\t%s\n%s\n' "$AGG_BUSY" "$AGG_TOTAL" "$AGG_PROCS" >"${AGG_SAMPLE_FILE}.new" &&
        mv "${AGG_SAMPLE_FILE}.new" "$AGG_SAMPLE_FILE"
else
    rm -f "$AGG_SAMPLE_FILE"
fi

### Layer 3: fork bomb (identical copies of the same command) ###
#
# Handle N processes with the SAME full command line, each above
# CPU_THRESHOLD (e.g. a while :; do :; done loop launched repeatedly).
# Throttling does not scale: with enough processes, some always run at
# full speed. If sustained, terminate all copies with SIGTERM.
#
# Legitimate worker pools (php-fpm, gunicorn, etc.) under heavy load
# could match this pattern. For false positives, add the command name
# to WHITELIST_COMM.

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

        log "FORKBOMB $count identical processes ('$comm') sustained >=${FORKBOMB_SUSTAIN_CHECKS}min -> terminating pids=[$pids] cmd=[$safe_cmdline]"

        for kpid in $pids; do
            kill -TERM "$kpid" 2>/dev/null || true
        done

        notify "🚨 cpu-watchdog: FORKBOMB detected — $count identical processes ('$comm') terminated (SIGTERM).
full details: ${LOG_FILE}"
    fi
done

mv "${FORKBOMB_COUNT_FILE}.new" "$FORKBOMB_COUNT_FILE"

### Layer 4: memory ###
#
# A one-minute interval cannot handle sudden memory spikes; earlyoom
# reacts in ~1s. This layer covers slower problems:
#
#   4a. A leaking process (RSS >= MEM_PROC_KILL_MB for
#       MEM_PROC_SUSTAIN_CHECKS minutes) -> SIGTERM, then SIGKILL
#       on the next run if ignored.
#   4b. Host pressure from MANY medium-sized processes (e.g. 20 claude
#       sessions of ~300 MB) -> early warning, then SIGTERM to the
#       largest process, prioritizing MEM_PREFER_REGEX. Select one at
#       a time to allow memory to recover before choosing another.
#   4c. Report earlyoom kills since the previous run to Telegram
#       (earlyoom runs with DynamicUser and cannot read this .conf).

MEM_COUNTS_FILE="$STATE_DIR/mem_counts.tsv"
MEM_SYS_COUNT_FILE="$STATE_DIR/mem_sys_count"
MEM_ALERT_FILE="$STATE_DIR/mem_last_alert"
EARLYOOM_CURSOR_FILE="$STATE_DIR/earlyoom.cursor"

touch "$MEM_COUNTS_FILE"

# Separate memory whitelist: deliberately exclude "claude" (exempt
# from CPU throttling but eligible for memory kills). Keep databases/infra.
is_mem_exempt() {
    local pid="$1"
    local comm="${2%% *}"  # see comment in is_whitelisted()
    local w

    for w in ${MEM_WHITELIST_COMM:-}; do
        if [ "$comm" = "$w" ]; then
            return 0
        fi
    done

    is_whitelisted_cmdline "$pid" "$2"
}

meminfo_kb() {
    awk -v k="$1:" '$1 == k { print $2 }' "$PROC_DIR/meminfo"
}

# Top groups by process name, e.g. "20×claude=5361MB, 16×node=2318MB".
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

# Memory alert cooldown prevents sending Telegram messages every minute.
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
process '$comm' (pid $pid, ${rss} MB) received SIG$sig.
full details: ${LOG_FILE}"
}

# RSS in MB. Put comm last because it can contain spaces (e.g. "tmux: server").
MEM_SNAPSHOT=$(
    ps -eo pid=,rss=,comm= --no-headers |
        awk '{ $2 = int($2 / 1024); print }'
)

MEM_TOTAL_KB=$(meminfo_kb MemTotal)
MEM_AVAIL_KB=$(meminfo_kb MemAvailable)
SWAP_TOTAL_KB=$(meminfo_kb SwapTotal)
SWAP_FREE_KB=$(meminfo_kb SwapFree)

MEM_AVAIL_PCT=$(( MEM_AVAIL_KB * 100 / MEM_TOTAL_KB ))

# Without swap, treat it as exhausted so only RAM determines the criterion.
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

MEM_STATUS="available RAM ${MEM_AVAIL_PCT}% ($(( MEM_AVAIL_KB / 1024 ))MB), used swap ${SWAP_USED_PCT}%, PSI mem avg60=${PSI_MEM_AVG60}"

## 4a: single process above MEM_PROC_KILL_MB ##

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
                "MEM_PROC ignored SIGTERM, still using ${rss}MB" || true
        elif mem_kill "$pid" "$comm" "$rss" TERM \
            "MEM_PROC ${rss}MB >= ${MEM_PROC_KILL_MB}MB for >=${MEM_PROC_SUSTAIN_CHECKS}min"; then
            termed=1
        fi
    fi

    printf '%s\t%s\t%s\n' "$key" "$new_count" "$termed" >>"${MEM_COUNTS_FILE}.new"
done <<<"$MEM_SNAPSHOT"

mv "${MEM_COUNTS_FILE}.new" "$MEM_COUNTS_FILE"

## 4b: host-wide memory pressure ##
#
# Candidates with RSS >= MEM_VICTIM_MIN_MB as "priority rss pid comm":
#   2 = command line matches MEM_PREFER_FIRST_REGEX (e.g. vite, phpunit,
#       which appear as node/php and cannot be distinguished by comm);
#   1 = comm matches MEM_PREFER_REGEX;
#   0 = other processes.
mem_victim_candidates() {
    local pref rss pid comm

    while read -r pref rss pid comm; do
        if [ -n "${MEM_PREFER_FIRST_REGEX:-}" ] &&
           get_cmdline "$pid" "$comm" | grep -Eq -- "$MEM_PREFER_FIRST_REGEX"; then
            pref=2
        fi
        printf '%s %s %s %s\n' "$pref" "$rss" "$pid" "$comm"
    done < <(
        awk -v re="${MEM_PREFER_REGEX:-^$}" -v min="${MEM_VICTIM_MIN_MB:-200}" '
            $2 >= min {
                pid = $1; rss = $2
                $1 = ""; $2 = ""
                sub(/^ +/, "")
                printf "%d %d %s %s\n", ($0 ~ re), rss, pid, $0
            }' <<<"$MEM_SNAPSHOT"
    )
}

old_sys_count=$(cat "$MEM_SYS_COUNT_FILE" 2>/dev/null || echo 0)
[[ "$old_sys_count" =~ ^[0-9]+$ ]] || old_sys_count=0

if [ "$MEM_AVAIL_PCT" -le "$MEM_AVAIL_KILL_PCT" ] &&
   [ "$SWAP_FREE_PCT" -le "$MEM_SWAP_FREE_KILL_PCT" ]; then
    new_sys_count=$(( old_sys_count + 1 ))
else
    new_sys_count=0
fi

if [ "$new_sys_count" -ge "$MEM_SYS_SUSTAIN_CHECKS" ]; then
    log "MEM_SYS_HIGH $MEM_STATUS sustained >=${MEM_SYS_SUSTAIN_CHECKS}min — top: $(mem_top_groups 5)"

    # Candidates: preferred first, then descending RSS.
    killed=0
    while read -r _pref rss pid comm; do
        if [ "$pid" = "$MY_PID" ] || [ "$pid" = "$MY_PPID" ] || [ "$pid" = "1" ]; then
            continue
        fi

        if is_mem_exempt "$pid" "$comm"; then
            continue
        fi

        if mem_kill "$pid" "$comm" "$rss" TERM \
            "MEM_SYS host low on memory (${MEM_STATUS})"; then
            killed=1
            break
        fi
    done < <(mem_victim_candidates | sort -k1,1rn -k2,2rn)

    if [ "$killed" -eq 0 ]; then
        log "MEM_SYS_HIGH no non-whitelisted candidate with >=${MEM_VICTIM_MIN_MB:-200}MB"
    fi

    # Reset the counter: allow MEM_SYS_SUSTAIN_CHECKS minutes for memory
    # to recover before choosing the next victim.
    new_sys_count=0
elif [ "$MEM_AVAIL_PCT" -le "$MEM_AVAIL_WARN_PCT" ] ||
     { [ "${SWAP_TOTAL_KB:-0}" -gt 0 ] &&
       [ "$SWAP_USED_PCT" -ge "$MEM_SWAP_USED_WARN_PCT" ]; }; then
    mem_alert "low memory — ${MEM_STATUS}.
top: $(mem_top_groups 5)"
fi

echo "$new_sys_count" >"$MEM_SYS_COUNT_FILE"

## 4c: report earlyoom kills ##

# --cursor-file resumes exactly where the previous run stopped, without
# duplicate or missing events. Without a cursor, only read the last minute.
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
        notify "🚨 earlyoom killed process(es) due to low memory:
$(head -n 5 <<<"$eo_kills")
now: ${MEM_STATUS}"
    fi
fi

### Release throttles for processes that became idle ###
#
# Measure ACTUAL target CPU usage between runs (utime+stime from
# /proc/<pid>/stat), rather than ps lifetime %CPU. Under cpulimit, usage
# saturates at the limit. If it stays below RELEASE_IDLE_PCT% of that
# limit for RELEASE_SUSTAIN_CHECKS consecutive runs, remove the throttle.
# RELEASE_SUSTAIN_CHECKS=0 disables automatic release.

proc_cpu_ticks() {
    awk '{
        sub(/^.*\) /, "")
        print $12 + $13
    }' "$PROC_DIR/$1/stat" 2>/dev/null
}

declare -A RELEASED

release_idle_throttles() {
    local sustain="${RELEASE_SUSTAIN_CHECKS:-3}"
    local idle_pct="${RELEASE_IDLE_PCT:-50}"
    local grace_min="${RELEASE_GRACE_MIN:-30}"
    local hz key ticks epoch idle cl_pid limit applied_at reason pid
    local elapsed used threshold scope

    [ "$sustain" -gt 0 ] || { : >"$RELEASE_FILE"; return 0; }

    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)

    local -A prev_ticks prev_epoch prev_idle
    while IFS=$'\t' read -r key ticks epoch idle; do
        if [ -n "${key:-}" ]; then
            prev_ticks["$key"]="$ticks"
            prev_epoch["$key"]="$epoch"
            prev_idle["$key"]="${idle:-0}"
        fi
    done <"$RELEASE_FILE"

    : >"${RELEASE_FILE}.new"

    while IFS=$'\t' read -r key cl_pid limit applied_at reason; do
        [ -n "${key:-}" ] || continue
        pid="${key%%:*}"

        [ -d "$PROC_DIR/$pid" ] || continue
        [ -n "${cl_pid:-}" ] || continue
        [ -d "$PROC_DIR/$cl_pid" ] || continue
        [ "$(pid_start_ticks "$pid" || true)" = "${key#*:}" ] || continue

        ticks=$(proc_cpu_ticks "$pid") || true
        [ -n "${ticks:-}" ] || continue

        idle=0
        if [ -n "${prev_ticks[$key]:-}" ]; then
            elapsed=$(( NOW - prev_epoch[$key] ))
            [ "$elapsed" -ge 1 ] || elapsed=1
            used=$(( (ticks - prev_ticks[$key]) * 100 / (hz * elapsed) ))
            threshold=$(( ${limit:-50} * idle_pct / 100 ))
            if [ "$used" -lt "$threshold" ]; then
                idle=$(( ${prev_idle[$key]:-0} + 1 ))
            fi
        fi

        if [ "$idle" -ge "$sustain" ]; then
            scope="cpu-watchdog-limit-${key/:/-}.scope"
            if ! systemctl stop "$scope" >/dev/null 2>&1; then
                kill "$cl_pid" 2>/dev/null || true
            fi
            RELEASED["$key"]=1
            printf '%s\t%s\n' "$key" "$(( NOW + grace_min * 60 ))" >>"$GRACE_FILE"
            log "RELEASE pid=$pid -> throttle removed: actual usage below ${threshold}% for ${sustain} runs (original reason: ${reason:-?})"
            notify "✅ cpu-watchdog: throttle removed from pid $pid (low actual usage for ${sustain}min)."
        else
            printf '%s\t%s\t%s\t%s\n' "$key" "$ticks" "$NOW" "$idle" >>"${RELEASE_FILE}.new"
        fi
    done <"$LIMITED_FILE"

    mv "${RELEASE_FILE}.new" "$RELEASE_FILE"
}

release_idle_throttles

: >"${GRACE_FILE}.new"
while IFS=$'\t' read -r key until_epoch; do
    if [ -n "${key:-}" ] && [ "${until_epoch:-0}" -gt "$NOW" ]; then
        printf '%s\t%s\n' "$key" "$until_epoch" >>"${GRACE_FILE}.new"
    fi
done <"$GRACE_FILE"
mv "${GRACE_FILE}.new" "$GRACE_FILE"

### Clean up old state ###

: >"${LIMITED_FILE}.new"

while IFS=$'\t' read -r key cpulimit_pid limit applied_at reason; do

    if [ -z "${key:-}" ]; then
        continue
    fi

    pid="${key%%:*}"

    if [ -n "${RELEASED[$key]:-}" ]; then
        continue
    fi

    # Keep entries only if both the target and cpulimit processes still exist.
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
