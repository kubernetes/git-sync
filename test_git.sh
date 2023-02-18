#!/bin/bash
#
# Copyright 2023 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

function fail() {
    echo "FAIL:" "$@" >&3
    return 42
}

function pass() {
    echo "PASS"
}

function assert_file_exists() {
    if ! [[ -f "$1" ]]; then
        fail "$1 does not exist"
    fi
}

function assert_file_absent() {
    if [[ -f "$1" ]]; then
        fail "$1 exists but should not"
    fi
}

function assert_eq() {
    if [[ "$1" == "$2" ]]; then
        return
    fi
    fail "'$1' does not equal '$2'"
}

function assert_substr() {
    if [[ "$1" =~ "$2" ]]; then
        return
    fi
    fail "'$1' does not contain '$2'"
}

# DIR is the directory in which all this test's state lives.
RUNID="${RANDOM}${RANDOM}"
DIR="/tmp/git-sync-git.$RUNID"
mkdir "$DIR"

# WORKDIR is where test cases run
WORKDIR="$DIR/work"
function clean_workdir() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
}

#
# After all the test functions are defined, we can iterate over them and run
# them all automatically.  See the end of this file.
#

##############################################
# Test `git init` on an existing repo
##############################################
function git::reinit_existing_repo() {
    git init -b main
    date > file
    git add file 
    git commit -qam 'commit_1'
    TREE1="$(git ls-tree HEAD | cut -d' ' -f3 | cut -f1)"
    git init
    TREE2="$(git ls-tree HEAD | cut -d' ' -f3 | cut -f1)"
    assert_eq "$TREE1" "$TREE2"
}

##############################################
# Test `git fetch` of a branch
##############################################
function git::fetch_upstream_branch() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b main

    # A commit on branch 1
    git checkout -b upstream_branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"

    # A commit on branch 2
    git checkout -b upstream_branch_2
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"

    popd >/dev/null

    mkdir clone
    cd clone
    git init -b clone_branch

    assert_substr "$(git cat-file -t "$SHA1" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"

    git fetch "file://$WORKDIR/upstream" upstream_branch_1
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    git checkout "$SHA1"
    assert_file_exists file_1
    assert_file_absent file_2

    git fetch "file://$WORKDIR/upstream" upstream_branch_2
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    git checkout "$SHA2"
    assert_file_exists file_1
    assert_file_exists file_2
}

##############################################
# Test `git fetch` of a tag
##############################################
function git::fetch_upstream_tag() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b main

    # A tag on branch 1 (not at HEAD)
    git checkout -b upstream_branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"
    git tag upstream_tag_1

    # Another tag on branch 1 (at HEAD)
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"
    git tag upstream_tag_2

    # A tag on branch 2 (not at HEAD)
    git checkout -b upstream_branch_2
    date > file_3
    git add file_3
    git commit -qam 'commit_3'
    SHA3="$(git rev-parse HEAD)"
    git tag upstream_tag_3

    # Another tag on branch 2 (at HEAD)
    date > file_4
    git add file_4
    git commit -qam 'commit_4'
    SHA4="$(git rev-parse HEAD)"
    git tag upstream_tag_4

    popd >/dev/null

    mkdir clone
    pushd clone >/dev/null
    git init -b clone_branch

    assert_substr "$(git cat-file -t "$SHA1" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"

    git fetch "file://$WORKDIR/upstream" upstream_tag_1
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA1"
    assert_file_exists file_1
    assert_file_absent file_2
    assert_file_absent file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" upstream_tag_2
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA2"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_absent file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" upstream_tag_3
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_eq "$(git cat-file -t "$SHA3")" "commit"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA3"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_exists file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" upstream_tag_4
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_eq "$(git cat-file -t "$SHA3")" "commit"
    assert_eq "$(git cat-file -t "$SHA4")" "commit"
    git checkout "$SHA4"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_exists file_3
    assert_file_exists file_4
}

