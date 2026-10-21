# SPDX-License-Identifier: GPL-3.0-or-later
# push scenarios (M5)

push_remote() { # push_remote NAME: bare repo with history, picogit clone in c
    new_bare "$1"
    seed "$1" up
    mkdir -p up/dir
    for i in 1 2 3; do
        echo "rev $i" > up/dir/file.txt
        echo "$i" >> up/history.txt
        commit_all up "rev $i"
    done
    git -C up push -q origin main
    pg clone "$BASE/$1.git" c
}

# verify_remote NAME: the remote passes fsck and a fresh real-git clone has
# exactly our work tree.
verify_remote() {
    git --git-dir="$SRV/$1.git" fsck --strict --no-progress
    rm -rf verify
    git clone -q "$BASE/$1.git" verify
    diff -r --no-dereference -x .git c verify || fail "remote content differs"
    assert_eq "$(git -C verify rev-parse HEAD)" "$(git -C c rev-parse HEAD)"
}

test_push_commit_from_shallow_clone() {
    push_remote ps1
    cd c
    echo pushed >> history.txt
    mkdir -p new/deep && head -c 5000000 /dev/urandom > new/deep/big.bin
    printf '#!/bin/sh\n' > new/run.sh && chmod +x new/run.sh
    ln -s ../history.txt new/link
    rm -r dir
    pg commit -a -m "from picogit"
    pg push 2>../out.txt
    cd ..
    grep -q "main -> main" out.txt
    check_repo c
    verify_remote ps1
    assert_eq "$(git -C c rev-parse origin/main)" "$(git -C c rev-parse HEAD)"
    [ -x verify/new/run.sh ] || fail "exec bit lost"
    assert_eq "$(readlink verify/new/link)" ../history.txt
    assert_eq "$(git -C verify log -1 --format='%an|%s')" "Pico Tester|from picogit"
    # no temporary pack left behind
    [ -z "$(ls c/.git/objects/pack)" ] || fail "leftover push pack"
}

test_push_several_commits_and_up_to_date() {
    push_remote ps2
    cd c
    for i in a b c; do
        echo "$i" > "f-$i.txt"
        pg commit -a -m "commit $i"
    done
    PICOGIT_TRACE=1 pg push 2>../trace.txt
    pg push 2>../out.txt
    cd ..
    grep -q "Everything up-to-date" out.txt
    # only the new objects are sent: 3 x (commit + root tree + blob)
    grep -q "pushing 3 commits, 9 objects" trace.txt || fail "$(grep pushing trace.txt)"
    verify_remote ps2
    assert_eq "$(git -C verify rev-list --count HEAD)" 6
}

test_push_rejected_when_remote_moved() {
    push_remote ps3
    echo other > up/other.txt
    commit_all up "someone else"
    git -C up push -q origin main
    echo mine > c/mine.txt
    (cd c && pg commit -a -m "mine")
    if (cd c && pg push) 2>err.txt; then fail "push over a moved remote succeeded"; fi
    grep -q "pull' first" err.txt
    assert_eq "$(git --git-dir="$SRV/ps3.git" rev-parse main)" "$(git -C up rev-parse HEAD)"
}

test_push_after_pull() {
    push_remote ps4
    echo upstream > up/upstream.txt
    commit_all up "upstream"
    git -C up push -q origin main
    (cd c && pg pull)
    echo local > c/local.txt
    (cd c && pg commit -a -m "after pull" && pg push)
    check_repo c
    verify_remote ps4
}

test_push_to_empty_remote() {
    new_bare ps5
    pg clone "$BASE/ps5.git" c 2>/dev/null
    mkdir c/src && echo 'int main(void){return 0;}' > c/src/main.c
    (cd c && pg commit -a -m "initial" && pg push)
    verify_remote ps5
    echo "second" > c/README
    (cd c && pg commit -a -m "second" && pg push)
    verify_remote ps5
    check_repo c
}

test_push_hook_rejection_is_reported() {
    push_remote ps6
    cat > "$SRV/ps6.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "policy: pushes are frozen" >&2
exit 1
EOF
    chmod +x "$SRV/ps6.git/hooks/pre-receive"
    echo x > c/x.txt
    (cd c && pg commit -a -m "frozen")
    if (cd c && pg push) 2>err.txt; then fail "rejected push reported success"; fi
    grep -q "remote: policy: pushes are frozen" err.txt
    grep -q "remote rejected refs/heads/main" err.txt
    # the tracking ref did not move
    assert_eq "$(git -C c rev-parse origin/main)" "$(git -C up rev-parse HEAD)"
}

test_push_with_token_auth() {
    push_remote ps7
    extra_server --auth "carol:pw123"
    git -C c config remote.origin.url "$XBASE/ps7.git"
    echo auth > c/auth.txt
    (cd c && pg commit -a -m "auth push")
    if (cd c && pg push) 2>err.txt; then fail "push without credentials succeeded"; fi
    grep -q "authentication required" err.txt
    (cd c && PICOGIT_TOKEN=pw123 PICOGIT_USERNAME=carol pg push)
    git -C c config remote.origin.url "$BASE/ps7.git"
    verify_remote ps7
}

test_push_from_detached_head_fails() {
    push_remote ps8
    git -C c checkout -q --detach
    if (cd c && pg push) 2>err.txt; then fail "push from detached HEAD succeeded"; fi
    grep -q "detached" err.txt
}

test_push_and_real_git_roundtrip() {
    # picogit pushes, real git builds on top, picogit pulls it back
    push_remote ps9
    echo "pico" > c/pico.txt
    (cd c && pg commit -a -m "pico" && pg push)
    git -C up pull -q --ff-only
    echo "git" > up/git.txt
    commit_all up "git"
    git -C up push -q origin main
    (cd c && pg pull)
    check_repo c
    assert_file c/git.txt git
    verify_remote ps9
}
