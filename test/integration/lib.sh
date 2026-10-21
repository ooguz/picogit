# Shared helpers for the integration tests (sourced by run.sh / https.sh).
#
# PICOGIT may contain an emulator prefix, e.g. "qemu-arm build/armv7/picogit",
# so it is intentionally expanded without quotes.

set -u

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PICOGIT=${PICOGIT:-$TOP/build/host/picogit}
PICOGIT_DEV=${PICOGIT_DEV:-$TOP/build/host/picogit-dev}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/picogit-test.XXXXXX")
SRV=$WORK/srv
SERVER_PID=
PORT=
PASS=0
FAIL=0
FAILED_TESTS=()

# Isolate real git from the user's configuration.
export HOME=$WORK/home
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test Author" GIT_AUTHOR_EMAIL="author@example.com"
export GIT_COMMITTER_NAME="Test Author" GIT_COMMITTER_EMAIL="author@example.com"
export PICOGIT_AUTHOR_NAME="Pico Tester" PICOGIT_AUTHOR_EMAIL="pico@example.com"
unset PICOGIT_TOKEN PICOGIT_USERNAME
mkdir -p "$HOME" "$SRV"
cat > "$HOME/.gitconfig" <<'EOF'
[init]
	defaultBranch = main
[advice]
	detachedHead = false
[protocol]
	version = 2
EOF

cleanup() {
    stop_server
    if [ "${KEEP_WORK:-0}" = 1 ]; then
        echo "work directory kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

pg() { $PICOGIT "$@"; }
pgdev() { $PICOGIT_DEV "$@"; }

# extra_server [server options...] -> starts an additional server for the
# current test (killed when the test's subshell exits); sets XBASE.
extra_server() {
    local pf=$WORK/xport.$BASHPID.$RANDOM
    python3 -I "$TOP/test/server/git_http_server.py" --root "$SRV" \
        --port-file "$pf" "$@" >>"$WORK/xserver.log" 2>&1 &
    local pid=$!
    XPIDS="${XPIDS:-} $pid"
    trap 'kill $XPIDS 2>/dev/null' EXIT
    for _ in $(seq 100); do
        [ -s "$pf" ] && break
        sleep 0.05
    done
    case " $* " in
        *" --tls "*) XBASE="https://localhost:$(cat "$pf")" ;;
        *) XBASE="http://127.0.0.1:$(cat "$pf")" ;;
    esac
}

# make_certs DIR: a test CA plus server certificates for "localhost":
# DIR/ca.pem, DIR/server.{pem,key} (valid), DIR/expired.{pem,key}
make_certs() {
    local d=$1
    [ -f "$d/server.pem" ] && return 0
    mkdir -p "$d"
    (
        cd "$d"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout ca.key -out ca.pem -days 30 -subj "/CN=picogit test CA" 2>/dev/null
        for n in server expired; do
            openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
                -keyout $n.key -out $n.csr -subj "/CN=localhost" 2>/dev/null
        done
        printf 'subjectAltName=DNS:localhost\n' > ext.cnf
        openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
            -days 30 -extfile ext.cnf -out server.pem 2>/dev/null
        openssl x509 -req -in expired.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
            -not_before 20200101000000Z -not_after 20210101000000Z \
            -extfile ext.cnf -out expired.pem 2>/dev/null
    )
}

# start_server [server options...] -> sets PORT and BASE
start_server() {
    stop_server
    rm -f "$WORK/port"
    python3 -I "$TOP/test/server/git_http_server.py" --root "$SRV" \
        --port-file "$WORK/port" "$@" >"$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 100); do
        [ -s "$WORK/port" ] && break
        sleep 0.05
    done
    PORT=$(cat "$WORK/port")
    case " $* " in
        *" --tls "*) BASE="https://127.0.0.1:$PORT" ;;
        *) BASE="http://127.0.0.1:$PORT" ;;
    esac
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=
    fi
}

# new_bare NAME -> creates $SRV/NAME.git with branch main
new_bare() {
    rm -rf "$SRV/$1.git"
    git init -q --bare -b main "$SRV/$1.git"
}

# seed NAME DIR: clone the bare repo with real git into DIR
seed() {
    git clone -q "$SRV/$1.git" "$2" 2>/dev/null
}

# commit_all DIR MESSAGE: commit everything in DIR with real git
commit_all() {
    git -C "$1" add -A && git -C "$1" commit -q -m "$2"
}

# check_repo DIR: the repository must pass fsck and have a clean status
check_repo() {
    local out
    if ! out=$(git -C "$1" fsck --strict --no-progress 2>&1); then
        echo "git fsck failed in $1:"; echo "$out"; return 1
    fi
    if echo "$out" | grep -qv '^dangling'; then
        if [ -n "$out" ]; then echo "git fsck: $out"; fi
    fi
    out=$(git -C "$1" status --porcelain --ignored=no 2>&1)
    if [ -n "$out" ]; then
        echo "git status not clean in $1:"; echo "$out"; return 1
    fi
}

fail() { echo "FAIL: $*"; return 1; }

assert_eq() {
    if [ "$1" != "$2" ]; then
        echo "assertion failed: '$1' != '$2' ${3:-}"; return 1
    fi
}

assert_file() { # assert_file PATH CONTENT
    [ -f "$1" ] || { echo "missing file $1"; return 1; }
    assert_eq "$(cat "$1")" "$2" "($1)"
}

run_test() {
    local name=$1 log=$WORK/$1.log rc
    # Not inside `if`: errexit is ignored in a condition context.
    ( set -e; cd "$WORK"; "$name" ) >"$log" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
        PASS=$((PASS + 1))
        printf "  ok    %s\n" "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf "  FAIL  %s\n" "$name"
        sed 's/^/        | /' "$log"
    fi
}

run_all() {
    local t
    for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
        if [ -z "${ONLY:-}" ] || [[ $t == *$ONLY* ]]; then
            run_test "$t"
        fi
    done
    echo "integration: $PASS passed, $FAIL failed"
    [ "$FAIL" = 0 ]
}