##############################################
# Test `git fetch` of an annotated tag
##############################################
function git::fetch_upstream_tag_annotated() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b main

    # A tag on branch 1 (not at HEAD)
    git checkout -b upstream_branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"
    git tag -am "anntag_1" upstream_anntag_1

    # Another tag on branch 1 (at HEAD)
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"
    git tag -am "anntag_2" upstream_anntag_2

    # A tag on branch 2 (not at HEAD)
    git checkout -b upstream_branch_2
    date > file_3
    git add file_3
    git commit -qam 'commit_3'
    SHA3="$(git rev-parse HEAD)"
    git tag -am "anntag_3" upstream_anntag_3

    # Another tag on branch 2 (at HEAD)
    date > file_4
    git add file_4
    git commit -qam 'commit_4'
    SHA4="$(git rev-parse HEAD)"
    git tag -am "anntag_4" upstream_anntag_4

    popd >/dev/null

    mkdir clone
    pushd clone >/dev/null
    git init -b clone_branch

    assert_substr "$(git cat-file -t "$SHA1" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"

    git fetch "file://$WORKDIR/upstream" upstream_anntag_1
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA1"
    assert_file_exists file_1
    assert_file_absent file_2
    assert_file_absent file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" upstream_anntag_2
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA2"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_absent file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" upstream_anntag_3
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_eq "$(git cat-file -t "$SHA3")" "commit"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA3"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_exists file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" upstream_anntag_4
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_eq "$(git cat-file -t "$SHA3")" "commit"
    assert_eq "$(git cat-file -t "$SHA4")" "commit"
    git checkout "$SHA4"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_exists file_3
    assert_file_exists file_4
}

##############################################
# Test `git fetch` of a SHA
##############################################
function git::fetch_upstream_sha() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b main

    # A commit on branch 1 (not at HEAD)
    git checkout -b upstream_branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"

    # Another commit on branch 1 (at HEAD)
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"

    # A commit on branch 2 (not at HEAD)
    git checkout -b upstream_branch_2
    date > file_3
    git add file_3
    git commit -qam 'commit_3'
    SHA3="$(git rev-parse HEAD)"

    # Another commit on branch 2 (at HEAD)
    date > file_4
    git add file_4
    git commit -qam 'commit_4'
    SHA4="$(git rev-parse HEAD)"

    popd >/dev/null

    mkdir clone
    pushd clone >/dev/null
    git init -b clone_branch

    assert_substr "$(git cat-file -t "$SHA1" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"

    git fetch "file://$WORKDIR/upstream" "$SHA1"
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_substr "$(git cat-file -t "$SHA2" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA1"
    assert_file_exists file_1
    assert_file_absent file_2
    assert_file_absent file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" "$SHA2"
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_substr "$(git cat-file -t "$SHA3" 2>&1 || true)" "could not get object info"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA2"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_absent file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" "$SHA3"
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_eq "$(git cat-file -t "$SHA3")" "commit"
    assert_substr "$(git cat-file -t "$SHA4" 2>&1 || true)" "could not get object info"
    git checkout "$SHA3"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_exists file_3
    assert_file_absent file_4

    git fetch "file://$WORKDIR/upstream" "$SHA4"
    assert_eq "$(git cat-file -t "$SHA1")" "commit"
    assert_eq "$(git cat-file -t "$SHA2")" "commit"
    assert_eq "$(git cat-file -t "$SHA3")" "commit"
    assert_eq "$(git cat-file -t "$SHA4")" "commit"
    git checkout "$SHA4"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_file_exists file_3
    assert_file_exists file_4
}

##############################################
# Test git shallow fetch from a branch
##############################################
function git::shallow_fetch_branch() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b upstream_branch

    # Some commits
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA="$(git rev-parse HEAD)"

    popd >/dev/null

    mkdir clone
    cd clone
    git init -b clone_branch

    git fetch "file://$WORKDIR/upstream" upstream_branch
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"

    git fetch "file://$WORKDIR/upstream" upstream_branch --depth 1
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "true"

    git fetch "file://$WORKDIR/upstream" upstream_branch --unshallow
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"
}

##############################################
# Test git shallow fetch from a tag
##############################################
function git::shallow_fetch_tag() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b upstream_branch

    # Some commits
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA="$(git rev-parse HEAD)"
    git tag upstream_tag

    popd >/dev/null

    mkdir clone
    cd clone
    git init -b clone_branch

    git fetch "file://$WORKDIR/upstream" upstream_tag
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"

    git fetch "file://$WORKDIR/upstream" upstream_tag --depth 1
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "true"

    git fetch "file://$WORKDIR/upstream" upstream_tag --unshallow
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"
}

