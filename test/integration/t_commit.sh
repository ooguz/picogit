# SPDX-License-Identifier: GPL-3.0-or-later
# commit -a scenarios (M4)

# simple_remote NAME: bare repo with one commit, cloned by picogit into c
simple_remote() {
    new_bare "$1"
    seed "$1" up
    mkdir -p up/dir/sub
    echo base > up/base.txt
    echo nested > up/dir/sub/n.txt
    printf '#!/bin/sh\n' > up/tool.sh
    chmod +x up/tool.sh
    commit_all up "base"
    git -C up push -q origin main
    pg clone "$BASE/$1.git" c
}

# expect_tree_like_git_add_all: our HEAD tree equals what real git would
# commit for the same work tree with `git add -A`.
expect_tree_like_git_add_all() {
    rm -rf verify && cp -a c verify
    git -C verify reset -q --soft HEAD~1 2>/dev/null || true
    git -C verify add -A
    assert_eq "$(git -C c rev-parse 'HEAD^{tree}')" "$(git -C verify write-tree)" "tree vs git add -A"
}

test_commit_all_change_kinds() {
    simple_remote cm1
    cd c
    echo changed >> base.txt
    rm dir/sub/n.txt
    echo new > dir/new.txt
    mkdir -p brand/new/dir && head -c 20000 /dev/urandom > brand/new/dir/blob.bin
    chmod -x tool.sh
    ln -s base.txt link
    echo spaced > "with space.txt"
    pg commit -a -m "all kinds" > ../out.txt
    cd ..
    grep -q "\[main [0-9a-f]\{7\}\] all kinds" out.txt
    check_repo c
    expect_tree_like_git_add_all
    assert_eq "$(git -C c log -1 --format=%s)" "all kinds"
    assert_eq "$(git -C c log -1 --format='%an <%ae>|%cn <%ce>')" \
        "Pico Tester <pico@example.com>|Pico Tester <pico@example.com>"
    assert_eq "$(git -C c rev-parse HEAD^)" "$(git -C up rev-parse HEAD)"
    assert_eq "$(git -C c ls-tree HEAD link | cut -c1-6)" 120000
    assert_eq "$(git -C c ls-tree HEAD tool.sh | cut -c1-6)" 100644
    [ -z "$(git -C c ls-tree -r HEAD dir/sub)" ] || fail "deleted file still in tree"
}

test_commit_nothing_to_commit() {
    simple_remote cm2
    cd c
    set +e
    pg commit -a -m "nothing" > ../out.txt 2>&1
    local rc=$?
    set -e
    cd ..
    assert_eq "$rc" 1
    grep -q "nothing to commit" out.txt
    assert_eq "$(git -C c rev-list --count HEAD)" 1
    # touching a file without changing it is not a change either
    touch c/base.txt
    if (cd c && pg commit -a -m "touch"); then fail "touch produced a commit"; fi
    check_repo c
}

test_commit_respects_gitignore() {
    simple_remote cm3
    cd c
    printf '*.log\n!keep.log\nbuild/\n/root-only.txt\n' > .gitignore
    mkdir -p build sub/build nested
    echo x > a.log; echo k > keep.log; echo b > build/out.o; echo b > sub/build/o
    echo r > root-only.txt; echo r > nested/root-only.txt
    printf '*.tmp\n' > nested/.gitignore
    echo t > nested/x.tmp; echo t > x.tmp
    echo secret > secret.key
    echo 'secret.key' >> .git/info/exclude
    pg commit -a -m "ignore rules"
    cd ..
    check_repo c
    local files
    files=$(git -C c ls-tree -r --name-only HEAD | sort | tr '\n' ' ')
    assert_eq "$files" ".gitignore base.txt dir/sub/n.txt keep.log nested/.gitignore nested/root-only.txt tool.sh x.tmp "
    # tracked files stay tracked even when a pattern matches them
    echo '*.txt' >> c/.gitignore
    echo more >> c/base.txt
    (cd c && pg commit -a -m "tracked but ignored")
    git -C c show --stat HEAD | grep -q base.txt
    check_repo c
}

