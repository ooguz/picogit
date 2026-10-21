# SPDX-License-Identifier: GPL-3.0-or-later
# HTTP / HTTPS client tests (M1), through the picogit-dev helper script.

fetch() { pgdev --dev-run "$TOP/test/integration/http_fetch.lua" "$@"; }

expect_body() { # expect_body FILE OUTPUT
    local want
    want="200	$(sha1sum < "$1" | cut -d' ' -f1)	$(stat -c %s "$1")"
    assert_eq "$2" "$want"
}

setup_files() {
    mkdir -p "$SRV/files"
    [ -f "$SRV/files/big.bin" ] || head -c 3000000 /dev/urandom > "$SRV/files/big.bin"
    printf '' > "$SRV/files/empty.bin"
}

test_http_content_length_body() {
    setup_files
    expect_body "$SRV/files/big.bin" "$(fetch "$BASE/__file/big.bin")"
    expect_body "$SRV/files/empty.bin" "$(fetch "$BASE/__file/empty.bin")"
    case "$(fetch "$BASE/__file/missing")" in 404*) ;; *) fail "expected 404" ;; esac
}

test_http_chunked_post_with_file_body() {
    setup_files
    (printf 'prefix:'; cat "$SRV/files/big.bin") > "$WORK/expect"
    expect_body "$WORK/expect" "$(fetch --post "$SRV/files/big.bin" "$BASE/__echo")"
}

test_http_close_delimited_body() {
    setup_files
    extra_server --no-chunked
    (printf 'prefix:'; cat "$SRV/files/big.bin") > "$WORK/expect"
    expect_body "$WORK/expect" "$(fetch --post "$SRV/files/big.bin" "$XBASE/__echo")"
}

test_http_redirects() {
    setup_files
    expect_body "$SRV/files/big.bin" "$(fetch "$BASE/redirect/__file/big.bin")"
    # POST follows 307 but not 301
    (printf 'prefix:'; cat "$SRV/files/empty.bin") > "$WORK/expect"
    expect_body "$WORK/expect" "$(fetch --post "$SRV/files/empty.bin" "$BASE/redirect307/__echo")"
    fetch --post "$SRV/files/empty.bin" "$BASE/redirect/__echo" | grep -q "redirected with status 301"
}

test_http_connection_errors() {
    fetch "http://127.0.0.1:1/x" | grep -q "cannot connect to 127.0.0.1 port 1"
    fetch "http://no-such-host.invalid/x" | grep -q "cannot resolve host"
    fetch "ftp://example.com/x" | grep -q "unsupported protocol"
}

test_http_basic_auth_and_redaction() {
    setup_files
    extra_server --auth "alice:s3cret"
    case "$(fetch "$XBASE/__file/empty.bin")" in 401*) ;; *) fail "expected 401" ;; esac
    expect_body "$SRV/files/empty.bin" "$(fetch --auth alice:s3cret "$XBASE/__file/empty.bin")"
    # credentials in the URL never appear in error messages
    out=$(fetch "http://alice:s3cret@127.0.0.1:1/x") || true
    echo "$out" | grep -q "unable to access 'http://127.0.0.1:1/x'"
    if echo "$out" | grep -q s3cret; then fail "password leaked: $out"; fi
}

test_https_custom_ca() {
    setup_files
    make_certs "$WORK/certs"
    extra_server --tls "$WORK/certs/server.pem" "$WORK/certs/server.key"
    expect_body "$SRV/files/big.bin" "$(fetch --cacert "$WORK/certs/ca.pem" "$XBASE/__file/big.bin")"
    (printf 'prefix:'; cat "$SRV/files/big.bin") > "$WORK/expect"
    expect_body "$WORK/expect" "$(fetch --cacert "$WORK/certs/ca.pem" --post "$SRV/files/big.bin" "$XBASE/__echo")"
    # embedded bundle does not know the test CA
    fetch "$XBASE/__file/empty.bin" | grep -q "not signed by a trusted CA"
    expect_body "$SRV/files/empty.bin" "$(fetch --insecure "$XBASE/__file/empty.bin")"
    # wrong host name
    fetch --cacert "$WORK/certs/ca.pem" "${XBASE/localhost/127.0.0.1}/__file/empty.bin" \
        | grep -q "does not match the host name"
}

test_https_expired_certificate_hint() {
    make_certs "$WORK/certs"
    extra_server --tls "$WORK/certs/expired.pem" "$WORK/certs/expired.key"
    out=$(fetch --cacert "$WORK/certs/ca.pem" "$XBASE/__file/empty.bin") || true
    echo "$out" | grep -q "certificate has expired"
    echo "$out" | grep -q "check the system time / NTP"
}

test_http_malformed_responses_fail_cleanly() {
    local mode out
    for mode in negative-length negative-chunk garbage-chunk huge-header endless-100 truncated; do
        out=$(fetch "$BASE/__evil/$mode" 2>&1) || true
        echo "$mode: $out"
        case "$out" in
            "ERROR unable to access"*|"ERROR network error: "*) ;;
            *) fail "$mode: expected a clean error, got: $out" ;;
        esac
    done
}

test_https_no_downgrade_with_uppercase_scheme() {
    make_certs "$WORK/certs"
    extra_server --tls "$WORK/certs/server.pem" "$WORK/certs/server.key"
    out=$(fetch --cacert "$WORK/certs/ca.pem" --auth u:secret "$XBASE/__downgrade/__file/x") || true
    echo "$out"
    echo "$out" | grep -q "refusing to follow a redirect from https to http"
}