##############################################
# Test git shallow fetch from an annotated tag
##############################################
function git::shallow_fetch_tag_annotated() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b upstream_branch

    # Some commits
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA="$(git rev-parse HEAD)"
    git tag -am "upstream_anntag" upstream_anntag

    popd >/dev/null

    mkdir clone
    cd clone
    git init -b clone_branch

    git fetch "file://$WORKDIR/upstream" upstream_anntag
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"

    git fetch "file://$WORKDIR/upstream" upstream_anntag --depth 1
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "true"

    git fetch "file://$WORKDIR/upstream" upstream_anntag --unshallow
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"
}

##############################################
# Test git shallow fetch from a SHA
##############################################
function git::shallow_fetch_sha() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b upstream_branch

    # Some commits
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA="$(git rev-parse HEAD)"

    popd >/dev/null

    mkdir clone
    cd clone
    git init -b clone_branch

    git fetch "file://$WORKDIR/upstream" "$SHA"
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"

    git fetch "file://$WORKDIR/upstream" "$SHA" --depth 1
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "true"

    git fetch "file://$WORKDIR/upstream" "$SHA" --unshallow
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"
}

##############################################
# Test git fetch with depth too large
##############################################
function git::fetch_too_large_depth() {
    mkdir upstream
    pushd upstream >/dev/null
    git init -b upstream_branch

    # Some commits
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA="$(git rev-parse HEAD)"

    popd >/dev/null

    mkdir clone
    cd clone
    git init -b clone_branch

    git fetch "file://$WORKDIR/upstream" upstream_branch --depth 1000
    git checkout "$SHA"
    assert_file_exists file_1
    assert_file_exists file_2
    assert_eq "$(git rev-parse --is-shallow-repository)" "false"
}

##############################################
# Test git rev-parse with a branch
##############################################
function git::rev_parse_branch() {
    mkdir repo
    pushd repo >/dev/null
    git init -b main

    # A commit on branch 1
    git checkout -b branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"

    # A commit on branch 2
    git checkout -b branch_2
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"

    assert_eq "$(git rev-parse branch_1)" "$SHA1"
    assert_eq "$(git rev-parse branch_1^{commit})" "$SHA1"
    assert_eq "$(git rev-parse branch_2)" "$SHA2"
    assert_eq "$(git rev-parse branch_2^{commit})" "$SHA2"
}

##############################################
# Test git rev-parse with a tag
##############################################
function git::rev_parse_tag() {
    mkdir repo
    pushd repo >/dev/null
    git init -b main

    # A tag on branch 1 (not at HEAD)
    git checkout -b branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"
    git tag tag_1

    # Another tag on branch 1 (at HEAD)
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"
    git tag tag_2

    # A tag on branch 2 (not at HEAD)
    git checkout -b branch_2
    date > file_3
    git add file_3
    git commit -qam 'commit_3'
    SHA3="$(git rev-parse HEAD)"
    git tag tag_3

    # Another tag on branch 2 (at HEAD)
    date > file_4
    git add file_4
    git commit -qam 'commit_4'
    SHA4="$(git rev-parse HEAD)"
    git tag tag_4

    assert_eq "$(git rev-parse tag_1)" "$SHA1"
    assert_eq "$(git rev-parse tag_1^{commit})" "$SHA1"
    assert_eq "$(git rev-parse tag_2)" "$SHA2"
    assert_eq "$(git rev-parse tag_2^{commit})" "$SHA2"
    assert_eq "$(git rev-parse tag_3)" "$SHA3"
    assert_eq "$(git rev-parse tag_3^{commit})" "$SHA3"
    assert_eq "$(git rev-parse tag_4)" "$SHA4"
    assert_eq "$(git rev-parse tag_4^{commit})" "$SHA4"
}

