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

# Camada 2 mede o uso real: 4 CPUs (stub de nproc) x 100 Hz x 60 s = 24000 ticks
# por intervalo entre execuções. 19200 de busy = 80% da capacidade (limite: 75%).
agg_busy() { advance_cpu 19200 4800; }
agg_calm() { advance_cpu 1200 22800; }

test_aggregate_ignores_high_lifetime_pcpu_when_machine_is_idle() {
    local a b c d
    a=$(spawn_victim a); b=$(spawn_victim b); c=$(spawn_victim c); d=$(spawn_victim d)
    link_proc "$a" "$b" "$c" "$d"
    ps_cpu "$a" 79 w1; ps_cpu "$b" 79 w2; ps_cpu "$c" 79 w3; ps_cpu "$d" 79 w4
    agg_calm; run_watchdog
    for _ in 1 2 3 4; do agg_calm; run_watchdog; done
    assert_eq "" "$(calls cpulimit)"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

test_aggregate_real_load_throttles_recent_top_consumers_up_to_limit() {
    local a b c d cl
    a=$(spawn_victim a); b=$(spawn_victim b); c=$(spawn_victim c); d=$(spawn_victim d)
    fake_proc "$a" w1 0; fake_proc "$b" w2 0; fake_proc "$c" w3 0; fake_proc "$d" w4 0
    advance_cpu 0 0; run_watchdog
    agg_busy
    fake_proc "$a" w1 1000; fake_proc "$b" w2 6000; fake_proc "$c" w3 5000; fake_proc "$d" w4 4000
    run_watchdog
    assert_eq "" "$(calls cpulimit)" "(só 1 intervalo acima do limite)"
    agg_busy
    fake_proc "$a" w1 2000; fake_proc "$b" w2 12000; fake_proc "$c" w3 10000; fake_proc "$d" w4 8000
    run_watchdog
    cl=$(calls cpulimit)
    assert_eq 2 "$(wc -l <<<"$cl")"
    assert_contains "$cl" "-p $b -l 20"
    assert_contains "$cl" "-p $c -l 20"
    assert_not_contains "$cl" "-p $a "
    assert_not_contains "$cl" "-p $d "
    assert_contains "$(log_content)" "AGG_HIGH uso agregado 320%"
}

test_aggregate_below_threshold_does_nothing() {
    local a b i
    a=$(spawn_victim a); b=$(spawn_victim b)
    fake_proc "$a" w1 0; fake_proc "$b" w2 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2 3 4; do
        advance_cpu 16800 7200
        fake_proc "$a" w1 $((i * 6000)); fake_proc "$b" w2 $((i * 6000))
        run_watchdog
    done
    assert_eq "" "$(calls cpulimit)"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

test_aggregate_requires_sustained_real_load() {
    local a; a=$(spawn_victim a)
    fake_proc "$a" w1 0
    advance_cpu 0 0; run_watchdog
    agg_busy; fake_proc "$a" w1 6000; run_watchdog
    agg_calm; fake_proc "$a" w1 6100; run_watchdog
    agg_busy; fake_proc "$a" w1 12100; run_watchdog
    assert_eq "" "$(calls cpulimit)"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

test_aggregate_skips_kernel_threads_new_and_reused_processes() {
    local kt reused hog young
    kt=$(spawn_victim kt); reused=$(spawn_victim reused); hog=$(spawn_victim hog); young=$(spawn_victim young)
    fake_proc "$kt" kworker 0 2097152
    fake_proc "$reused" app 0 4194560 1000
    fake_proc "$hog" hog 0
    advance_cpu 0 0; run_watchdog
    agg_busy
    fake_proc "$kt" kworker 6000 2097152
    fake_proc "$reused" app 6000 4194560 1000
    fake_proc "$hog" hog 6000
    run_watchdog
    agg_busy
    fake_proc "$kt" kworker 12000 2097152
    fake_proc "$reused" app 12000 4194560 2000
    fake_proc "$hog" hog 12000
    fake_proc "$young" newcomer 12000
    run_watchdog
    assert_eq 1 "$(calls cpulimit | wc -l)"
    assert_contains "$(calls cpulimit)" "-p $hog -l 20"
}

test_aggregate_skips_whitelisted_and_processes_below_limit() {
    local ssh low hog
    ssh=$(spawn_victim ssh); low=$(spawn_victim low); hog=$(spawn_victim hog)
    fake_proc "$ssh" sshd 0; fake_proc "$low" small 0; fake_proc "$hog" hog 0
    advance_cpu 0 0; run_watchdog
    agg_busy
    fake_proc "$ssh" sshd 6000; fake_proc "$low" small 1000; fake_proc "$hog" hog 3000
    run_watchdog
    agg_busy
    fake_proc "$ssh" sshd 12000; fake_proc "$low" small 2000; fake_proc "$hog" hog 6000
    run_watchdog
    assert_eq 1 "$(calls cpulimit | wc -l)"
    assert_contains "$(calls cpulimit)" "-p $hog -l 20"
}

test_aggregate_does_not_count_steal_as_busy() {
    local hog i
    hog=$(spawn_victim hog)
    fake_proc "$hog" hog 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2 3 4; do
        advance_cpu 4800 4800 14400
        fake_proc "$hog" hog $((i * 6000))
        run_watchdog
    done
    assert_eq "" "$(calls cpulimit)"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

test_aggregate_without_proc_stat_is_inactive_and_quiet() {
    local a; a=$(spawn_victim a); link_proc "$a"
    ps_cpu "$a" 79 w1
    run_watchdog; run_watchdog; run_watchdog
    assert_eq "" "$(calls cpulimit)"
    assert_eq "" "$(cat "$T/stderr")"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

test_aggregate_counter_reset_does_not_fire_or_crash() {
    local hog i
    hog=$(spawn_victim hog)
    fake_proc "$hog" hog 0
    advance_cpu 1000000 1000000; run_watchdog
    printf 'cpu  5 0 0 5 0 0 0 0 0 0\n' >"$T/proc/stat"
    run_watchdog || fail "exit != 0 com contador regredindo: $(cat "$T/stderr")"
    assert_eq "" "$(cat "$T/stderr")"
    assert_eq "" "$(calls cpulimit)"
    CPU_USER=5; CPU_IDLE=5
    for i in 1 2 3; do
        agg_busy; fake_proc "$hog" hog $((i * 6000)); run_watchdog
    done
    assert_contains "$(calls cpulimit)" "-p $hog -l 20"
}

test_aggregate_handles_comm_with_spaces_and_parentheses() {
    local hog i
    hog=$(spawn_victim hog)
    fake_proc "$hog" "my (odd) name" 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2; do
        agg_busy; fake_proc "$hog" "my (odd) name" $((i * 6000)); run_watchdog
    done
    assert_contains "$(calls cpulimit)" "-p $hog -l 20"
    assert_contains "$(log_content)" "comm=my (odd) name -> limitado"
}

test_aggregate_sanitizes_control_chars_in_comm_and_keeps_process_visible() {
    local hog i
    hog=$(spawn_victim hog)
    fake_proc "$hog" $'evil)\n7 (x\t\033[31m' 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2; do
        agg_busy; fake_proc "$hog" $'evil)\n7 (x\t\033[31m' $((i * 6000)); run_watchdog
    done
    assert_contains "$(calls cpulimit)" "-p $hog -l 20"
    assert_contains "$(log_content)" "comm=evil)?7 (x??[31m -> limitado"
    assert_not_contains "$(log_content)" $'\033' "(ESC cru no log)"
}

test_aggregate_ignores_corrupt_sample_file() {
    local hog
    hog=$(spawn_victim hog)
    fake_proc "$hog" hog 0
    printf 'lixo\nsem formato\n' >"$T/state/agg_sample.tsv"
    advance_cpu 1000 1000; run_watchdog || fail "exit != 0 com amostra corrompida: $(cat "$T/stderr")"
    assert_eq "" "$(cat "$T/stderr")"
    assert_eq "" "$(calls cpulimit)"
    assert_eq "2" "$(head -1 "$T/state/agg_sample.tsv" | awk -F'\t' '{ print NF }')" "(amostra regravada)"
}

test_aggregate_high_without_candidates_logs_and_does_nothing() {
    local a b i
    a=$(spawn_victim a); b=$(spawn_victim b)
    fake_proc "$a" w1 0; fake_proc "$b" w2 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2 3; do
        agg_busy
        fake_proc "$a" w1 $((i * 1000)); fake_proc "$b" w2 $((i * 1000))
        run_watchdog
    done
    assert_eq "" "$(calls cpulimit)"
    assert_contains "$(log_content)" "AGG_HIGH nenhum processo acima de 20%"
}

test_cpulimit_does_not_hold_watchdog_lock() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog
    assert_contains "$(calls cpulimit)" "-p $p -l 50 -z"
    flock -n "$T/lock" true || fail "cpulimit vivo segurando o flock do watchdog"
}

test_idle_throttled_process_is_released_and_not_relimited() {
    local p; p=$(spawn_victim); link_proc "$p"
    EXTRA_CONF='RELEASE_SUSTAIN_CHECKS=2' write_conf
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog
    assert_contains "$(calls cpulimit)" "-p $p -l 50 -z"
    run_watchdog
    assert_eq "" "$(log_content | grep RELEASE || true)" "(1 medição ociosa de 2)"
    run_watchdog
    assert_contains "$(log_content)" "RELEASE pid=$p"
    assert_contains "$(calls systemctl)" "stop cpu-watchdog-limit-${p}-"
    run_watchdog; run_watchdog
    assert_eq 1 "$(calls cpulimit | wc -l)" "(grace impede novo throttle)"
}

test_release_disabled_keeps_throttle() {
    local p; p=$(spawn_victim); link_proc "$p"
    EXTRA_CONF='RELEASE_SUSTAIN_CHECKS=0' write_conf
    ps_cpu "$p" 95 hog
    for _ in 1 2 3 4 5 6; do run_watchdog; done
    assert_not_contains "$(log_content)" "RELEASE"
}

run_test test_single_process_throttled_after_sustain_checks
run_test test_throttle_uses_own_systemd_scope
run_test test_throttle_not_reapplied_to_same_process
run_test test_process_below_threshold_ignored
run_test test_counter_resets_when_process_drops_below_threshold
run_test test_whitelisted_comm_never_throttled
run_test test_whitelisted_cmdline_never_throttled
run_test test_aggregate_ignores_high_lifetime_pcpu_when_machine_is_idle
run_test test_aggregate_real_load_throttles_recent_top_consumers_up_to_limit
run_test test_aggregate_below_threshold_does_nothing
run_test test_aggregate_requires_sustained_real_load
run_test test_aggregate_skips_kernel_threads_new_and_reused_processes
run_test test_aggregate_skips_whitelisted_and_processes_below_limit
run_test test_aggregate_does_not_count_steal_as_busy
run_test test_aggregate_without_proc_stat_is_inactive_and_quiet
run_test test_aggregate_counter_reset_does_not_fire_or_crash
run_test test_aggregate_handles_comm_with_spaces_and_parentheses
run_test test_aggregate_sanitizes_control_chars_in_comm_and_keeps_process_visible
run_test test_aggregate_ignores_corrupt_sample_file
run_test test_aggregate_high_without_candidates_logs_and_does_nothing
run_test test_cpulimit_does_not_hold_watchdog_lock
run_test test_idle_throttled_process_is_released_and_not_relimited
run_test test_release_disabled_keeps_throttle
finish
