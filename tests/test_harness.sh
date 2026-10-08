#!/usr/bin/env bash
# Test harness: no victim process may survive teardown.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWNED="$(mktemp)"

spawn_in_command_substitution() {
    local p
    p=$(spawn_victim --leak-check); echo "$p" >>"$SPAWNED"
    p=$(spawn_stubborn_victim --leak-check); echo "$p" >>"$SPAWNED"
}

run_test spawn_in_command_substitution

CURRENT_TEST=test_teardown_reaps_all_victims
TESTS_RUN=$((TESTS_RUN + 1))
while read -r pid; do
    assert_dead "$pid" "(victim survived teardown)"
    kill -KILL "$pid" 2>/dev/null || true
done <"$SPAWNED"
rm -f "$SPAWNED"
finish
