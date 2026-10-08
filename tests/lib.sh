#!/usr/bin/env bash
# Shared test helpers. Each test runs the real watchdog as a subprocess
# against harmless child processes, with
# ps/cpulimit/systemd-run/curl/logger/journalctl/systemctl replaced by
# stubs and simulated /proc/meminfo.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG="$REPO_DIR/bin/cpu-watchdog.sh"
STUBS_DIR="$REPO_DIR/tests/stubs"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

fail() {
    local msg="$*"
    [ "${#msg}" -le 400 ] || msg="${msg:0:400}…"
    echo "  FAILED: $CURRENT_TEST: $msg" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    [[ "$haystack" == *"$needle"* ]] || fail "expected to contain [$needle] ${msg}; got: [$haystack]"
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    [[ "$haystack" != *"$needle"* ]] || fail "should not contain [$needle] ${msg}; got: [$haystack]"
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    [ "$expected" = "$actual" ] || fail "expected [$expected], got [$actual] ${msg}"
}

assert_alive() {
    kill -0 "$1" 2>/dev/null || fail "process $1 should be alive ${2:-}"
}

assert_dead() {
    local pid="$1"
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.05
    done
    fail "process $pid should have been terminated ${2:-}"
}

# Start a harmless victim process (sleep loop) with the supplied extra
# arguments in its command line. Print its PID.
spawn_victim() {
    bash -c 'while :; do sleep 1; done' victim "$@" >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" >>"$T/victims"
    for _ in $(seq 1 50); do
        [ -s "/proc/$pid/cmdline" ] && break
        sleep 0.02
    done
    echo "$pid"
}

setup_env() {
    T="$(mktemp -d)"
    mkdir -p "$T/state" "$T/proc/pressure" "$T/calls"
    : >"$T/ps_cpu"
    : >"$T/ps_mem"
    : >"$T/victims"
    CPU_USER=0; CPU_IDLE=0; CPU_STEAL=0
    set_meminfo 8000000 4000000 2000000 1800000
    echo "some avg10=0.00 avg60=0.00 avg300=0.00 total=0" >"$T/proc/pressure/memory"
    write_conf
}

# MemTotal MemAvailable SwapTotal SwapFree (kB)
set_meminfo() {
    printf 'MemTotal: %s kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' \
        "$1" "$2" "$3" "$4" >"$T/proc/meminfo"
}

write_conf() {
    cat >"$T/conf" <<CONF
CPU_THRESHOLD=80
SUSTAIN_CHECKS=2
LIMIT_PERCENT=50
WHITELIST_COMM="sshd systemd"
WHITELIST_CMDLINE=""
TELEGRAM_BOT_TOKEN="${TEST_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TEST_CHAT_ID:-}"
STATE_DIR="$T/state"
LOG_FILE="$T/watchdog.log"
AGG_CPU_THRESHOLD_PCT=75
AGG_SUSTAIN_CHECKS=2
AGG_TOP_N=2
AGG_MAX_THROTTLES=2
AGG_LIMIT_PERCENT=20
FORKBOMB_MIN_COUNT=3
FORKBOMB_SUSTAIN_CHECKS=2
MEM_PROC_KILL_MB=4096
MEM_PROC_SUSTAIN_CHECKS=2
MEM_AVAIL_WARN_PCT=20
MEM_SWAP_USED_WARN_PCT=50
MEM_ALERT_COOLDOWN_MIN=30
MEM_AVAIL_KILL_PCT=10
MEM_SWAP_FREE_KILL_PCT=40
MEM_SYS_SUSTAIN_CHECKS=2
MEM_VICTIM_MIN_MB=200
MEM_PREFER_REGEX="^(prefer-me)\$"
MEM_WHITELIST_COMM="sshd systemd"
${EXTRA_CONF:-}
CONF
}

# CPU snapshot row: pid pcpu comm
ps_cpu() { echo "$1 $2 $3" >>"$T/ps_cpu"; }
# Memory snapshot row: pid rss_kB comm
ps_mem() { echo "$1 $2 $3" >>"$T/ps_mem"; }

# Expose a real victim PID within simulated /proc.
link_proc() {
    local pid
    for pid in "$@"; do
        ln -sfn "/proc/$pid" "$T/proc/$pid"
    done
}

# Advance simulated /proc/stat cumulative counters (busy, idle and steal
# ticks), then rewrite the aggregate "cpu" line.
advance_cpu() {
    CPU_USER=$((CPU_USER + $1)); CPU_IDLE=$((CPU_IDLE + $2)); CPU_STEAL=$((CPU_STEAL + ${3:-0}))
    printf 'cpu  %s 0 0 %s 0 0 0 %s 0 0\n' "$CPU_USER" "$CPU_IDLE" "$CPU_STEAL" >"$T/proc/stat"
}

# Simulate a process in fake /proc with controllable cumulative CPU ticks
# (unlike link_proc, which points to real /proc).
# pid comm ticks [flags] [starttime]; flags with 0x200000 = kernel thread.
fake_proc() {
    local pid="$1" comm="$2" ticks="$3" flags="${4:-4194560}" start="${5:-1000}"
    mkdir -p "$T/proc/$pid"
    printf '%s (%s) S 1 1 1 0 -1 %s 0 0 0 0 %s 0 0 0 20 0 1 0 %s 0 0\n' \
        "$pid" "$comm" "$flags" "$ticks" "$start" >"$T/proc/$pid/stat"
    printf '%s\0' "$comm" >"$T/proc/$pid/cmdline"
}

run_watchdog() {
    PATH="$STUBS_DIR:$PATH" \
    STUB_DIR="$T" \
    CPU_WATCHDOG_CONF="$T/conf" \
    CPU_WATCHDOG_LOCK="$T/lock" \
    CPU_WATCHDOG_PROC_DIR="$T/proc" \
        bash "$WATCHDOG" >"$T/stdout" 2>"$T/stderr"
}

log_content() { cat "$T/watchdog.log" 2>/dev/null || true; }
calls() { cat "$T/calls/$1" 2>/dev/null || true; }

teardown_env() {
    # Use a file rather than an array: spawn_victim runs inside $(...), so
    # an array populated in the subshell would be lost, leaking victims.
    local pid
    while read -r pid; do
        kill -KILL "$pid" 2>/dev/null || true
    done <"$T/victims"
    pkill -f "stub-cpulimit-marker $T" 2>/dev/null || true
    rm -rf "$T"
}

run_test() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    local before=$TESTS_FAILED
    setup_env
    "$1" || true
    teardown_env
    if [ "$TESTS_FAILED" -eq "$before" ]; then
        echo "  ok   $1"
    fi
}

finish() {
    echo "$TESTS_RUN tests, $TESTS_FAILED failure(s)"
    [ "$TESTS_FAILED" -eq 0 ]
}

# Victim that ignores SIGTERM and only exits on SIGKILL.
spawn_stubborn_victim() {
    bash -c 'trap "" TERM; while :; do sleep 1; done' victim "$@" >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" >>"$T/victims"
    for _ in $(seq 1 50); do
        [ -s "/proc/$pid/cmdline" ] && break
        sleep 0.02
    done
    sleep 0.1
    echo "$pid"
}
