#!/usr/bin/env bash
# Camada 4: memória (4a processo único, 4b pressão da máquina, 4c earlyoom).
# spawn_victim sem argumentos é intencional (vítima genérica).
# shellcheck disable=SC2119
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MB=1024

test_large_process_termed_after_sustain() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" $((5000 * MB)) leaky
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
    assert_alive "$p" "(1ª medição)"
    run_watchdog
    assert_dead "$p"
    assert_contains "$(log_content)" "MEM_PROC 5000MB >= 4096MB"
    assert_contains "$(log_content)" "SIGTERM"
}

test_process_ignoring_term_gets_kill_next_run() {
    local p; p=$(spawn_stubborn_victim); link_proc "$p"
    ps_mem "$p" $((5000 * MB)) stubborn
    run_watchdog; run_watchdog
    assert_alive "$p" "(ignorou SIGTERM)"
    run_watchdog
    assert_dead "$p"
    assert_contains "$(log_content)" "MEM_PROC ignorou SIGTERM"
    assert_contains "$(log_content)" "SIGKILL"
}

test_process_below_mem_limit_untouched() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" $((4000 * MB)) big
    run_watchdog; run_watchdog; run_watchdog
    assert_alive "$p"
}

test_mem_whitelist_protects_process() {
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" $((9000 * MB)) systemd
    run_watchdog; run_watchdog; run_watchdog
    assert_alive "$p"
}

test_cpu_whitelist_does_not_protect_from_memory_layer() {
    EXTRA_CONF='WHITELIST_COMM="sshd systemd agent"' write_conf
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" $((5000 * MB)) agent
    run_watchdog; run_watchdog
    assert_dead "$p"
}

test_system_pressure_kills_one_preferred_process() {
    set_meminfo 8000000 400000 2000000 100000
    local pref big
    pref=$(spawn_victim); big=$(spawn_victim); link_proc "$pref" "$big"
    ps_mem "$big" $((900 * MB)) bigapp
    ps_mem "$pref" $((300 * MB)) prefer-me
    run_watchdog
    assert_alive "$pref" "(1ª medição)"
    run_watchdog
    assert_dead "$pref"
    assert_alive "$big" "(só uma vítima por vez)"
    assert_contains "$(log_content)" "MEM_SYS_HIGH"
}

test_test_tooling_killed_before_preferred_agent() {
    EXTRA_CONF='MEM_PREFER_FIRST_REGEX="node_modules/[.]bin/(vite|vitest)|vendor/bin/(phpunit|pest)"' write_conf
    set_meminfo 8000000 400000 2000000 100000
    local agent vite
    agent=$(spawn_victim --session); vite=$(spawn_victim /app/node_modules/.bin/vite)
    link_proc "$agent" "$vite"
    ps_mem "$agent" $((900 * MB)) prefer-me
    ps_mem "$vite" $((300 * MB)) node
    run_watchdog; run_watchdog
    assert_dead "$vite"
    assert_alive "$agent" "(agente só depois das ferramentas de teste)"
}

test_preferred_agent_still_killed_when_no_test_tooling_left() {
    EXTRA_CONF='MEM_PREFER_FIRST_REGEX="vendor/bin/phpunit"' write_conf
    set_meminfo 8000000 400000 2000000 100000
    local agent other
    agent=$(spawn_victim --session); other=$(spawn_victim --server)
    link_proc "$agent" "$other"
    ps_mem "$agent" $((300 * MB)) prefer-me
    ps_mem "$other" $((900 * MB)) bigapp
    run_watchdog; run_watchdog
    assert_dead "$agent"
    assert_alive "$other"
}

test_system_pressure_without_preferred_kills_largest() {
    set_meminfo 8000000 400000 2000000 100000
    local small big
    small=$(spawn_victim); big=$(spawn_victim); link_proc "$small" "$big"
    ps_mem "$small" $((300 * MB)) smallapp
    ps_mem "$big" $((900 * MB)) bigapp
    run_watchdog; run_watchdog
    assert_dead "$big"
    assert_alive "$small"
}

test_low_ram_with_free_swap_does_not_kill() {
    set_meminfo 8000000 400000 2000000 1800000
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" $((900 * MB)) bigapp
    run_watchdog; run_watchdog; run_watchdog
    assert_alive "$p"
}

test_low_ram_warns_once_within_cooldown() {
    set_meminfo 8000000 1200000 2000000 1800000
    run_watchdog; run_watchdog
    assert_eq 1 "$(grep -c MEM_WARN "$T/watchdog.log")"
}

test_healthy_host_without_swap_does_not_warn() {
    set_meminfo 8000000 6000000 0 0
    run_watchdog
    assert_not_contains "$(log_content)" "MEM_WARN"
}

test_host_without_swap_still_warns_on_low_ram() {
    set_meminfo 8000000 1200000 0 0
    run_watchdog
    assert_contains "$(log_content)" "MEM_WARN"
}

test_host_without_swap_still_kills_on_low_ram() {
    set_meminfo 8000000 400000 0 0
    local p; p=$(spawn_victim); link_proc "$p"
    ps_mem "$p" $((900 * MB)) bigapp
    run_watchdog; run_watchdog
    assert_dead "$p"
}

test_earlyoom_kills_are_reported() {
    touch "$T/earlyoom_active"
    echo 'sending SIGTERM to process 4242 uid 1000 "node": oom_score 900, VmRSS 1200 MiB' >"$T/journal_earlyoom"
    run_watchdog
    assert_contains "$(log_content)" "EARLYOOM sending SIGTERM to process 4242"
}

run_test test_large_process_termed_after_sustain
run_test test_process_ignoring_term_gets_kill_next_run
run_test test_process_below_mem_limit_untouched
run_test test_mem_whitelist_protects_process
run_test test_cpu_whitelist_does_not_protect_from_memory_layer
run_test test_system_pressure_kills_one_preferred_process
run_test test_test_tooling_killed_before_preferred_agent
run_test test_preferred_agent_still_killed_when_no_test_tooling_left
run_test test_system_pressure_without_preferred_kills_largest
run_test test_low_ram_with_free_swap_does_not_kill
run_test test_low_ram_warns_once_within_cooldown
run_test test_healthy_host_without_swap_does_not_warn
run_test test_host_without_swap_still_warns_on_low_ram
run_test test_host_without_swap_still_kills_on_low_ram
run_test test_earlyoom_kills_are_reported
finish
