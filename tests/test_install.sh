#!/usr/bin/env bash
# Run the real installer against a temporary filesystem and fake package/service managers.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

prepare_installer() {
    mkdir -p "$T/repo" "$T/root/etc/default"
    cp -r "$REPO_DIR/bin" "$REPO_DIR/config" "$REPO_DIR/systemd" "$T/repo/"
    # Redirect absolute destinations only; keep the installer's behavior intact.
    sed -e "s|/usr/local/|$T/root/usr/local/|g" \
        -e "s|/etc/|$T/root/etc/|g" \
        -e "s|/var/lib/|$T/root/var/lib/|g" \
        "$REPO_DIR/install.sh" >"$T/repo/install.sh"
    cat >"$T/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
id() { echo "${INSTALL_UID:-0}"; }
command() {
    if [ "${1:-}" = -v ]; then
        case "$2" in
            apt-get|pacman) [[ " $INSTALL_MANAGERS " == *" $2 "* ]]; return ;;
            cpulimit|earlyoom) [ -f "$T/installed-$2" ]; return ;;
        esac
    fi
    builtin command "$@"
}
apt-get() {
    command -v apt-get >/dev/null || return 127
    echo "apt-get $*" >>"$T/packages"
    [ "${INSTALL_PACKAGE_FAIL:-0}" -eq 0 ] || return 1
    if [ "$1" = install ]; then touch "$T/installed-${@: -1}"; fi
}
pacman() {
    command -v pacman >/dev/null || return 127
    echo "pacman $*" >>"$T/packages"
    [ "${INSTALL_PACKAGE_FAIL:-0}" -eq 0 ] || return 1
    touch "$T/installed-${@: -1}"
}
systemctl() {
    echo "systemctl $*" >>"$T/services"
    case "$1" in
        cat) return 1 ;;
        is-active) echo active ;;
        status) echo 'cpu-watchdog.timer active' ;;
    esac
}
source "$T/repo/install.sh"
DRIVER
}

run_installer() {
    env T="$T" INSTALL_MANAGERS="${1:-}" INSTALL_UID="${2:-0}" \
        INSTALL_PACKAGE_FAIL="${3:-0}" \
        bash "$T/driver.sh" >"$T/stdout" 2>"$T/stderr"
}

assert_installed() {
    [ -x "$T/root/usr/local/bin/cpu-watchdog.sh" ] || fail "watchdog not installed"
    [ -x "$T/root/usr/local/bin/cpu-watchdog-ctl" ] || fail "management tool not installed"
    [ -f "$T/root/etc/cpu-watchdog.conf" ] || fail "config not installed"
    [ -f "$T/root/var/lib/cpu-watchdog/counts.tsv" ] || fail "state not created"
    assert_contains "$(cat "$T/services")" "systemctl enable --now cpu-watchdog.timer"
    assert_contains "$(cat "$T/services")" "systemctl enable --now earlyoom"
}

test_arch_installs_without_cpulimit() {
    prepare_installer
    run_installer pacman || { fail "Arch install failed: $(cat "$T/stderr")"; return; }
    assert_installed
    assert_eq "pacman -S --needed --noconfirm earlyoom" "$(cat "$T/packages")"
    assert_contains "$(cat "$T/stdout" "$T/stderr")" "yay -S cpulimit"
    [ ! -f "$T/installed-cpulimit" ] || fail "must not install AUR packages as root"
}

test_debian_installs_missing_dependencies() {
    prepare_installer
    run_installer apt-get || { fail "Debian install failed: $(cat "$T/stderr")"; return; }
    assert_installed
    assert_contains "$(cat "$T/packages")" "apt-get install -y cpulimit"
    assert_contains "$(cat "$T/packages")" "apt-get install -y earlyoom"
}

test_existing_dependencies_need_no_package_manager() {
    prepare_installer
    touch "$T/installed-cpulimit" "$T/installed-earlyoom"
    run_installer || { fail "preinstalled dependencies rejected: $(cat "$T/stderr")"; return; }
    assert_installed
    [ ! -f "$T/packages" ] || fail "already installed packages should be skipped"
}

test_missing_dependencies_without_package_manager_fail_before_writes() {
    prepare_installer
    run_installer && fail "missing dependencies should fail clearly"
    assert_contains "$(cat "$T/stderr")" "apt-get or pacman"
    [ ! -e "$T/root/usr" ] || fail "must fail before installing files"
    [ ! -f "$T/services" ] || fail "must fail before changing services"
}

test_arch_rerun_keeps_custom_config_and_unchanged_timer() {
    prepare_installer
    run_installer pacman || { fail "first install failed"; return; }
    echo 'CPU_THRESHOLD=91' >>"$T/root/etc/cpu-watchdog.conf"
    : >"$T/packages"
    : >"$T/services"
    run_installer pacman || { fail "rerun failed: $(cat "$T/stderr")"; return; }
    assert_contains "$(cat "$T/root/etc/cpu-watchdog.conf")" 'CPU_THRESHOLD=91'
    assert_eq "" "$(cat "$T/packages")"
    assert_not_contains "$(cat "$T/services")" "systemctl daemon-reload"
    assert_not_contains "$(cat "$T/services")" "systemctl restart"
}

test_package_failure_stops_before_writes() {
    prepare_installer
    run_installer pacman 0 1 && fail "package failure should abort"
    [ ! -e "$T/root/usr" ] || fail "must not install files after package failure"
    [ ! -f "$T/services" ] || fail "must not change services after package failure"
}

test_installer_rejects_non_root() {
    prepare_installer
    run_installer pacman 1000 && fail "non-root installation should fail"
    [ ! -f "$T/packages" ] || fail "non-root must not install packages"
    [ ! -e "$T/root/usr" ] || fail "non-root must not install files"
}

run_test test_arch_installs_without_cpulimit
run_test test_debian_installs_missing_dependencies
run_test test_existing_dependencies_need_no_package_manager
run_test test_missing_dependencies_without_package_manager_fail_before_writes
run_test test_arch_rerun_keeps_custom_config_and_unchanged_timer
run_test test_package_failure_stops_before_writes
run_test test_installer_rejects_non_root
finish
