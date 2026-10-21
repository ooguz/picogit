#!/usr/bin/env bash
# Network test: clone public repositories over HTTPS using the embedded CA
# bundle, then verify them with real git.
#   PICOGIT=... bash test/integration/https.sh
. "$(dirname "$0")/lib.sh"

echo "https tests with: $PICOGIT"

test_https_github_shallow_clone() {
    pg clone https://github.com/octocat/Hello-World.git hw
    check_repo hw
    assert_eq "$(git -C hw rev-list --count HEAD)" 1
    (cd hw && pg pull) 2>out.txt
    grep -q "Already up to date" out.txt
    # the same commit as the server reports
    assert_eq "$(git -C hw rev-parse HEAD)" \
        "$(git ls-remote https://github.com/octocat/Hello-World.git refs/heads/master | cut -f1)"
}

test_https_github_full_clone_with_deltas() {
    # a small repository with real history (deltas, many objects)
    PICOGIT_TRACE=1 pg clone --depth 0 https://github.com/octocat/Spoon-Knife.git sk 2>trace.txt
    grep "pack:" trace.txt || true
    check_repo sk
    [ "$(git -C sk rev-list --count HEAD)" -gt 1 ] || fail "expected full history"
}

test_https_wrong_ca_is_rejected() {
    make_certs "$WORK/certs"
    if pg --cacert "$WORK/certs/ca.pem" clone https://github.com/octocat/Hello-World.git x 2>err.txt; then
        fail "clone with an unrelated CA succeeded"
    fi
    grep -q "not signed by a trusted CA" err.txt
    [ ! -e x ] || fail "failed clone left a directory"
}

run_all