test_commit_identity_sources() {
    simple_remote cm4
    echo 1 >> c/base.txt
    if (cd c && unset PICOGIT_AUTHOR_NAME PICOGIT_AUTHOR_EMAIL && pg commit -a -m x) 2>err.txt; then
        fail "commit without identity succeeded"
    fi
    grep -q "author identity unknown" err.txt
    # ~/.gitconfig is the last resort
    printf '[user]\n\tname = Global User\n\temail = global@example.com\n' > "$HOME/.gitconfig.user"
    cp "$HOME/.gitconfig" "$HOME/.gitconfig.orig"
    cat "$HOME/.gitconfig.user" >> "$HOME/.gitconfig"
    (cd c && unset PICOGIT_AUTHOR_NAME PICOGIT_AUTHOR_EMAIL && pg commit -a -m "from global")
    mv "$HOME/.gitconfig.orig" "$HOME/.gitconfig"
    assert_eq "$(git -C c log -1 --format='%an <%ae>')" "Global User <global@example.com>"
    echo 1b >> c/base.txt
    git -C c config user.name "Config User"
    git -C c config user.email "config@example.com"
    (cd c && unset PICOGIT_AUTHOR_NAME PICOGIT_AUTHOR_EMAIL && TZ=UTC-3 pg commit -a -m "from config")
    assert_eq "$(git -C c log -1 --format='%an <%ae>')" "Config User <config@example.com>"
    git -C c cat-file commit HEAD | grep -q '^author Config User <config@example.com> [0-9]* +0300$'
    echo 2 >> c/base.txt
    (cd c && TZ=UTC+5:30 pg commit -a -m "env wins")
    assert_eq "$(git -C c log -1 --format='%an')" "Pico Tester"
    git -C c cat-file commit HEAD | grep -q ' -0530$'
    check_repo c
}

test_commit_message_cleanup() {
    simple_remote cm5
    echo 1 >> c/base.txt
    (cd c && pg commit -a -m "$(printf '\n\nsubject   \n\n\n\nbody line  \n\n')")
    assert_eq "$(git -C c cat-file commit HEAD | sed '1,/^$/d')" "$(printf 'subject\n\nbody line')"
    echo 2 >> c/base.txt
    if (cd c && pg commit -a -m "   ") 2>err.txt; then fail "empty message accepted"; fi
    grep -q "empty commit message" err.txt
    if (cd c && pg commit -m "no -a") 2>err.txt; then fail "commit without -a accepted"; fi
    grep -q "commit -a" err.txt
    (cd c && pg commit -am "combined flags")
    assert_eq "$(git -C c log -1 --format=%s)" "combined flags"
}

test_commit_root_in_empty_clone() {
    new_bare cm6
    pg clone "$BASE/cm6.git" c 2>/dev/null
    mkdir c/d && echo hello > c/d/hello.txt
    (cd c && pg commit -a -m "root commit") > out.txt
    grep -q "root-commit" out.txt
    check_repo c
    assert_eq "$(git -C c rev-list --count HEAD)" 1
    assert_eq "$(git -C c show HEAD:d/hello.txt)" hello
}

test_commit_detects_same_size_change_immediately() {
    simple_remote cm7
    cd c
    echo aaaa > same.txt
    pg commit -a -m one
    echo bbbb > same.txt   # same size, same second
    pg commit -a -m two
    cd ..
    assert_eq "$(git -C c show HEAD:same.txt)" bbbb
    check_repo c
}

test_commit_core_filemode_false() {
    simple_remote cm8
    git -C c config core.filemode false
    chmod -x c/tool.sh
    chmod +x c/base.txt
    echo new > c/new.txt
    chmod +x c/new.txt
    (cd c && pg commit -a -m "modes ignored")
    assert_eq "$(git -C c ls-tree HEAD tool.sh | cut -c1-6)" 100755
    assert_eq "$(git -C c ls-tree HEAD base.txt | cut -c1-6)" 100644
    assert_eq "$(git -C c ls-tree HEAD new.txt | cut -c1-6)" 100644
}

test_commit_core_symlinks_false() {
    new_bare cm9
    seed cm9 up
    echo target > up/t.txt
    ln -s t.txt up/l
    commit_all up "with link"
    git -C up push -q origin main
    pg clone "$BASE/cm9.git" c
    git -C c config core.symlinks false
    # emulate a file system without symlinks: replace the link by a file
    rm c/l && printf 'other.txt' > c/l
    (cd c && pg commit -a -m "retarget")
    assert_eq "$(git -C c ls-tree HEAD l | cut -c1-6)" 120000
    assert_eq "$(git -C c cat-file blob HEAD:l)" other.txt
}

test_commit_skips_embedded_repository() {
    simple_remote cm10
    git init -q c/inner
    echo x > c/inner/file
    echo top > c/top.txt
    (cd c && pg commit -a -m "with inner repo") 2>err.txt
    grep -q "embedded git repositories are not supported" err.txt
    [ -z "$(git -C c ls-tree HEAD inner)" ] || fail "embedded repo committed"
    git -C c ls-tree HEAD top.txt | grep -q top.txt
}
