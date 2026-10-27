#!/usr/bin/env bash
# Layer 2b: agent processes capped through a cgroup quota, never cpulimit.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENT_CONF='CPU_THRESHOLD=1000000
AGENT_COMM="agent"
AGENT_CPU_QUOTA_PCT=350
RELEASE_SUSTAIN_CHECKS=2'

agg_busy() { advance_cpu 19200 4800; }

slice_usage() {
    mkdir -p "$T/cgroup/agents.slice"
    echo "/agents.slice" >"$T/agent_cgroup"
    printf 'usage_usec %s\nnr_periods 0\n' "$1" >"$T/cgroup/agents.slice/cpu.stat"
}

# Two busy intervals with a single agent consuming most of the CPU.
busy_agent() {
    local a="$1" i
    fake_proc "$a" agent 0
    advance_cpu 0 0; run_watchdog
    for i in 1 2; do
        agg_busy; fake_proc "$a" agent $((i * 6000)); run_watchdog
    done
}

test_agent_adopted_into_slice() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    fake_proc "$a" agent 0
    advance_cpu 0 0; run_watchdog
    assert_contains "$(calls busctl)" "StartTransientUnit ssa(sv)a(sa(sv)) cpu-watchdog-agent-${a}-1000.scope fail 2 PIDs au 1 $a Slice s cpu-watchdog-agents.slice 0"
    assert_contains "$(log_content)" "AGENT_ADOPT pid=$a comm=agent"
}

test_agent_already_in_slice_not_readopted() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    fake_proc "$a" agent 0
    echo "0::/cpu.slice/cpu-watchdog.slice/cpu-watchdog-agents.slice/x.scope" >"$T/proc/$a/cgroup"
    advance_cpu 0 0; run_watchdog
    assert_eq "" "$(calls busctl)"
}

test_non_agent_not_adopted() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim other)
    fake_proc "$a" other 0
    advance_cpu 0 0; run_watchdog
    assert_eq "" "$(calls busctl)"
}

test_aggregate_high_caps_slice_instead_of_cpulimit() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    busy_agent "$a"
    assert_eq "" "$(calls cpulimit)" "(agents are never cpulimited)"
    assert_contains "$(calls systemctl)" "set-property --runtime cpu-watchdog-agents.slice CPUQuota=350%"
    assert_contains "$(log_content)" "AGENT_QUOTA cpu-watchdog-agents.slice capped at 350%"
}

test_cap_applied_once() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    busy_agent "$a"
    agg_busy; fake_proc "$a" agent 18000; run_watchdog
    assert_eq 1 "$(calls systemctl | grep -c 'CPUQuota=350%')"
}

test_cap_removed_when_slice_usage_drops() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    slice_usage 1000
    busy_agent "$a"
    run_watchdog
    assert_eq "" "$(calls systemctl | grep -x 'set-property --runtime cpu-watchdog-agents.slice CPUQuota=' || true)" "(one idle measurement out of two)"
    run_watchdog
    assert_contains "$(calls systemctl)" "set-property --runtime cpu-watchdog-agents.slice CPUQuota="
    assert_contains "$(log_content)" "AGENT_QUOTA cap removed"
    [ ! -e "$T/state/agent_quota" ] || fail "quota state should be cleared"
}

test_cap_kept_while_slice_is_busy() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a i; a=$(spawn_victim agent)
    slice_usage 0
    busy_agent "$a"
    for i in 1 2 3; do
        slice_usage $((i * 1000000000)); run_watchdog
    done
    assert_not_contains "$(log_content)" "cap removed"
}

test_disabling_quota_removes_cap() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    busy_agent "$a"
    EXTRA_CONF="$AGENT_CONF
AGENT_CPU_QUOTA_PCT=0" write_conf
    run_watchdog
    assert_contains "$(log_content)" "AGENT_QUOTA disabled -> cap removed"
    [ ! -e "$T/state/agent_quota" ] || fail "quota state should be cleared"
}

test_observe_mode_only_logs() {
    EXTRA_CONF="$AGENT_CONF
MODE=observe" write_conf
    local a; a=$(spawn_victim agent)
    busy_agent "$a"
    assert_eq "" "$(calls busctl)"
    assert_not_contains "$(calls systemctl)" "set-property"
    assert_contains "$(log_content)" "AGENT_QUOTA would cap cpu-watchdog-agents.slice at 350%"
}

test_disabled_by_default() {
    EXTRA_CONF='CPU_THRESHOLD=1000000' write_conf
    local a; a=$(spawn_victim agent)
    busy_agent "$a"
    assert_eq "" "$(calls busctl)"
    assert_not_contains "$(calls systemctl)" "set-property"
    assert_contains "$(calls cpulimit)" "-p $a -l 20"
}

governor() { mkdir -p "$T/state"; printf '%s\t%s\t99\t0\n' "$1" "$2" >"$T/state/credit-governor"; }

test_fresh_governor_owns_quota_and_raises_trigger() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    governor "$(date +%s)" 100000
    busy_agent "$a"
    assert_contains "$(calls busctl)" "cpu-watchdog-agent-${a}-1000.scope" "(agents still adopted)"
    assert_not_contains "$(calls systemctl)" "CPUQuota=" "(governor owns the quota)"
    assert_not_contains "$(log_content)" "AGG_HIGH"
}

test_fresh_governor_threshold_drives_layer2() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    governor "$(date +%s)" 100
    busy_agent "$a"
    assert_contains "$(log_content)" "threshold 100% = credit governor"
    assert_not_contains "$(calls systemctl)" "CPUQuota=350%"
}

test_stale_governor_restores_fixed_policy() {
    EXTRA_CONF="$AGENT_CONF" write_conf
    local a; a=$(spawn_victim agent)
    governor $(( $(date +%s) - 600 )) 100000
    fake_proc "$a" agent 0
    advance_cpu 0 0; run_watchdog
    assert_contains "$(calls systemctl)" "set-property --runtime cpu-watchdog-agents.slice CPUQuota="
    assert_contains "$(log_content)" "CREDIT_GOVERNOR stale"
    [ ! -e "$T/state/credit-governor" ] || fail "stale governor file should be removed"
    for i in 1 2; do agg_busy; fake_proc "$a" agent $((i * 6000)); run_watchdog; done
    assert_contains "$(calls systemctl)" "CPUQuota=350%"
}

run_test test_agent_adopted_into_slice
run_test test_agent_already_in_slice_not_readopted
run_test test_non_agent_not_adopted
run_test test_aggregate_high_caps_slice_instead_of_cpulimit
run_test test_cap_applied_once
run_test test_cap_removed_when_slice_usage_drops
run_test test_cap_kept_while_slice_is_busy
run_test test_disabling_quota_removes_cap
run_test test_observe_mode_only_logs
run_test test_disabled_by_default
run_test test_fresh_governor_owns_quota_and_raises_trigger
run_test test_fresh_governor_threshold_drives_layer2
run_test test_stale_governor_restores_fixed_policy
finish
