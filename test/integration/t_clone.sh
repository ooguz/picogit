# SPDX-License-Identifier: GPL-3.0-or-later
# clone scenarios (M2)

# make_fixture NAME: a repository with three commits containing binary
# data, an executable, a symlink, nested directories and a deleted file.
make_fixture() {
    new_bare "$1"
    local w=$WORK/fixture-$1
    rm -rf "$w"
    seed "$1" "$w"
    mkdir -p "$w/dir/sub/deeper" "$w/empty-later"
    echo "first" > "$w/readme.txt"
    echo "gone soon" > "$w/empty-later/doomed.txt"
    commit_all "$w" "first"
    printf '#!/bin/sh\necho run\n' > "$w/run.sh"
    chmod +x "$w/run.sh"
    head -c 300000 /dev/urandom > "$w/dir/blob.bin"
    printf 'a\0b\0c\n' > "$w/dir/sub/nul.dat"
    echo "deep" > "$w/dir/sub/deeper/file.txt"
    ln -s readme.txt "$w/link-to-readme"
    ln -s dir/sub "$w/link-to-dir"
    echo "spaces" > "$w/name with spaces.txt"
    echo "utf8" > "$w/dosya-çğüşöı.txt"
    commit_all "$w" "second"
    rm -rf "$w/empty-later"
    echo "first, edited" > "$w/readme.txt"
    commit_all "$w" "third"
    git -C "$w" push -q origin main
}

# same_tree DIR: the checked out files equal the fixture (content, modes,
# symlinks) and HEAD matches the remote.
same_tree() {
    local repo=$1 bare=$2
    assert_eq "$(git -C "$repo" rev-parse HEAD)" "$(git --git-dir="$SRV/$bare.git" rev-parse main)"
    diff -r --no-dereference -x .git "$repo" "$WORK/fixture-$bare" || fail "work tree differs"
    [ -x "$repo/run.sh" ] || fail "exec bit lost"
    [ -L "$repo/link-to-readme" ] || fail "symlink not created"
    assert_eq "$(readlink "$repo/link-to-readme")" "readme.txt"
    [ ! -e "$repo/empty-later" ] || fail "deleted directory present"
}

test_clone_shallow_default() {
    make_fixture fx1
    pg clone "$BASE/fx1.git" c 2>err.txt
    check_repo c
    same_tree c fx1
    assert_eq "$(git -C c rev-list --count HEAD)" 1
    [ -f c/.git/shallow ] || fail "no .git/shallow"
    assert_eq "$(cat c/.git/shallow)" "$(git -C c rev-parse HEAD)"
    assert_eq "$(git -C c rev-parse --abbrev-ref HEAD)" main
    assert_eq "$(git -C c config remote.origin.url)" "$BASE/fx1.git"
    assert_eq "$(git -C c config branch.main.merge)" refs/heads/main
    assert_eq "$(git -C c rev-parse origin/main)" "$(git -C c rev-parse HEAD)"
    # no temporary pack files left behind
    [ -z "$(ls c/.git/objects/pack)" ] || fail "leftover files in objects/pack"
}

test_clone_full_history() {
    make_fixture fx2
    pg clone --depth 0 "$BASE/fx2.git" c
    check_repo c
    same_tree c fx2
    assert_eq "$(git -C c rev-list --count HEAD)" 3
    [ ! -f c/.git/shallow ] || fail ".git/shallow written for a full clone"
    git -C c log --format=%s | tr '\n' ' ' | grep -q "third second first"
}

test_clone_depth_two() {
    make_fixture fx3
    pg clone --depth 2 "$BASE/fx3.git" c
    check_repo c
    assert_eq "$(git -C c rev-list --count HEAD)" 2
}

test_clone_into_default_dir_and_errors() {
    make_fixture fx4
    mkdir d && cd d
    pg clone "$BASE/fx4.git"
    check_repo fx4
    # existing non-empty destination
    if pg clone "$BASE/fx4.git" 2>err.txt; then fail "clone into non-empty dir succeeded"; fi
    grep -q "already exists and is not an empty directory" err.txt
    # missing repository: nothing is left behind
    if pg clone "$BASE/nope.git" nope 2>err.txt; then fail "clone of missing repo succeeded"; fi
    grep -q "not found" err.txt
    [ ! -e nope ] || fail "failed clone left a directory"
    # an existing empty directory is fine
    mkdir empty
    pg clone "$BASE/fx4.git" empty
    check_repo empty
}

test_clone_branch_and_tag() {
    make_fixture fx5
    local w=$WORK/fixture-fx5
    git -C "$w" checkout -q -b feature
    echo feature > "$w/feature.txt"
    commit_all "$w" "feature work"
    git -C "$w" tag -a v1.0 -m "release 1.0"
    git -C "$w" push -q origin feature v1.0
    pg clone --branch feature "$BASE/fx5.git" c
    check_repo c
    assert_eq "$(git -C c rev-parse --abbrev-ref HEAD)" feature
    assert_file c/feature.txt feature
    assert_eq "$(git -C c config branch.feature.merge)" refs/heads/feature
    pg clone -b v1.0 "$BASE/fx5.git" t
    check_repo t
    assert_eq "$(git -C t rev-parse HEAD)" "$(git -C "$w" rev-parse 'v1.0^{commit}')"
    if pg clone --branch nosuch "$BASE/fx5.git" x 2>err.txt; then fail "unknown branch accepted"; fi
    grep -q "remote branch 'nosuch' not found" err.txt
}

