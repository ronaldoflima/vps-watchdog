#!/usr/bin/env bash
# Run real policy evaluation against harmless victims and simulated resource pressure.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

observe_conf() { EXTRA_CONF=$'MODE=observe\nRELEASE_SUSTAIN_CHECKS=1' write_conf; }
no_cpu_actions() {
    assert_eq '' "$(calls cpulimit)"
    assert_eq '' "$(calls systemd-run)"
    assert_not_contains "$(calls systemctl)" 'stop '
}

test_observe_single_cpu_reports_without_throttling() {
    observe_conf
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog
    assert_contains "$(log_content)" 'OBSERVE THROTTLE'
    assert_contains "$(log_content)" 'would limit'
    no_cpu_actions
    assert_alive "$p"
    [ ! -e "$T/state/counts.tsv" ] || fail 'observation populated active counters'
}

test_observe_aggregate_cpu_reports_without_throttling() {
    observe_conf
    local p i; p=$(spawn_victim)
    fake_proc "$p" hog 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2; do
        advance_cpu 19200 4800; fake_proc "$p" hog $((i * 6000)); run_watchdog
    done
    assert_contains "$(log_content)" 'OBSERVE AGG_THROTTLE'
    no_cpu_actions
}

test_observe_forkbomb_reports_without_terminating() {
    observe_conf
    local a b c; a=$(spawn_victim); b=$(spawn_victim); c=$(spawn_victim)
    link_proc "$a" "$b" "$c"
    ps_cpu "$a" 95 worker; ps_cpu "$b" 95 worker; ps_cpu "$c" 95 worker
    run_watchdog; run_watchdog; run_watchdog
    assert_contains "$(log_content)" 'OBSERVE FORKBOMB'
    assert_alive "$a"; assert_alive "$b"; assert_alive "$c"
    no_cpu_actions
}

test_observe_memory_does_not_signal_or_fake_term_escalation() {
    observe_conf
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" 5120000 leaky
    run_watchdog; run_watchdog; run_watchdog
    assert_alive "$p"
    assert_contains "$(log_content)" 'OBSERVE MEM_PROC'
    assert_contains "$(log_content)" 'would send SIGTERM'
    assert_not_contains "$(log_content)" 'ignored SIGTERM'
    no_cpu_actions
}

test_observe_system_memory_selects_one_candidate_without_killing() {
    observe_conf
    set_meminfo 8000000 400000 2000000 100000
    local a b; a=$(spawn_victim); b=$(spawn_victim)
    link_proc "$a" "$b"
    ps_mem "$a" 921600 bigapp; ps_mem "$b" 307200 prefer-me
    run_watchdog; run_watchdog
    assert_alive "$a"; assert_alive "$b"
    assert_contains "$(log_content)" "OBSERVE MEM_SYS host low on memory"
    assert_contains "$(log_content)" "pid=$b"
    assert_eq 1 "$(grep -c 'OBSERVE MEM_SYS host' "$T/watchdog.log")"
}

test_observe_preserves_active_state_and_existing_throttle_on_release() {
    local p helper start now
    p=$(spawn_victim); helper=$(spawn_victim helper); link_proc "$p" "$helper"
    start=$(awk '{print $22}' "/proc/$p/stat"); now=$(date +%s)
    printf '%s:%s\t%s\t50\tyesterday\tTHROTTLE\n' "$p" "$start" "$helper" >"$T/state/limited.tsv"
    printf '%s:%s\t0\t%s\t0\n' "$p" "$start" "$((now - 60))" >"$T/state/release.tsv"
    printf 'active counters\n' >"$T/state/counts.tsv"
    cp -r "$T/state" "$T/original-state"
    observe_conf
    run_watchdog; run_watchdog
    assert_contains "$(log_content)" 'OBSERVE RELEASE'
    assert_alive "$helper"; assert_alive "$p"
    local f
    for f in "$T/original-state/"*; do
        cmp -s "$f" "$T/state/${f##*/}" || fail "active state changed: ${f##*/}"
    done
    no_cpu_actions
}

test_observe_reports_existing_term_escalation_without_sigkill() {
    observe_conf
    local p start; p=$(spawn_victim); link_proc "$p"
    start=$(awk '{print $22}' "/proc/$p/stat")
    mkdir -p "$T/state/observe"
    printf '%s:%s\t2\t1\n' "$p" "$start" >"$T/state/observe/mem_counts.tsv"
    ps_mem "$p" 5120000 leaky
    run_watchdog
    assert_contains "$(log_content)" 'would send SIGKILL'
    assert_alive "$p"
}

test_invalid_mode_fails_before_state_or_actions() {
    EXTRA_CONF='MODE=observ' write_conf
    run_watchdog && fail 'invalid mode accepted'
    assert_contains "$(cat "$T/stderr")" 'Invalid MODE'
    assert_eq '' "$(ls -A "$T/state")"
    no_cpu_actions
}

test_observe_notifications_label_proposals_and_hide_cmdline() {
    TEST_BOT_TOKEN=fake TEST_CHAT_ID=123 observe_conf
    local p; p=$(spawn_victim --password=private-demo-value); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog
    assert_contains "$(calls curl.argv)" 'OBSERVE:'
    assert_contains "$(calls curl.argv)" 'would limit'
    assert_not_contains "$(calls curl.argv)" 'private-demo-value'
    assert_not_contains "$(log_content)" 'private-demo-value'
    no_cpu_actions
}

test_observe_counters_do_not_trigger_actions_when_activating() {
    observe_conf
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog; run_watchdog
    EXTRA_CONF='MODE=active' write_conf
    run_watchdog
    assert_eq '' "$(calls cpulimit)" '(active starts with its own first sample)'
    run_watchdog
    assert_contains "$(calls cpulimit)" "-p $p -l 50"
}

test_observe_respects_real_active_release_grace() {
    observe_conf
    local p start; p=$(spawn_victim); link_proc "$p"
    start=$(awk '{print $22}' "/proc/$p/stat")
    printf '%s:%s\t%s\n' "$p" "$start" "$(( $(date +%s) + 600 ))" >"$T/state/released.tsv"
    ps_cpu "$p" 95 hog
    run_watchdog; run_watchdog; run_watchdog
    assert_not_contains "$(log_content)" 'would limit'
    no_cpu_actions
}

test_observe_missing_cpulimit_reports_alert_instead_of_limit() {
    observe_conf
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 95 hog
    # Imported by the child Bash that runs the real watchdog.
    # shellcheck disable=SC2317,SC2329
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = cpulimit ]; then return 1; fi
        builtin command "$@"
    }
    export -f command
    run_watchdog; run_watchdog
    unset -f command
    assert_contains "$(log_content)" 'would alert (cpulimit missing)'
    assert_not_contains "$(log_content)" 'would limit'
    no_cpu_actions
}

run_test test_observe_missing_cpulimit_reports_alert_instead_of_limit
run_test test_observe_respects_real_active_release_grace
run_test test_observe_notifications_label_proposals_and_hide_cmdline
run_test test_observe_counters_do_not_trigger_actions_when_activating
run_test test_observe_single_cpu_reports_without_throttling
run_test test_observe_aggregate_cpu_reports_without_throttling
run_test test_observe_forkbomb_reports_without_terminating
run_test test_observe_memory_does_not_signal_or_fake_term_escalation
run_test test_observe_system_memory_selects_one_candidate_without_killing
run_test test_observe_preserves_active_state_and_existing_throttle_on_release
run_test test_observe_reports_existing_term_escalation_without_sigkill
run_test test_invalid_mode_fails_before_state_or_actions
finish
