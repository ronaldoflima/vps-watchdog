#!/usr/bin/env bash
# Roda todos os tests/test_*.sh sem root; veja as dependências no README.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
rc=0
for t in test_*.sh; do
    echo "== $t"
    bash "$t" || rc=1
done
exit "$rc"