test_clone_empty_repository() {
    new_bare empty1
    pg clone "$BASE/empty1.git" c 2>err.txt
    grep -q "empty repository" err.txt
    assert_eq "$(git -C c symbolic-ref HEAD)" refs/heads/main
    assert_eq "$(git -C c status --porcelain)" ""
    git -C c fsck --strict
}

test_clone_protocol_v0_server() {
    make_fixture fx6
    extra_server --protocol-v0
    PICOGIT_TRACE=1 pg clone "$XBASE/fx6.git" c 2>trace.txt
    check_repo c
    same_tree c fx6
    assert_eq "$(git -C c rev-list --count HEAD)" 1
    grep -q "upload-pack: protocol v0" trace.txt || fail "v0 path not used"
    pg clone --depth 0 "$XBASE/fx6.git" full
    check_repo full
    assert_eq "$(git -C full rev-list --count HEAD)" 3
}

test_clone_close_delimited_responses() {
    make_fixture fx7
    extra_server --no-chunked
    pg clone "$XBASE/fx7.git" c
    check_repo c
    same_tree c fx7
}

test_clone_through_redirect() {
    make_fixture fx8
    pg clone "$BASE/redirect/fx8.git" c
    check_repo c
    # the configured URL is the one the user gave
    assert_eq "$(git -C c config remote.origin.url)" "$BASE/redirect/fx8.git"
}

test_clone_big_history_with_deltas() {
    # many revisions of a big file make git produce OFS_DELTA chains
    new_bare fx9
    seed fx9 w
    seq 1 20000 > w/numbers.txt
    for i in 1 2 3 4 5 6 7 8; do
        sed -i "s/^$((i * 1000))\$/changed $i/" w/numbers.txt
        echo "rev $i" >> w/log.txt
        commit_all w "rev $i"
    done
    git -C w push -q origin main
    git --git-dir="$SRV/fx9.git" repack -adq --depth=50 --window=10
    PICOGIT_TRACE=1 pg clone --depth 0 "$BASE/fx9.git" c 2>trace.txt
    grep -q "upload-pack: protocol v2" trace.txt || fail "v2 not used"
    grep "pack: .* deltas" trace.txt
    grep -qE "pack: [0-9]+ objects, [1-9][0-9]* deltas" trace.txt || fail "no deltas in pack"
    check_repo c
    cmp c/numbers.txt w/numbers.txt
    assert_eq "$(git -C c rev-list --count HEAD)" 8
}

test_clone_with_auth() {
    make_fixture fx10
    extra_server --auth "bob:t0ken"
    if pg clone "$XBASE/fx10.git" c 2>err.txt; then fail "clone without credentials succeeded"; fi
    grep -q "authentication required" err.txt
    # token from the environment
    PICOGIT_TOKEN=t0ken PICOGIT_USERNAME=bob pg clone "$XBASE/fx10.git" c1
    check_repo c1
    # ~/.netrc
    printf 'machine 127.0.0.1\n  login bob\n  password t0ken\n' > "$HOME/.netrc"
    pg clone "$XBASE/fx10.git" c2
    rm -f "$HOME/.netrc"
    check_repo c2
    # credentials in the URL: works, warns, never printed
    local url=${XBASE/http:\/\//http://bob:t0ken@}
    pg clone "$url/fx10.git" c3 2>err.txt
    check_repo c3
    grep -q "credentials in the URL" err.txt
    if grep -q t0ken err.txt; then fail "token printed"; fi
    # wrong password
    if PICOGIT_TOKEN=wrong PICOGIT_USERNAME=bob pg clone "$XBASE/fx10.git" c4 2>err.txt; then
        fail "wrong token accepted"
    fi
    grep -q "authentication failed" err.txt
    if grep -q wrong err.txt; then fail "token printed"; fi
}

test_clone_submodule_is_skipped() {
    new_bare subm
    seed subm w
    echo top > w/top.txt
    commit_all w "top"
    # add a gitlink entry by hand (no submodule repository needed)
    git -C w update-index --add --cacheinfo 160000,$(git -C w rev-parse HEAD),vendor/lib
    git -C w commit -q -m "add submodule"
    git -C w push -q origin main
    pg clone "$BASE/subm.git" c 2>err.txt
    grep -q "submodule 'vendor/lib' is not supported" err.txt
    [ -d c/vendor/lib ] || fail "submodule directory not created"
    check_repo c
}

test_clone_remote_head_without_symref() {
    make_fixture fx11
    # detached HEAD on the server: no symref is advertised (v2 and v0)
    git --git-dir="$SRV/fx11.git" rev-parse main > "$WORK/head"
    cp "$WORK/head" "$SRV/fx11.git/HEAD"
    pg clone "$BASE/fx11.git" c
    check_repo c
    assert_eq "$(git -C c symbolic-ref HEAD)" refs/heads/main
    extra_server --protocol-v0
    pg clone "$XBASE/fx11.git" c0
    check_repo c0
    assert_eq "$(git -C c0 symbolic-ref HEAD)" refs/heads/main
    # no branch at that commit at all: detached checkout
    git --git-dir="$SRV/fx11.git" rev-parse main~1 > "$WORK/head"
    cp "$WORK/head" "$SRV/fx11.git/HEAD"
    pg clone "$BASE/fx11.git" d 2>err.txt
    grep -q "not on a branch" err.txt
    assert_eq "$(git -C d rev-parse HEAD)" "$(git --git-dir="$SRV/fx11.git" rev-parse main~1)"
    check_repo d
}