##############################################
# Test git rev-parse with an annotated tag
##############################################
function git::rev_parse_tag_annotated() {
    mkdir repo
    pushd repo >/dev/null
    git init -b main

    # A tag on branch 1 (not at HEAD)
    git checkout -b branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"
    git tag -am "anntag_1" anntag_1

    # Another tag on branch 1 (at HEAD)
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"
    git tag -am "anntag_2" anntag_2

    # A tag on branch 2 (not at HEAD)
    git checkout -b branch_2
    date > file_3
    git add file_3
    git commit -qam 'commit_3'
    SHA3="$(git rev-parse HEAD)"
    git tag -am "anntag_3" anntag_3

    # Another tag on branch 2 (at HEAD)
    date > file_4
    git add file_4
    git commit -qam 'commit_4'
    SHA4="$(git rev-parse HEAD)"
    git tag -am "anntag_4" anntag_4

    # Annotated tags have their own SHA, which can be found with rev-parse, but
    # it doesn't make sense to test rev-parse against itself.
    assert_eq "$(git rev-parse anntag_1^{commit})" "$SHA1"
    assert_eq "$(git rev-parse anntag_2^{commit})" "$SHA2"
    assert_eq "$(git rev-parse anntag_3^{commit})" "$SHA3"
    assert_eq "$(git rev-parse anntag_4^{commit})" "$SHA4"
}

##############################################
# Test git rev-parse with a SHA
##############################################
function git::rev_parse_sha() {
    mkdir repo
    pushd repo >/dev/null
    git init -b main

    # A commit on branch 1 (not at HEAD)
    git checkout -b branch_1
    date > file_1
    git add file_1
    git commit -qam 'commit_1'
    SHA1="$(git rev-parse HEAD)"
    SHORT1="$(echo "$SHA1" | sed 's/........$//')"

    # Another commit on branch 1 (at HEAD)
    date > file_2
    git add file_2
    git commit -qam 'commit_2'
    SHA2="$(git rev-parse HEAD)"
    SHORT2="$(echo "$SHA2" | sed 's/........$//')"

    # A commit on branch 2 (not at HEAD)
    git checkout -b branch_2
    date > file_3
    git add file_3
    git commit -qam 'commit_3'
    SHA3="$(git rev-parse HEAD)"
    SHORT3="$(echo "$SHA3" | sed 's/........$//')"

    # Another commit on branch 2 (at HEAD)
    date > file_4
    git add file_4
    git commit -qam 'commit_4'
    SHA4="$(git rev-parse HEAD)"
    SHORT4="$(echo "$SHA4" | sed 's/........$//')"

    assert_eq "$(git rev-parse "$SHA1")" "$SHA1"
    assert_eq "$(git rev-parse "$SHA1^{commit}")" "$SHA1"
    assert_eq "$(git rev-parse "$SHORT1")" "$SHA1"
    assert_eq "$(git rev-parse "$SHA2")" "$SHA2"
    assert_eq "$(git rev-parse "$SHA2^{commit}")" "$SHA2"
    assert_eq "$(git rev-parse "$SHORT2")" "$SHA2"
    assert_eq "$(git rev-parse "$SHA3")" "$SHA3"
    assert_eq "$(git rev-parse "$SHA3^{commit}")" "$SHA3"
    assert_eq "$(git rev-parse "$SHORT3")" "$SHA3"
    assert_eq "$(git rev-parse "$SHA4")" "$SHA4"
    assert_eq "$(git rev-parse "$SHA4^{commit}")" "$SHA4"
    assert_eq "$(git rev-parse "$SHORT4")" "$SHA4"
}

##############################################
# Test git rev-parse with a non-existent ref
##############################################
function git::rev_parse_non_existent_name() {
    mkdir repo
    pushd repo >/dev/null
    git init -b main

    assert_substr "$(git rev-parse does-not-exist 2>&1 || true)" "unknown revision"
}

##############################################
# Test git rev-parse with a non-existent sha
##############################################
function git::rev_parse_non_existent_sha() {
    mkdir repo
    pushd repo >/dev/null
    git init -b main

    # As long as it tastes like a SHA, rev-parse is happy, but there is no
    # commit for it.
    assert_eq "$(git rev-parse 0123456789abcdef0123456789abcdef01234567)" "0123456789abcdef0123456789abcdef01234567"
    assert_substr "$(git rev-parse 0123456789abcdef0123456789abcdef01234567^{commit} 2>&1 || true)" "unknown revision"
    # Less-than-full SHAs do not work.
    assert_substr "$(git rev-parse 0123456789abcdef 2>&1 || true)" "unknown revision"
    assert_substr "$(git rev-parse 0123456789abcdef^{commit} 2>&1 || true)" "unknown revision"
}

#
# main
#

function list_tests() {
    (
        shopt -s extdebug
        declare -F \
            | cut -f3 -d' ' \
            | grep "^git::" \
            | while read X; do declare -F $X; done \
            | sort -n -k2 \
            | cut -f1 -d' ' \
            | sed 's/^git:://'
    )
}

