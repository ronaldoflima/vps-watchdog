#!/usr/bin/env bash
# Compatibilidade: o template do repo roda sem erro sob `set -u`.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_example_config_runs_cleanly() {
    sed -E \
        -e "s|^STATE_DIR=.*|STATE_DIR=\"$T/state\"|" \
        -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/watchdog.log\"|" \
        "$EXAMPLE_CONF" >"$T/conf"
    run_watchdog || fail "exit != 0 com o template: $(cat "$T/stderr")"
    assert_eq "" "$(cat "$T/stderr")" "(stderr devia estar vazio)"
}

test_legacy_config_without_new_keys_runs_cleanly() {
    run_watchdog || fail "exit != 0 com config legada: $(cat "$T/stderr")"
    assert_eq "" "$(cat "$T/stderr")"
}

EXAMPLE_CONF="${EXAMPLE_CONF:-$REPO_DIR/config/cpu-watchdog.conf.example}"
EARLYOOM_DEFAULT="${EARLYOOM_DEFAULT:-$REPO_DIR/config/earlyoom.default}"

# Valor de uma variável definida num arquivo shell, sem poluir este processo.
conf_value() {
    # shellcheck disable=SC2016
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2:-}"' _ "$1" "$2"
}

is_valid_ere() {
    local rc=0
    grep -Eq -- "$1" <<<"" 2>/dev/null || rc=$?
    [ "$rc" -le 1 ]
}

test_example_config_ships_without_credentials() {
    assert_eq "" "$(conf_value "$EXAMPLE_CONF" TELEGRAM_BOT_TOKEN)" "(TELEGRAM_BOT_TOKEN no template)"
    assert_eq "" "$(conf_value "$EXAMPLE_CONF" TELEGRAM_CHAT_ID)" "(TELEGRAM_CHAT_ID no template)"
}

test_example_config_regexes_compile() {
    local prefer cmdline
    prefer=$(conf_value "$EXAMPLE_CONF" MEM_PREFER_REGEX)
    cmdline=$(conf_value "$EXAMPLE_CONF" WHITELIST_CMDLINE)
    awk -v re="$prefer" 'BEGIN { exit !("claude" ~ re) }' 2>/dev/null ||
        fail "MEM_PREFER_REGEX inválido no awk ou não casa 'claude': $prefer"
    if [ -n "$cmdline" ]; then
        is_valid_ere "$cmdline" || fail "WHITELIST_CMDLINE não é ERE válida: $cmdline"
    fi
}

test_earlyoom_args_are_well_formed() {
    local EARLYOOM_ARGS; EARLYOOM_ARGS=$(conf_value "$EARLYOOM_DEFAULT" EARLYOOM_ARGS)
    local -a args
    eval "args=($EARLYOOM_ARGS)"
    local i re
    for i in "${!args[@]}"; do
        case "${args[$i]}" in
            --prefer|--avoid)
                re="${args[$((i + 1))]}"
                is_valid_ere "$re" || fail "${args[$i]} não é ERE válida: $re"
                ;;
            -m|-s)
                [[ "${args[$((i + 1))]}" =~ ^[0-9]+,[0-9]+$ ]] || fail "${args[$i]} mal formado"
                ;;
        esac
    done
    [[ "$EARLYOOM_ARGS" == *--avoid* ]] || fail "--avoid ausente"
    local avoid; avoid=$(grep -oE -- "--avoid '[^']+'" <<<"$EARLYOOM_ARGS" | cut -d"'" -f2)
    local proc
    for proc in sshd systemd earlyoom; do
        grep -Eq -- "$avoid" <<<"$proc" || fail "--avoid não protege $proc"
    done
}

test_config_cannot_move_lock_or_proc_dir() {
    EXTRA_CONF='LOCK_FILE=/nonexistent-dir/lock
PROC_DIR=/nonexistent-dir' write_conf
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
    [ -e "$T/lock" ] || fail "lock devia continuar em CPU_WATCHDOG_LOCK"
}

test_env_overrides_ignored_when_running_as_root() {
    PATH="$REPO_DIR/tests/stubs/root:$PATH" run_watchdog && fail "devia falhar ao ignorar CPU_WATCHDOG_CONF"
    assert_contains "$(cat "$T/stderr")" "/etc/cpu-watchdog.conf"
    [ ! -e "$T/watchdog.log" ] || fail "não devia ter usado o config do teste"
}

run_test test_example_config_runs_cleanly
run_test test_legacy_config_without_new_keys_runs_cleanly
run_test test_config_cannot_move_lock_or_proc_dir
run_test test_env_overrides_ignored_when_running_as_root
run_test test_example_config_ships_without_credentials
run_test test_example_config_regexes_compile
run_test test_earlyoom_args_are_well_formed
finish
