# SPDX-License-Identifier: GPL-3.0-or-later
# Hostile servers and repositories: nothing may be written outside the
# work tree or into .git, and malformed input must fail cleanly.

# push_tree NAME TREE: make a commit for TREE on main in bare repo NAME
push_tree() {
    local c
    c=$(git --git-dir="$SRV/$1.git" commit-tree "$2" -m hostile)
    git --git-dir="$SRV/$1.git" update-ref refs/heads/main "$c"
}

# mktree_raw: build a tree object from "mode name id" lines without git's
# own sanity checks (duplicates allowed); prints its id
mktree_raw() {
    local repo=$1; shift
    python3 -I - "$@" <<'PY' | git --git-dir="$repo" hash-object -t tree -w --literally --stdin
import sys
out = b""
for spec in sys.argv[1:]:
    mode, name, oid = spec.split(" ", 2)
    out += mode.encode() + b" " + name.encode() + b"\0" + bytes.fromhex(oid)
sys.stdout.buffer.write(out)
PY
}

test_security_symlinked_directory_is_not_followed() {
    new_bare evil1
    local g=$SRV/evil1.git outside=$PWD/outside
    mkdir -p "$outside"
    local link blob sub tree
    link=$(printf '%s' "$outside" | git --git-dir="$g" hash-object -w --stdin)
    blob=$(echo pwned | git --git-dir="$g" hash-object -w --stdin)
    sub=$(mktree_raw "$g" "100644 x $blob")
    tree=$(mktree_raw "$g" "120000 dir $link" "40000 dir $sub")
    push_tree evil1 "$tree"
    if pg clone "$BASE/evil1.git" c 2>err.txt; then fail "hostile clone succeeded"; fi
    cat err.txt
    [ ! -e "$outside/x" ] || fail "wrote through a symlink outside the work tree"
}

test_security_symlink_into_git_dir() {
    new_bare evil2
    local g=$SRV/evil2.git link blob sub tree
    link=$(printf '.git' | git --git-dir="$g" hash-object -w --stdin)
    blob=$(printf '[core]\n\tbare = true\n' | git --git-dir="$g" hash-object -w --stdin)
    sub=$(mktree_raw "$g" "100644 config $blob")
    tree=$(mktree_raw "$g" "120000 g $link" "40000 g $sub")
    push_tree evil2 "$tree"
    if pg clone "$BASE/evil2.git" c 2>err.txt; then fail "hostile clone succeeded"; fi
    [ ! -e c ] || ! grep -q "bare = true" c/.git/config 2>/dev/null || fail ".git/config overwritten"
}

test_security_pull_through_symlink_is_refused() {
    # an innocent first commit with a symlink, then a hostile second one
    new_bare evil3
    local g=$SRV/evil3.git outside=$PWD/outside
    mkdir -p "$outside"
    local link blob sub t1 t2 c1 c2
    link=$(printf '%s' "$outside" | git --git-dir="$g" hash-object -w --stdin)
    t1=$(mktree_raw "$g" "120000 dir $link")
    c1=$(git --git-dir="$g" commit-tree "$t1" -m one)
    git --git-dir="$g" update-ref refs/heads/main "$c1"
    pg clone "$BASE/evil3.git" c
    blob=$(echo pwned | git --git-dir="$g" hash-object -w --stdin)
    sub=$(mktree_raw "$g" "100644 x $blob")
    t2=$(mktree_raw "$g" "120000 dir $link" "40000 dir $sub")
    c2=$(git --git-dir="$g" commit-tree "$t2" -p "$c1" -m two)
    git --git-dir="$g" update-ref refs/heads/main "$c2"
    if (cd c && pg pull) 2>err.txt; then fail "hostile pull succeeded"; fi
    [ ! -e "$outside/x" ] || fail "wrote through a symlink outside the work tree"
}
