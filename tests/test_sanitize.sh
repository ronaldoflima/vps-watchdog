#!/usr/bin/env bash
# Segredos no argv de processos monitorados não podem chegar ao log local nem
# ao journal (logger). A cmdline continua útil para diagnóstico.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACT_NOW='SUSTAIN_CHECKS=1
AGG_SUSTAIN_CHECKS=99
FORKBOMB_SUSTAIN_CHECKS=99'

# Dispara a Camada 1 contra uma vítima com os argumentos dados e devolve
# log + journal concatenados.
throttle_output() {
    EXTRA_CONF="$ACT_NOW" write_conf
    local p; p=$(spawn_victim "$@"); link_proc "$p"
    ps_cpu "$p" 99 app
    run_watchdog || fail "exit != 0: $(cat "$T/stderr")"
    log_content
    calls logger
}

assert_redacted() {
    local out="$1"; shift
    local s
    for s in "$@"; do
        assert_not_contains "$out" "$s" "(segredo vazou)"
    done
    assert_contains "$out" "<redacted>"
}

test_leak_reproduction_flag_with_equals() {
    local out; out=$(throttle_output --token=TOKxEQ111 --verbose)
    assert_redacted "$out" TOKxEQ111
    assert_contains "$out" "--token=<redacted>"
    assert_contains "$out" "--verbose"
}

test_flag_followed_by_separate_value() {
    local out; out=$(throttle_output --password PWxSEP222 --client-secret CSx223 --db-api-key AKx224 input.txt)
    assert_redacted "$out" PWxSEP222 CSx223 AKx224
    assert_contains "$out" "--password <redacted>"
    assert_contains "$out" "input.txt"
}

test_boolean_sensitive_flag_does_not_eat_next_flag() {
    local out; out=$(throttle_output --no-auth --port 8080)
    assert_contains "$out" "--no-auth --port 8080"
}

test_env_style_assignments() {
    local out; out=$(throttle_output DB_PASSWORD=ENVx333 AWS_SECRET_ACCESS_KEY=ENVx334 PGPASSWORD=ENVx335 MODE=prod)
    assert_redacted "$out" ENVx333 ENVx334 ENVx335
    assert_contains "$out" "MODE=prod"
}

