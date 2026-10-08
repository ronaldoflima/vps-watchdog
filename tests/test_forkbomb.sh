#!/usr/bin/env bash
# Layer 3: identical copies of the same command -> SIGTERM to all.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Isolate Layer 3: Layer 1 never reaches its sustain threshold in these tests.
FB_CONF='SUSTAIN_CHECKS=99
AGG_SUSTAIN_CHECKS=99'

spawn_copies() {
    local n="$1"; shift
    local p
    for _ in $(seq 1 "$n"); do
        p=$(spawn_victim "$@"); link_proc "$p"; ps_cpu "$p" 99 spinner
        echo "$p"
    done
}

test_identical_copies_killed_after_sustain() {
    EXTRA_CONF="$FB_CONF" write_conf
    local pids; pids=$(spawn_copies 3 --spin)
    run_watchdog
    local p
    for p in $pids; do assert_alive "$p" "(first measurement)"; done
    run_watchdog
    for p in $pids; do assert_dead "$p"; done
    assert_contains "$(log_content)" "FORKBOMB 3 identical processes"
}

test_fewer_than_min_count_not_killed() {
    EXTRA_CONF="$FB_CONF" write_conf
    local pids; pids=$(spawn_copies 2 --spin)
    run_watchdog; run_watchdog; run_watchdog
    local p
    for p in $pids; do assert_alive "$p"; done
}

test_different_cmdlines_not_grouped() {
    EXTRA_CONF="$FB_CONF" write_conf
    local a b c
    a=$(spawn_copies 1 --one); b=$(spawn_copies 1 --two); c=$(spawn_copies 1 --three)
    run_watchdog; run_watchdog; run_watchdog
    assert_alive "$a"; assert_alive "$b"; assert_alive "$c"
}

test_copies_below_cpu_threshold_not_killed() {
    EXTRA_CONF="$FB_CONF" write_conf
    local p pids=""
    for _ in 1 2 3; do
        p=$(spawn_victim --idle); link_proc "$p"; ps_cpu "$p" 40 worker; pids+=" $p"
    done
    run_watchdog; run_watchdog; run_watchdog
    for p in $pids; do assert_alive "$p"; done
}

test_whitelisted_copies_not_killed() {
    EXTRA_CONF="$FB_CONF" write_conf
    local p pids=""
    for _ in 1 2 3; do
        p=$(spawn_victim --pool); link_proc "$p"; ps_cpu "$p" 99 sshd; pids+=" $p"
    done
    run_watchdog; run_watchdog; run_watchdog
    for p in $pids; do assert_alive "$p"; done
}

run_test test_identical_copies_killed_after_sustain
run_test test_fewer_than_min_count_not_killed
run_test test_different_cmdlines_not_grouped
run_test test_copies_below_cpu_threshold_not_killed
run_test test_whitelisted_copies_not_killed
finish
