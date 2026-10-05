#!/usr/bin/env bash
# Notificação via Telegram: o bot token não pode aparecer no argv do curl
# (visível em `ps`/`/proc/<pid>/cmdline` para qualquer usuário da máquina).
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_BOT_TOKEN="123456789:FAKEtokenFAKEtokenFAKEtokenFAKE0"
TEST_CHAT_ID="-1001234567890"

trigger_throttle() {
    EXTRA_CONF='SUSTAIN_CHECKS=1' write_conf
    local p; p=$(spawn_victim --token=ARGVxSECRET); link_proc "$p"
    ps_cpu "$p" 99 app
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
}

test_credentials_not_in_curl_argv() {
    trigger_throttle
    [ -s "$T/calls/curl.argv" ] || fail "curl não foi chamado"
    assert_not_contains "$(calls curl.argv)" "FAKEtokenFAKE" "(token no argv do curl)"
    assert_not_contains "$(calls curl.argv)" "$TEST_CHAT_ID" "(chat_id no argv do curl)"
}

test_request_still_targets_bot_endpoint_with_chat_and_text() {
    trigger_throttle
    local all; all="$(calls curl.argv)$(calls curl.stdin)"
    assert_contains "$all" "https://api.telegram.org/bot${TEST_BOT_TOKEN}/sendMessage"
    assert_contains "$all" "chat_id=${TEST_CHAT_ID}"
    assert_contains "$all" "limitado a 50%"
}

test_notification_never_includes_cmdline() {
    trigger_throttle
    local all; all="$(calls curl.argv)$(calls curl.stdin)"
    assert_not_contains "$all" "ARGVxSECRET"
    assert_not_contains "$all" "--token="
}

test_no_credentials_means_no_request() {
    TEST_BOT_TOKEN="" TEST_CHAT_ID="" trigger_throttle
    assert_eq "" "$(calls curl.argv)"
}

test_control_chars_in_credentials_cannot_inject_curl_directives() {
    TEST_CHAT_ID=$'123\noutput = /tmp/pwned' trigger_throttle
    assert_not_contains "$(calls curl.stdin)" "output ="
    assert_contains "$(log_content)" "TELEGRAM"
}

run_test test_control_chars_in_credentials_cannot_inject_curl_directives
run_test test_credentials_not_in_curl_argv
run_test test_request_still_targets_bot_endpoint_with_chat_and_text
run_test test_notification_never_includes_cmdline
run_test test_no_credentials_means_no_request
finish