test_url_userinfo_password() {
    local out; out=$(throttle_output --dsn=x postgres://app:URLx444@db.example.com:5432/app)
    assert_redacted "$out" URLx444
    assert_contains "$out" "postgres://app:<redacted>@db.example.com:5432/app"
}

test_sensitive_query_parameters() {
    local out; out=$(throttle_output "https://api.example.com/v1?access_token=QRYx555&page=2&X-Amz-Signature=QRYx556")
    assert_redacted "$out" QRYx555 QRYx556
    assert_contains "$out" "page=2"
    assert_contains "$out" "api.example.com"
}

test_telegram_bot_token_in_url() {
    local out; out=$(throttle_output "https://api.telegram.org/bot123456789:TGxAAAAAAAAAAAAAAAAAAAAAAAAAAAAA666/sendMessage")
    assert_redacted "$out" TGxAAAAAAAAAAAAAAAAAAAAAAAAAAAAA666 123456789:
    assert_contains "$out" "api.telegram.org/bot<redacted>/sendMessage"
}

test_authorization_headers() {
    local out; out=$(throttle_output -H "Authorization: Bearer HDRx777" -H "X-Api-Key: HDRx778" -H "Accept: application/json")
    assert_redacted "$out" HDRx777 HDRx778
    assert_contains "$out" "Accept: application/json"
}

test_basic_auth_user_colon_password() {
    local out; out=$(throttle_output --user admin:BAx888 -u ops:BAx889)
    assert_redacted "$out" BAx888 BAx889
}

test_short_u_flag_without_colon_is_kept() {
    local out; out=$(throttle_output -u script.py)
    assert_contains "$out" "-u script.py"
}

test_well_known_token_shapes() {
    local out; out=$(throttle_output \
        ghp_SHPxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1 \
        github_pat_SHPxBBBBBBBBBBBBBBBBBBBBBB2 \
        sk-ant-SHPxCCCCCCCCCCCCCCCCCC3 \
        xoxb-1234-SHPxDDDDDDDDDD4 \
        AKIASHPXEEEEEEEEEEE5 \
        glpat-SHPxFFFFFFFFFFFFFFFFFFFF6 \
        eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SHPxJWTSIG7)
    assert_redacted "$out" SHPxAAAA SHPxBBBB SHPxCCCC SHPxDDDD SHPXEEEE SHPxFFFF SHPxJWTSIG7
}

test_non_sensitive_cmdline_is_kept_verbatim() {
    local out; out=$(throttle_output --workers 4 --config /etc/app.yaml https://example.com/path?page=3)
    assert_contains "$out" "--workers 4 --config /etc/app.yaml https://example.com/path?page=3"
    assert_not_contains "$out" "<redacted>"
}

test_forkbomb_log_is_sanitized() {
    EXTRA_CONF='SUSTAIN_CHECKS=99
AGG_SUSTAIN_CHECKS=99
FORKBOMB_SUSTAIN_CHECKS=1' write_conf
    local p
    for _ in 1 2 3; do
        p=$(spawn_victim --api-key=FBx999); link_proc "$p"; ps_cpu "$p" 99 spinner
    done
    run_watchdog
    local out; out="$(log_content)$(calls logger)"
    assert_contains "$out" "FORKBOMB 3 processos"
    assert_redacted "$out" FBx999
}

test_memory_kill_log_is_sanitized() {
    EXTRA_CONF='MEM_PROC_SUSTAIN_CHECKS=1' write_conf
    local p; p=$(spawn_victim --secret=MEMx000); link_proc "$p"
    ps_mem "$p" $((5000 * 1024)) leaky
    run_watchdog
    local out; out="$(log_content)$(calls logger)"
    assert_contains "$out" "MEM_PROC"
    assert_redacted "$out" MEMx000
}

test_whitelist_cmdline_still_matches_raw_cmdline() {
    EXTRA_CONF="$ACT_NOW
WHITELIST_CMDLINE='--token=keep-me-exempt'" write_conf
    local p; p=$(spawn_victim --token=keep-me-exempt); link_proc "$p"
    ps_cpu "$p" 99 app
    run_watchdog
    assert_eq "" "$(calls cpulimit)"
}

test_newline_in_argv_cannot_forge_log_lines() {
    EXTRA_CONF="$ACT_NOW" write_conf
    local p; p=$(spawn_victim $'x\n2026-01-01 00:00:00 FORGED entry'); link_proc "$p"
    ps_cpu "$p" 99 app
    run_watchdog
    assert_eq 0 "$(grep -c '^2026-01-01 00:00:00 FORGED' "$T/watchdog.log")"
    assert_eq 1 "$(grep -c 'THROTTLE' "$T/watchdog.log")"
}

test_huge_cmdline_is_truncated() {
    EXTRA_CONF="$ACT_NOW" write_conf
    local big; big=$(head -c 20000 /dev/zero | tr '\0' 'a')
    local p; p=$(spawn_victim "$big"); link_proc "$p"
    ps_cpu "$p" 99 app
    run_watchdog
    local line; line=$(grep THROTTLE "$T/watchdog.log")
    [ "${#line}" -lt 1500 ] || fail "linha de log com ${#line} caracteres"
    assert_contains "$line" "…]"
}

test_secrets_inside_shell_c_string() {
    local out; out=$(throttle_output "mysql --password=SHCx01 -h db && PGPASSWORD=SHCx02 psql; curl -H 'X-Api-Key: SHCx03' --token SHCx04 x")
    assert_redacted "$out" SHCx01 SHCx02 SHCx03 SHCx04
    assert_contains "$out" "-h db"
}

test_whole_argv_rewritten_into_single_arg() {
    local out; out=$(throttle_output "myapp --token STPx05 --workers 4")
    assert_redacted "$out" STPx05
    assert_contains "$out" "--workers 4"
}

test_sensitive_value_with_spaces_fully_redacted() {
    local out; out=$(throttle_output --password "correct horse SPCx06" "--secret=battery staple SPCx07")
    assert_redacted "$out" SPCx06 SPCx07 horse staple
}

test_known_short_password_flags() {
    local out
    out=$(throttle_output "mysql -uroot -pSHFx08 app; sshpass -p SHFx09 ssh h; redis-cli -a SHFx10 ping; docker login -u bob -p SHFx11 reg")
    assert_redacted "$out" SHFx08 SHFx09 SHFx10 SHFx11
    assert_contains "$out" "-uroot"
}

test_short_p_flag_kept_for_other_programs() {
    local out; out=$(throttle_output "docker run -p 8080:80 nginx; ssh -p 2222 host")
    assert_contains "$out" "-p 8080:80"
    assert_contains "$out" "-p 2222"
}

test_invalid_utf8_bytes_do_not_bypass_rules() {
    local out; out=$(LC_ALL=C.UTF-8 throttle_output $'--token=\xffUTFx12' $'--api-key=ab\xffUTFx13' $'https://h/x?token=a\xffUTFx14')
    assert_redacted "$out" UTFx12 UTFx13 UTFx14
}

test_curl_user_password_variants() {
    local out; out=$(throttle_output --user=u:USRx15 -uu:USRx16 --proxy-user p:USRx17 -U q:USRx18 --proxy-user=r:USRx19)
    assert_redacted "$out" USRx15 USRx16 USRx17 USRx18 USRx19
}

test_header_embedded_in_other_argument() {
    local out; out=$(throttle_output "--header=X-Api-Key: HEMx20" "--header=Cookie: sid=HEMx21" -c "http.extraHeader=Authorization: token HEMx22")
    assert_redacted "$out" HEMx20 HEMx21 HEMx22
}

test_url_userinfo_edge_cases() {
    local out; out=$(throttle_output "https://user:p@ssURLx23@h.example/x" "https://URLx24TOKENTOKENTOKEN@github.com/o/r" "https://h.example/cb#access_token=URLx25")
    assert_redacted "$out" URLx23 URLx24 URLx25
    assert_contains "$out" "github.com/o/r"
}

test_url_with_at_in_path_is_kept() {
    local out; out=$(throttle_output "https://registry.npmjs.org/@types/node" "ssh://git@github.com/o/r")
    assert_contains "$out" "https://registry.npmjs.org/@types/node"
    assert_contains "$out" "ssh://git@github.com/o/r"
}

test_json_body_and_dsn_strings() {
    local out; out=$(throttle_output -d '{"user":"a","password":"JSNx26"}' "host=db user=app password=JSNx27 dbname=x" "app:JSNx28@tcp(db:3306)/x")
    assert_redacted "$out" JSNx26 JSNx27 JSNx28
    assert_contains "$out" "dbname=x"
}

test_huge_number_of_args_is_bounded() {
    EXTRA_CONF="$ACT_NOW" write_conf
    local -a many; mapfile -t many < <(yes a | head -n 100000)
    local p; p=$(spawn_victim "${many[@]}"); link_proc "$p"
    ps_cpu "$p" 99 app
    local start=$SECONDS
    run_watchdog
    [ $((SECONDS - start)) -le 3 ] || fail "watchdog levou $((SECONDS - start))s com 100k argumentos"
    assert_contains "$(log_content)" "…]"
}

test_log_and_state_are_private() {
    EXTRA_CONF="$ACT_NOW" write_conf
    rmdir "$T/state"
    local p; p=$(spawn_victim); link_proc "$p"
    ps_cpu "$p" 99 app
    (umask 022; run_watchdog)
    assert_eq 600 "$(stat -c %a "$T/watchdog.log")" "(modo do log)"
    assert_eq 700 "$(stat -c %a "$T/state")" "(modo do STATE_DIR)"
}

run_test test_leak_reproduction_flag_with_equals
run_test test_flag_followed_by_separate_value
run_test test_boolean_sensitive_flag_does_not_eat_next_flag
run_test test_env_style_assignments
run_test test_url_userinfo_password
run_test test_sensitive_query_parameters
run_test test_telegram_bot_token_in_url
run_test test_authorization_headers
run_test test_basic_auth_user_colon_password
run_test test_short_u_flag_without_colon_is_kept
run_test test_well_known_token_shapes
run_test test_non_sensitive_cmdline_is_kept_verbatim
run_test test_forkbomb_log_is_sanitized
run_test test_memory_kill_log_is_sanitized
run_test test_whitelist_cmdline_still_matches_raw_cmdline
run_test test_newline_in_argv_cannot_forge_log_lines
run_test test_huge_cmdline_is_truncated
run_test test_secrets_inside_shell_c_string
run_test test_whole_argv_rewritten_into_single_arg
run_test test_sensitive_value_with_spaces_fully_redacted
run_test test_known_short_password_flags
run_test test_short_p_flag_kept_for_other_programs
run_test test_invalid_utf8_bytes_do_not_bypass_rules
run_test test_curl_user_password_variants
run_test test_header_embedded_in_other_argument
run_test test_url_userinfo_edge_cases
run_test test_url_with_at_in_path_is_kept
run_test test_json_body_and_dsn_strings
run_test test_huge_number_of_args_is_bounded
run_test test_log_and_state_are_private
finish
