#!/usr/bin/env bash
# Panel tests (Python standard library only); skipped when python3 is missing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found, skipping panel tests"
    exit 0
fi
PYTHONDONTWRITEBYTECODE=1 CPU_WATCHDOG_PANEL_ALLOW_USER=1 python3 -m unittest -q test_panel.py
