# SPDX-License-Identifier: GPL-3.0-or-later
# pull scenarios (M3)

# upstream NAME: bare repo + a real-git working clone in $PWD/up
upstream() {
    new_bare "$1"
    seed "$1" up
    mkdir -p up/dir up/old-dir
    echo one > up/a.txt
    echo keep > up/dir/keep.txt
    echo old > up/old-dir/x.txt
    echo becomes-dir > up/node
    printf '#!/bin/sh\n' > up/script.sh
    ln -s a.txt up/link
    commit_all up "base"
    git -C up push -q origin main
}

push_up() { commit_all up "$1" && git -C up push -q origin main; }

test_pull_fast_forward_all_change_kinds() {
    upstream p1
    pg clone "$BASE/p1.git" c
    # modify, add, delete, chmod, symlink retarget, file->dir, dir->file
    echo two >> up/a.txt
    echo new > up/dir/new.txt
    head -c 50000 /dev/urandom > up/dir/data.bin
    rm -rf up/old-dir && echo now-a-file > up/old-dir
    rm up/node && mkdir up/node && echo inside > up/node/f
    chmod +x up/script.sh
    rm up/link && ln -s dir/keep.txt up/link
    push_up "many changes"
    echo three >> up/a.txt
    push_up "second change"
    (cd c && pg pull) 2>out.txt
    grep -q "Fast-forward" out.txt
    check_repo c
    assert_eq "$(git -C c rev-parse HEAD)" "$(git -C up rev-parse HEAD)"
    assert_eq "$(git -C c rev-parse origin/main)" "$(git -C up rev-parse HEAD)"
    diff -r --no-dereference -x .git c up
    [ -x c/script.sh ] || fail "exec bit not applied"
    assert_eq "$(readlink c/link)" dir/keep.txt
    [ -f c/old-dir ] && [ -d c/node ] || fail "file/dir swaps not applied"
    # the shallow clone keeps working: history grew by the pulled commits
    assert_eq "$(git -C c rev-list --count HEAD)" 3
    [ -z "$(ls c/.git/objects | grep incoming)" ] || fail "quarantine left behind"
}

test_pull_outside_repository_fails() {
    if pg pull 2>err.txt; then fail "pull outside a repository succeeded"; fi
    grep -q "not a git repository" err.txt
}

test_pull_up_to_date_and_local_ahead() {
    upstream p2
    pg clone "$BASE/p2.git" c
    (cd c && pg pull) 2>out.txt
    grep -q "Already up to date" out.txt
    # local commit (made with real git): remote did not move
    echo local >> c/a.txt
    git -C c commit -q -am "local"
    (cd c && pg pull) 2>out.txt
    grep -q "Already up to date" out.txt
    assert_eq "$(git -C c log -1 --format=%s)" local
    check_repo c
}

test_pull_rejects_divergence() {
    upstream p3
    pg clone "$BASE/p3.git" c
    echo local > c/local.txt
    git -C c add local.txt && git -C c commit -q -m "local work"
    echo remote > up/remote.txt
    push_up "remote work"
    local before origin_before
    before=$(git -C c rev-parse HEAD)
    origin_before=$(git -C c rev-parse origin/main)
    if (cd c && pg pull) 2>err.txt; then fail "diverged pull succeeded"; fi
    grep -q "diverged" err.txt
    assert_eq "$(git -C c rev-parse HEAD)" "$before"
    assert_eq "$(git -C c rev-parse origin/main)" "$origin_before"
    [ ! -e c/remote.txt ] || fail "work tree touched"
    [ -z "$(ls c/.git/objects | grep incoming)" ] || fail "quarantine left behind"
    # the downloaded objects were discarded
    if git -C c cat-file -e "$(git -C up rev-parse HEAD)" 2>/dev/null; then
        fail "objects of the rejected pull were kept"
    fi
    check_repo c
}

