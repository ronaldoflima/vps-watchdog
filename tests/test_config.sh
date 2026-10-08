#!/usr/bin/env bash
# Compatibility: repository template runs without errors under set -u.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_example_config_runs_cleanly() {
    sed -E \
        -e "s|^STATE_DIR=.*|STATE_DIR=\"$T/state\"|" \
        -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/watchdog.log\"|" \
        "$EXAMPLE_CONF" >"$T/conf"
    run_watchdog || fail "exit != 0 with the template: $(cat "$T/stderr")"
    assert_eq "" "$(cat "$T/stderr")" "(stderr should be empty)"
}

test_legacy_config_without_new_keys_runs_cleanly() {
    run_watchdog || fail "exit != 0 with legacy configuration: $(cat "$T/stderr")"
    assert_eq "" "$(cat "$T/stderr")"
}

test_arch_daemons_are_protected_by_template() {
    sed -E \
        -e "s|^STATE_DIR=.*|STATE_DIR=\"$T/state\"|" \
        -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/watchdog.log\"|" \
        -e 's/^SUSTAIN_CHECKS=.*/SUSTAIN_CHECKS=1/' \
        -e 's/^MEM_PROC_SUSTAIN_CHECKS=.*/MEM_PROC_SUSTAIN_CHECKS=1/' \
        "$EXAMPLE_CONF" >"$T/conf"
    local cron fpm hog
    cron=$(spawn_victim --arch-cron); fpm=$(spawn_victim --arch-fpm); hog=$(spawn_victim --control)
    link_proc "$cron" "$fpm" "$hog"
    ps_cpu "$cron" 99 crond
    ps_cpu "$hog" 99 hog
    ps_mem "$cron" 9216000 crond
    ps_mem "$fpm" 9216000 php-fpm
    run_watchdog || fail "template failed: $(cat "$T/stderr")"
    assert_not_contains "$(calls cpulimit)" "-p $cron "
    assert_contains "$(calls cpulimit)" "-p $hog "
    assert_alive "$cron" "(Arch cron daemon must be protected)"
    assert_alive "$fpm" "(Arch PHP-FPM must be protected)"
}

EXAMPLE_CONF="${EXAMPLE_CONF:-$REPO_DIR/config/cpu-watchdog.conf.example}"
EARLYOOM_DEFAULT="${EARLYOOM_DEFAULT:-$REPO_DIR/config/earlyoom.default}"

# Read a variable from a shell file without polluting this process.
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
    assert_eq "" "$(conf_value "$EXAMPLE_CONF" TELEGRAM_BOT_TOKEN)" "(TELEGRAM_BOT_TOKEN in template)"
    assert_eq "" "$(conf_value "$EXAMPLE_CONF" TELEGRAM_CHAT_ID)" "(TELEGRAM_CHAT_ID in template)"
}

test_example_config_regexes_compile() {
    local prefer cmdline
    prefer=$(conf_value "$EXAMPLE_CONF" MEM_PREFER_REGEX)
    cmdline=$(conf_value "$EXAMPLE_CONF" WHITELIST_CMDLINE)
    awk -v re="$prefer" 'BEGIN { exit !("claude" ~ re) }' 2>/dev/null ||
        fail "MEM_PREFER_REGEX invalid in awk or does not match 'claude': $prefer"
    if [ -n "$cmdline" ]; then
        is_valid_ere "$cmdline" || fail "WHITELIST_CMDLINE is not a valid ERE: $cmdline"
    fi
    local first; first=$(conf_value "$EXAMPLE_CONF" MEM_PREFER_FIRST_REGEX)
    is_valid_ere "$first" || fail "MEM_PREFER_FIRST_REGEX is not a valid ERE: $first"
    grep -Eq -- "$first" <<<"node /app/node_modules/.bin/vite" || fail "MEM_PREFER_FIRST_REGEX does not match vite"
    grep -Eq -- "$first" <<<"php vendor/bin/phpunit --filter X" || fail "MEM_PREFER_FIRST_REGEX does not match phpunit"
    ! grep -Eq -- "$first" <<<"/home/u/.local/bin/claude --resume" || fail "MEM_PREFER_FIRST_REGEX matches claude"
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
                is_valid_ere "$re" || fail "${args[$i]} is not a valid ERE: $re"
                ;;
            -m|-s)
                [[ "${args[$((i + 1))]}" =~ ^[0-9]+,[0-9]+$ ]] || fail "${args[$i]} malformed"
                ;;
        esac
    done
    [[ "$EARLYOOM_ARGS" == *--avoid* ]] || fail "--avoid missing"
    local prefer; prefer=$(grep -oE -- "--prefer '[^']+'" <<<"$EARLYOOM_ARGS" | cut -d"'" -f2)
    grep -Eq -- "$prefer" <<<"node" || fail "--prefer does not target node (vite, jest...)"
    grep -Eq -- "$prefer" <<<"php" || fail "--prefer does not target php (phpunit)"
    ! grep -Eq -- "$prefer" <<<"claude" || fail "--prefer should not target claude (test tools first)"
    ! grep -Eq -- "$prefer" <<<"2.1.283" || fail "--prefer should not target the versioned Claude Code binary"
    local avoid; avoid=$(grep -oE -- "--avoid '[^']+'" <<<"$EARLYOOM_ARGS" | cut -d"'" -f2)
    local proc
    for proc in sshd systemd earlyoom; do
        grep -Eq -- "$avoid" <<<"$proc" || fail "--avoid does not protect $proc"
    done
}

test_config_cannot_move_lock_or_proc_dir() {
    EXTRA_CONF='LOCK_FILE=/nonexistent-dir/lock
PROC_DIR=/nonexistent-dir' write_conf
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
    [ -e "$T/lock" ] || fail "lock should remain at CPU_WATCHDOG_LOCK"
}

test_env_overrides_ignored_when_running_as_root() {
    PATH="$REPO_DIR/tests/stubs/root:$PATH" run_watchdog && fail "should fail when ignoring CPU_WATCHDOG_CONF"
    assert_contains "$(cat "$T/stderr")" "/etc/cpu-watchdog.conf"
    [ ! -e "$T/watchdog.log" ] || fail "should not have used the test configuration"
}

run_test test_example_config_runs_cleanly
run_test test_legacy_config_without_new_keys_runs_cleanly
run_test test_arch_daemons_are_protected_by_template
run_test test_config_cannot_move_lock_or_proc_dir
run_test test_env_overrides_ignored_when_running_as_root
run_test test_example_config_ships_without_credentials
run_test test_example_config_regexes_compile
run_test test_earlyoom_args_are_well_formed
finish
