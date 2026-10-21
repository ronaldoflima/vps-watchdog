#!/usr/bin/env bash
# Regression cases for interval CPU, pressure alerts and safe actions.
# Calling spawn_victim without arguments is intentional.
# shellcheck disable=SC2119
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_swap_full_with_available_ram_is_quiet() {
    set_meminfo 8000000 4800000 2000000 0
    run_watchdog
    assert_not_contains "$(log_content)" MEM_WARN
}

test_swap_full_with_reduced_ram_warns() {
    set_meminfo 8000000 2000000 2000000 0
    run_watchdog
    assert_contains "$(log_content)" MEM_WARN
}

test_interval_cpu_ignores_lifetime_average() {
    local p i; p=$(spawn_victim)
    fake_proc "$p" hog 0
    ps_cpu "$p" 999 hog
    advance_cpu 0 0; run_watchdog
    for i in 1 2 3; do
        advance_cpu 100 23900
        fake_proc "$p" hog "$((i * 100))"
        run_watchdog
    done
    assert_eq "" "$(calls cpulimit)"
}

test_interval_cpu_detects_busy_process_despite_low_lifetime_average() {
    local p i; p=$(spawn_victim)
    fake_proc "$p" hog 0
    ps_cpu "$p" 1 hog
    advance_cpu 0 0; run_watchdog
    assert_eq "" "$(calls cpulimit)" '(first sample has no interval)'
    for i in 1 2; do
        advance_cpu 6000 18000
        fake_proc "$p" hog "$((i * 6000))"
        run_watchdog
    done
    assert_contains "$(calls cpulimit)" "-p $p -l 50"
}

test_aggregate_tightens_existing_individual_limit() {
    local p i; p=$(spawn_victim)
    fake_proc "$p" hog 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2; do
        advance_cpu 19200 4800
        fake_proc "$p" hog "$((i * 6000))"
        run_watchdog
    done
    assert_contains "$(calls cpulimit)" "-p $p -l 50"
    assert_contains "$(calls cpulimit)" "-p $p -l 20"
    assert_eq 1 "$(wc -l <"$T/state/limited.tsv")" '(one authoritative limit)'
    assert_eq 20 "$(cut -f3 "$T/state/limited.tsv")"
    assert_contains "$(calls systemctl)" "stop cpu-watchdog-limit-${p}-1000.scope"
}

test_memory_does_not_signal_reused_pid() {
    local p i; p=$(spawn_victim)
    fake_proc "$p" hog 0
    # Simulate identity changing after the snapshot, during whitelist lookup.
    mkdir "$T/stubs"
    cat >"$T/stubs/grep" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *race-trigger* ]]; then
    awk '{sub(/1000 0 0$/, "2000 0 0"); print}' "$STUB_DIR/proc/$RACE_PID/stat" >"$STUB_DIR/new-stat"
    mv "$STUB_DIR/new-stat" "$STUB_DIR/proc/$RACE_PID/stat"
fi
exec /usr/bin/grep "$@"
STUB
    chmod +x "$T/stubs/grep"
    ps_mem "$p" 6000000 hog
    EXTRA_CONF='MEM_PROC_SUSTAIN_CHECKS=1
WHITELIST_CMDLINE="race-trigger"' write_conf
    export RACE_PID="$p"
    PATH="$T/stubs:$PATH" run_watchdog
    assert_alive "$p"
    assert_not_contains "$(log_content)" '-> SIGTERM'
    unset RACE_PID
}

run_test test_swap_full_with_available_ram_is_quiet
run_test test_swap_full_with_reduced_ram_warns
run_test test_interval_cpu_ignores_lifetime_average
run_test test_interval_cpu_detects_busy_process_despite_low_lifetime_average
run_test test_aggregate_tightens_existing_individual_limit
run_test test_memory_does_not_signal_reused_pid
finish