test_pull_protects_local_changes() {
    upstream p4
    pg clone "$BASE/p4.git" c
    echo upstream >> up/a.txt
    echo upstream > up/dir/keep.txt
    push_up "upstream edits"
    # local edit to a file the pull changes: refused, nothing touched
    echo mine >> c/a.txt
    if (cd c && pg pull) 2>err.txt; then fail "pull overwrote local changes"; fi
    grep -q "would be overwritten" err.txt
    grep -q "a.txt" err.txt
    assert_eq "$(tail -1 c/a.txt)" mine
    assert_file c/dir/keep.txt keep
    # undo it; an unrelated local change survives the pull
    git -C c checkout -q a.txt
    echo "unrelated" > c/notes.txt
    echo "local edit" >> c/script.sh
    (cd c && pg pull)
    assert_eq "$(tail -1 c/a.txt)" upstream
    assert_eq "$(tail -1 c/script.sh)" "local edit"
    assert_file c/notes.txt unrelated
    assert_eq "$(git -C c status --porcelain)" "$(printf ' M script.sh\n?? notes.txt')"
}

test_pull_refuses_to_overwrite_untracked() {
    upstream p5
    pg clone "$BASE/p5.git" c
    echo upstream > up/new.txt
    push_up "add new.txt"
    echo "my own" > c/new.txt
    if (cd c && pg pull) 2>err.txt; then fail "untracked file overwritten"; fi
    grep -q "untracked work tree files would be overwritten" err.txt
    assert_file c/new.txt "my own"
    rm c/new.txt
    (cd c && pg pull)
    check_repo c
}

test_pull_full_clone_and_subdirectory() {
    upstream p6
    pg clone --depth 0 "$BASE/p6.git" c
    echo more >> up/dir/keep.txt
    push_up "edit"
    (cd c/dir && pg pull)
    check_repo c
    [ ! -f c/.git/shallow ] || fail "full clone became shallow"
    assert_eq "$(git -C c rev-list --count HEAD)" 2
}

test_pull_into_empty_clone() {
    new_bare p7
    pg clone "$BASE/p7.git" c 2>/dev/null
    seed p7 up
    echo first > up/f.txt
    push_up "first"
    (cd c && pg pull)
    check_repo c
    assert_file c/f.txt first
}

test_pull_protocol_v0_server() {
    upstream p8
    extra_server --protocol-v0
    pg clone "$XBASE/p8.git" c
    echo v0 >> up/a.txt
    push_up "v0 change"
    (cd c && PICOGIT_TRACE=1 pg pull) 2>trace.txt
    grep -q "upload-pack: protocol v0" trace.txt
    check_repo c
    assert_eq "$(git -C c rev-parse HEAD)" "$(git -C up rev-parse HEAD)"
}

test_pull_many_times() {
    upstream p9
    pg clone "$BASE/p9.git" c
    for i in 1 2 3 4; do
        echo "round $i" > up/round.txt
        [ $i = 3 ] && rm up/round.txt
        push_up "round $i"
        (cd c && pg -q pull)
        check_repo c
    done
    [ ! -e c/round.txt ] || [ "$(cat c/round.txt)" = "round 4" ] || fail "bad final state"
    assert_eq "$(git -C c rev-parse HEAD)" "$(git -C up rev-parse HEAD)"
}

test_pull_conflicts_are_detected_before_any_change() {
    upstream p10
    pg clone "$BASE/p10.git" c
    # upstream: a.txt deleted, new file below "blocker/", old-dir becomes a file
    git -C up rm -q a.txt
    mkdir -p up/blocker && echo new > up/blocker/f
    git -C up rm -rq old-dir && echo file > up/old-dir
    push_up "conflicting changes"
    # locally: an untracked file named like the new directory
    echo mine > c/blocker
    if (cd c && pg pull) 2>err.txt; then fail "pull over an untracked file succeeded"; fi
    grep -q "untracked work tree files would be overwritten" err.txt
    # nothing was changed: a.txt still exists, index and HEAD untouched
    assert_file c/a.txt one
    check_repo_except_untracked c blocker
    rm c/blocker
    # untracked content inside a directory that becomes a file
    echo scratch > c/old-dir/untracked.txt
    if (cd c && pg pull) 2>err.txt; then fail "pull deleted untracked content"; fi
    grep -q "old-dir" err.txt
    assert_file c/old-dir/untracked.txt scratch
    assert_file c/a.txt one
    rm c/old-dir/untracked.txt
    (cd c && pg pull)
    check_repo c
    assert_file c/old-dir file
    assert_file c/blocker/f new
}
