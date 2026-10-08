#!/usr/bin/env bash
# Run all tests/test_*.sh as an unprivileged user; see README for dependencies.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
rc=0
for t in test_*.sh; do
    echo "== $t"
    bash "$t" || rc=1
done
exit "$rc"
