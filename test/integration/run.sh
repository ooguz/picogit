#!/usr/bin/env bash
# Integration tests: picogit against `git http-backend`, verified with real git.
#   PICOGIT=path/to/picogit bash test/integration/run.sh
#   ONLY=clone bash test/integration/run.sh   (run a subset)
#   KEEP_WORK=1 ...                           (keep the scratch directory)
. "$(dirname "$0")/lib.sh"

echo "integration tests with: $PICOGIT"
start_server

for f in "$(dirname "$0")"/t_*.sh; do . "$f"; done

test_version() {
    pg --version | grep -q '^picogit '
}

test_server_with_real_git() {
    new_bare srvcheck
    seed srvcheck w
    echo hello > w/a
    commit_all w init
    git -C w push -q "$BASE/srvcheck.git" main
    git clone -q "$BASE/redirect/srvcheck.git" c
    assert_file c/a hello
}

run_all