# Figure out which, if any, tests to run.
all_tests=($(list_tests))
tests_to_run=()

function print_tests() {
    echo "available tests:"
    for t in "${all_tests[@]}"; do
        echo "    $t"
    done
}

# Validate and accumulate tests to run if args are specified.
for arg; do
    # Use -? to list known tests.
    if [[ "${arg}" == "-?" ]]; then
        print_tests
        exit 0
    fi
    if [[ "${arg}" =~ ^- ]]; then
        echo "ERROR: unknown flag '${arg}'"
        exit 1
    fi
    # Make sure each non-flag arg matches at least one test.
    nmatches=0
    for t in "${all_tests[@]}"; do
        if [[ "${t}" =~ ${arg} ]]; then
            nmatches=$((nmatches+1))
            # Don't run tests twice, just keep the first match.
            if [[ " ${tests_to_run[*]} " =~ " ${t} " ]]; then
                continue
            fi
            tests_to_run+=("${t}")
            continue
        fi
    done
    if [[ ${nmatches} == 0 ]]; then
        echo "ERROR: no tests match pattern '${arg}'"
        echo
        print_tests
        exit 1
    fi
    tests_to_run+=("${matches[@]}")
done
set -- "${tests_to_run[@]}"

# If no tests were specified, run them all.
if [[ "$#" == 0 ]]; then
    set -- "${all_tests[@]}"
fi

function finish() {
  r=$?
  trap "" INT EXIT ERR
  if [[ $r != 0 ]]; then
    echo
    echo "the directory $DIR was not removed as it contains"\
         "log files useful for debugging"
  fi
  exit $r
}
trap finish INT EXIT ERR

echo
echo "test root is $DIR"
echo

# Run a test function and return its error code.  This is needed because POSIX
# dictates that `errexit` does not apply inside a function called in an `if`
# context.  But if we don't call it with `if`, then it terminates the whole
# test run as soon as one test fails.  So this jumps through hoops to let the
# individual test functions run outside of `if` and return a code in a
# variable.
#
# Args:
#  $1: the name of a variable to populate with the return code
#  $2+: the test function to run and optional args
function run_test() {
    retvar=$1
    shift

    declare -g "$retvar"
    local restore_opts=$(set +o)
    set +o errexit
    set +o nounset
    set +o pipefail
    (
        set -o errexit
        set -o nounset
        set -o pipefail
        "$@"
    )
    eval "$retvar=$?"
    eval "$restore_opts"
}

# Override local configs for predictability in this test.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# TODO: add a flag to run all the tests inside the git-sync container image
# Iterate over the chosen tests and run them.
FAILS=()
FINAL_RET=0
RUNS="${RUNS:-1}"
for t; do
    TEST_RET=0
    RUN=0
    while (( "${RUN}" < "${RUNS}" )); do
        clean_workdir

        pushd "$WORKDIR" >/dev/null

        sfx=""
        if (( "${RUNS}" > 1 )); then
            sfx=" ($((RUN+1))/${RUNS})"
        fi
        echo -n "testcase ${t}${sfx}: "

        # Set &3 for our own output, let testcases use &2 and &1.
        exec 3>&1

        # See comments on run_test for details.
        RUN_RET=0
        LOG="${DIR}/log.$t"
        run_test RUN_RET "git::${t}" >"${LOG}.${RUN}" 2>&1
        if [[ "$RUN_RET" == 0 ]]; then
            pass
        else
            TEST_RET=1
            if [[ "$RUN_RET" != 42 ]]; then
                echo "FAIL: unknown error"
            fi
        fi
        RUN=$((RUN+1))

        popd >/dev/null
    done
    if [[ "$TEST_RET" != 0 ]]; then
        FINAL_RET=1
        FAILS+=("$t  (log: ${LOG}.*)")
    fi
done
if [[ "$FINAL_RET" != 0 ]]; then
    echo
    echo "the following tests failed:"
    for f in "${FAILS[@]}"; do
        echo "    $f"
    done
    exit 1
fi

# Finally...
echo
if [[ "${CLEANUP:-}" == 0 ]]; then
    echo "leaving logs in $DIR"
else
    rm -rf "$DIR"
fi

