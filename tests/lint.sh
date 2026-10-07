#!/usr/bin/env bash
# Static validation: bash -n, shellcheck and systemd-analyze verify for units.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

mapfile -t stubs < <(find tests/stubs -type f | sort)
scripts=(bin/cpu-watchdog.sh bin/cpu-watchdog-ctl.sh install.sh tests/*.sh "${stubs[@]}")
rc=0

echo "== bash -n"
for f in "${scripts[@]}" config/cpu-watchdog.conf.example config/earlyoom.default; do
    bash -n "$f" || rc=1
done

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${scripts[@]}" || rc=1
else
    echo "shellcheck not found in PATH" >&2
    rc=1
fi

echo "== systemd-analyze verify"
if command -v systemd-analyze >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # ExecStart points to the repository script, so no installation is required.
    sed "s|^ExecStart=/usr/local/bin/cpu-watchdog.sh$|ExecStart=$PWD/bin/cpu-watchdog.sh|" \
        systemd/cpu-watchdog.service >"$tmp/cpu-watchdog.service"
    cp systemd/cpu-watchdog.timer "$tmp/"
    systemd-analyze verify "$tmp/cpu-watchdog.service" "$tmp/cpu-watchdog.timer" || rc=1
else
    echo "systemd-analyze missing, skipping"
fi

exit "$rc"
