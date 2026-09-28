#!/usr/bin/env bash
# Camadas 1 e 2: throttle por CPU.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_single_process_throttled_after_sustain_checks() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
    assert_eq "" "$(calls cpulimit)" "(não deve agir na 1ª medição)"
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
    assert_contains "$(calls cpulimit)" "-p $p -l 50 -z"
    assert_contains "$(log_content)" "THROTTLE cpu=95%"
}

test_throttle_uses_own_systemd_scope() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog
    assert_contains "$(calls systemd-run)" "--scope"
    assert_contains "$(calls systemd-run)" "--unit=cpu-watchdog-limit-${p}-"
}

test_throttle_not_reapplied_to_same_process() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog; run_watchdog; run_watchdog
    assert_eq 1 "$(calls cpulimit | wc -l)"
}

test_process_below_threshold_ignored() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 79 almost
    run_watchdog; run_watchdog; run_watchdog
    assert_eq "" "$(calls cpulimit)"
}

test_counter_resets_when_process_drops_below_threshold() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 bursty
    run_watchdog
    : >"$T/ps_cpu"; ps_cpu "$p" 10 bursty
    run_watchdog
    : >"$T/ps_cpu"; ps_cpu "$p" 95 bursty
    run_watchdog
    assert_eq "" "$(calls cpulimit)"
}

test_whitelisted_comm_never_throttled() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 99 sshd
    run_watchdog; run_watchdog; run_watchdog
    assert_eq "" "$(calls cpulimit)"
}

test_whitelisted_cmdline_never_throttled() {
    EXTRA_CONF='WHITELIST_CMDLINE="important-batch-job"' write_conf
    local p; p=$(spawn_victim important-batch-job --run); link_proc "$p"
    ps_cpu "$p" 99 python3
    run_watchdog; run_watchdog; run_watchdog
    assert_eq "" "$(calls cpulimit)"
}

test_aggregate_load_throttles_top_consumers_up_to_limit() {
    local a b c d
    a=$(spawn_victim a); b=$(spawn_victim b); c=$(spawn_victim c); d=$(spawn_victim d)
    link_proc "$a" "$b" "$c" "$d"
    ps_cpu "$a" 70 w1; ps_cpu "$b" 78 w2; ps_cpu "$c" 77 w3; ps_cpu "$d" 76 w4
    run_watchdog
    assert_eq "" "$(calls cpulimit)" "(agregado só na 1ª medição)"
    run_watchdog
    local cl; cl=$(calls cpulimit)
    assert_eq 2 "$(wc -l <<<"$cl")"
    assert_contains "$cl" "-p $b -l 20"
    assert_contains "$cl" "-p $c -l 20"
    assert_not_contains "$cl" "-p $a "
    assert_contains "$(log_content)" "AGG_HIGH uso agregado 301%"
}

test_aggregate_below_threshold_does_nothing() {
    local a b; a=$(spawn_victim a); b=$(spawn_victim b); link_proc "$a" "$b"
    ps_cpu "$a" 70 w1; ps_cpu "$b" 70 w2
    run_watchdog; run_watchdog; run_watchdog
    assert_eq "" "$(calls cpulimit)"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

run_test test_single_process_throttled_after_sustain_checks
run_test test_throttle_uses_own_systemd_scope
run_test test_throttle_not_reapplied_to_same_process
run_test test_process_below_threshold_ignored
run_test test_counter_resets_when_process_drops_below_threshold
run_test test_whitelisted_comm_never_throttled
run_test test_whitelisted_cmdline_never_throttled
run_test test_aggregate_load_throttles_top_consumers_up_to_limit
run_test test_aggregate_below_threshold_does_nothing
finish
