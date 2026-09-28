#!/usr/bin/env bash
# Validação estática: bash -n, shellcheck e systemd-analyze verify das units.
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
    echo "shellcheck não encontrado no PATH" >&2
    rc=1
fi

echo "== systemd-analyze verify"
if command -v systemd-analyze >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # O ExecStart aponta para o script do repo: não depende de instalação.
    sed "s|^ExecStart=/usr/local/bin/cpu-watchdog.sh$|ExecStart=$PWD/bin/cpu-watchdog.sh|" \
        systemd/cpu-watchdog.service >"$tmp/cpu-watchdog.service"
    cp systemd/cpu-watchdog.timer "$tmp/"
    systemd-analyze verify "$tmp/cpu-watchdog.service" "$tmp/cpu-watchdog.timer" || rc=1
else
    echo "systemd-analyze ausente, pulando"
fi

exit "$rc"
