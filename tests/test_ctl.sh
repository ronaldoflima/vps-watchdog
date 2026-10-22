#!/usr/bin/env bash
# cpu-watchdog-ctl free: lift every limit from a tmux session's processes.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

run_ctl() {
    local s
    mkdir -p "$T/bin"
    for s in tmux systemctl busctl; do ln -sf "$STUBS_DIR/$s" "$T/bin/$s"; done
    ln -sf "$STUBS_DIR/root/id" "$T/bin/id"
    env -u SUDO_USER -u TMUX_USER \
        PATH="$T/bin:$PATH" \
        STUB_DIR="$T" \
        CPU_WATCHDOG_CONF="$T/conf" \
        CPU_WATCHDOG_PROC_DIR="${CTL_PROC_DIR:-/proc}" \
        CPU_WATCHDOG_CGROUP_DIR="$T/cgroup" \
        bash "$REPO_DIR/bin/cpu-watchdog-ctl.sh" "$@" >"$T/stdout" 2>"$T/stderr"
}

start_of() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat"; }

test_free_resumes_stopped_process_and_records_it() {
    local v; v=$(spawn_victim pane)
    echo "$v" >"$T/tmux_panes"
    kill -STOP "$v"
    run_ctl free work || fail "exit != 0: $(cat "$T/stderr")"
    assert_contains "$(cat "$T/stdout")" "resumed"
    assert_not_contains "$(awk '{ sub(/^.*\) /, ""); print $1 }' "/proc/$v/stat")" "T"
    assert_contains "$(cat "$T/state/freed.tsv")" "$v:$(start_of "$v")"
    assert_contains "$(calls tmux)" "list-panes -s -t work"
}

test_free_includes_descendants() {
    local v child
    bash -c 'sleep 300 & wait' >/dev/null 2>&1 &
    v=$!
    echo "$v" >>"$T/victims"
    for _ in $(seq 1 50); do
        child=$(ps -o pid= --ppid "$v" | head -1 | tr -d ' ')
        [ -n "$child" ] && break
        sleep 0.02
    done
    [ -n "$child" ] || { fail "victim has no child"; return; }
    echo "$child" >>"$T/victims"
    echo "$v" >"$T/tmux_panes"
    run_ctl free work
    assert_contains "$(cat "$T/state/freed.tsv")" "$child:"
}

test_free_removes_cpulimit_throttle() {
    local v key; v=$(spawn_victim pane)
    echo "$v" >"$T/tmux_panes"
    key="$v:$(start_of "$v")"
    printf '%s\t%s\t20\t2026-01-01 00:00:00\tAGG_THROTTLE\n' "$key" "$v" >"$T/state/limited.tsv"
    run_ctl free work
    assert_contains "$(calls systemctl)" "stop cpu-watchdog-limit-${key/:/-}.scope"
    assert_contains "$(cat "$T/stdout")" "cpulimit-removed"
}

test_free_moves_agent_out_of_slice() {
    local v start; v=$(spawn_victim pane)
    echo "$v" >"$T/tmux_panes"
    start=$(start_of "$v")
    mkdir -p "$T/fproc/$v"
    cp "/proc/$v/stat" "$T/fproc/$v/stat"
    echo "0::/x.slice/cpu-watchdog-agents.slice/cpu-watchdog-agent-$v-$start.scope" >"$T/fproc/$v/cgroup"
    CTL_PROC_DIR="$T/fproc" run_ctl free work
    assert_contains "$(calls busctl)" "cpu-watchdog-free-$v-$start.scope fail 2 PIDs au 1 $v Slice s cpu-watchdog-free.slice 0"
    assert_contains "$(cat "$T/stdout")" "moved-out-of-agent-slice"
}

test_free_undo_removes_exemption() {
    local v; v=$(spawn_victim pane)
    echo "$v" >"$T/tmux_panes"
    printf '%s\n' "1:1" >"$T/state/freed.tsv"
    run_ctl free work
    run_ctl free work --undo || fail "exit != 0: $(cat "$T/stderr")"
    assert_not_contains "$(cat "$T/state/freed.tsv")" "$v:"
    assert_contains "$(cat "$T/state/freed.tsv")" "1:1" "(other entries kept)"
}

test_free_unknown_session_fails() {
    run_ctl free nope && fail "should fail without the session"
    assert_contains "$(cat "$T/stderr")" "tmux target 'nope' not found"
}

test_free_window_lists_only_that_window() {
    local v; v=$(spawn_victim pane)
    echo "$v" >"$T/tmux_panes"
    run_ctl free work:2 || fail "exit != 0: $(cat "$T/stderr")"
    assert_eq "list-panes -t work:2 -F #{pane_pid}" "$(calls tmux)"
    assert_contains "$(cat "$T/state/freed.tsv")" "$v:"
}

test_free_pane_resolves_single_pane() {
    local v; v=$(spawn_victim pane)
    echo "$v" >"$T/tmux_panes"
    run_ctl free work:2.1 || fail "exit != 0: $(cat "$T/stderr")"
    assert_eq "display-message -p -t work:2.1 #{pane_pid}" "$(calls tmux)"
    assert_contains "$(cat "$T/state/freed.tsv")" "$v:"
}

test_watchdog_skips_freed_agent() {
    EXTRA_CONF='CPU_THRESHOLD=1000000
AGENT_COMM="agent"
AGENT_CPU_QUOTA_PCT=350' write_conf
    local a; a=$(spawn_victim agent)
    fake_proc "$a" agent 0
    printf '%s:1000\n' "$a" >"$T/state/freed.tsv"
    advance_cpu 0 0; run_watchdog
    assert_eq "" "$(calls busctl)"
}

test_watchdog_never_cpulimits_freed_process() {
    EXTRA_CONF='CPU_THRESHOLD=1000000' write_conf
    local h i; h=$(spawn_victim hog)
    fake_proc "$h" hog 0
    printf '%s:1000\n' "$h" >"$T/state/freed.tsv"
    advance_cpu 0 0; run_watchdog
    for i in 1 2; do
        advance_cpu 19200 4800; fake_proc "$h" hog $((i * 6000)); run_watchdog
    done
    assert_eq "" "$(calls cpulimit)"
}

test_watchdog_prunes_freed_entries_of_dead_processes() {
    local a; a=$(spawn_victim agent)
    fake_proc "$a" agent 0
    printf '%s:1000\n999999:1\n' "$a" >"$T/state/freed.tsv"
    advance_cpu 0 0; run_watchdog
    assert_eq "$a:1000" "$(cat "$T/state/freed.tsv")"
}

run_test test_free_resumes_stopped_process_and_records_it
run_test test_free_includes_descendants
run_test test_free_removes_cpulimit_throttle
run_test test_free_moves_agent_out_of_slice
run_test test_free_undo_removes_exemption
run_test test_free_unknown_session_fails
run_test test_free_window_lists_only_that_window
run_test test_free_pane_resolves_single_pane
run_test test_watchdog_skips_freed_agent
run_test test_watchdog_never_cpulimits_freed_process
run_test test_watchdog_prunes_freed_entries_of_dead_processes
finish
