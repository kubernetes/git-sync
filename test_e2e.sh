#!/bin/bash
#
# Copyright 2016 The Kubernetes Authors.
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
    echo "FAIL: " "$@"
    remove_containers || true
    exit 1
}

function pass() {
    echo "PASS"
    remove_containers || true
}

function assert_link_exists() {
    if ! [[ -e "$1" ]]; then
        fail "$1 does not exist"
    fi
    if ! [[ -L "$1" ]]; then
        fail "$1 is not a symlink"
    fi
}

function assert_link_eq() {
    if [[ $(readlink "$1") == "$2" ]]; then
        return
    fi
    fail "link $1 does not point to '$2': $(readlink $1)"
}

function assert_file_exists() {
    if ! [[ -f "$1" ]]; then
        fail "$1 does not exist"
    fi
}

function assert_file_absent() {
    if [[ -f "$1" ]]; then
        fail "$1 exists"
    fi
}

function assert_file_eq() {
    if [[ $(cat "$1") == "$2" ]]; then
        return
    fi
    fail "file $1 does not contain '$2': $(cat $1)"
}

function assert_file_contains() {
    if grep -q "$2" "$1"; then
        return
    fi
    fail "file $1 does not contain '$2': $(cat $1)"
}

# Helper: run a docker container.
function docker_run() {
    docker run \
        -d \
        --rm \
        --label git-sync-e2e="$RUNID" \
        "$@"
    sleep 2 # wait for it to come up
}

# Helper: get the IP of a docker container.
function docker_ip() {
    if [[ -z "$1" ]]; then
        echo "usage: $0 <id>"
        return 1
    fi
    docker inspect "$1" | jq -r .[0].NetworkSettings.IPAddress
}

function docker_kill() {
    if [[ -z "$1" ]]; then
        echo "usage: $0 <id>"
        return 1
    fi
    docker kill "$1" >/dev/null
}

# DIR is the directory in which all this test's state lives.
RUNID="${RANDOM}${RANDOM}"
DIR="/tmp/git-sync-e2e.$RUNID"
mkdir "$DIR"

# WORK is temp space and in reset for each testcase.
WORK="$DIR/work"
function clean_work() {
    rm -rf "$WORK"
    mkdir -p "$WORK"
}

# REPO and REPO2 are the source repos under test.
REPO="$DIR/repo"
REPO2="${REPO}2"
MAIN_BRANCH="e2e-branch"
function init_repo() {
    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b "$MAIN_BRANCH"
    touch "$REPO"/file
    git -C "$REPO" add file
    git -C "$REPO" commit -aqm "init file"

    rm -rf "$REPO2"
    cp -r "$REPO" "$REPO2"
}

# ROOT is the volume (usually) used as --root.
ROOT="$DIR/root"
function clean_root() {
    rm -rf "$ROOT"
    mkdir -p "$ROOT"
}

# Init SSH for test cases.
DOT_SSH="$DIR/dot_ssh"
mkdir -p "$DOT_SSH"
ssh-keygen -f "$DOT_SSH/id_test" -P "" >/dev/null
cat "$DOT_SSH/id_test.pub" > "$DOT_SSH/authorized_keys"

SLOW_GIT_CLONE=/slow_git_clone.sh
SLOW_GIT_FETCH=/slow_git_fetch.sh
ASKPASS_GIT=/askpass_git.sh
EXECHOOK_COMMAND=/test_exechook_command.sh
EXECHOOK_COMMAND_FAIL=/test_exechook_command_fail.sh
EXECHOOK_COMMAND_SLEEPY=/test_exechook_command_with_sleep.sh
EXECHOOK_COMMAND_FAIL_SLEEPY=/test_exechook_command_fail_with_sleep.sh
RUNLOG="$DIR/runlog.exechook-fail-retry"
rm -f $RUNLOG
touch $RUNLOG

function GIT_SYNC() {
    #./bin/linux_amd64/git-sync "$@"
    docker run \
        -i \
        --rm \
        --label git-sync-e2e="$RUNID" \
        --network="host" \
        -u $(id -u):$(id -g) \
        -v "$ROOT":"$ROOT":rw \
        -v "$REPO":"$REPO":ro \
        -v "$REPO2":"$REPO2":ro \
        -v "$WORK":"$WORK":ro \
        -v "$(pwd)/slow_git_clone.sh":"$SLOW_GIT_CLONE":ro \
        -v "$(pwd)/slow_git_fetch.sh":"$SLOW_GIT_FETCH":ro \
        -v "$(pwd)/askpass_git.sh":"$ASKPASS_GIT":ro \
        -v "$(pwd)/test_exechook_command.sh":"$EXECHOOK_COMMAND":ro \
        -v "$(pwd)/test_exechook_command_fail.sh":"$EXECHOOK_COMMAND_FAIL":ro \
        -v "$(pwd)/test_exechook_command_with_sleep.sh":"$EXECHOOK_COMMAND_SLEEPY":ro \
        -v "$(pwd)/test_exechook_command_fail_with_sleep.sh":"$EXECHOOK_COMMAND_FAIL_SLEEPY":ro \
        -v "$RUNLOG":/var/log/runs \
        -v "$DOT_SSH/id_test":"/etc/git-secret/ssh":ro \
        --env XDG_CONFIG_HOME=$DIR \
        e2e/git-sync:$(make -s version)__$(go env GOOS)_$(go env GOARCH) \
            --add-user \
            --v=5 \
            "$@"
}

function remove_containers() {
    sleep 2 # Let docker finish saving container metadata
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker kill "$CTR" >/dev/null
        done
}

#
# After all the test functions are defined, we can iterate over them and run
# them all automatically.  See the end of this file.
#

##############################################
# Test HEAD one-time
##############################################
function e2e::head_once() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test non-zero exit
##############################################
function e2e::non_zero_exit() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    (
        set +o errexit
        GIT_SYNC \
            --one-time \
            --repo="file://$REPO" \
            --branch="$MAIN_BRANCH" \
            --rev=does-not-exit \
            --root="$ROOT" \
            --dest="link" \
            >> "$1" 2>&1
        RET=$?
        if [[ "$RET" != 1 ]]; then
            fail "expected exit code 1, got $RET"
        fi
        assert_file_absent "$ROOT"/link
        assert_file_absent "$ROOT"/link/file
    )
}

##############################################
# Test HEAD one-time with an absolute-path link
##############################################
function e2e::absolute_dest() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT/root" \
        --dest="$ROOT/other/dir/link" \
        >> "$1" 2>&1
    assert_file_absent "$ROOT"/root/link
    assert_link_exists "$ROOT"/other/dir/link
    assert_file_exists "$ROOT"/other/dir/link/file
    assert_file_eq "$ROOT"/other/dir/link/file "$FUNCNAME"
}

##############################################
# Test HEAD one-time with a subdir-path link
##############################################
function e2e::subdir_dest() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="other/dir/link" \
        >> "$1" 2>&1
    assert_file_absent "$ROOT"/link
    assert_link_exists "$ROOT"/other/dir/link
    assert_file_exists "$ROOT"/other/dir/link/file
    assert_file_eq "$ROOT"/other/dir/link/file "$FUNCNAME"
}

##############################################
# Test default syncing (master)
##############################################
function e2e::default_sync_master() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" checkout -q -b master

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Move forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"

    # Move backward
    git -C "$REPO" reset -q --hard HEAD^
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test HEAD syncing
##############################################
function e2e::head_sync() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test worktree-cleanup
##############################################
function e2e::worktree_cleanup() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --wait=10 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 4
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"

    # second commit
    echo "$FUNCNAME-ok" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"
    REV=$(git -C "$REPO" rev-list -n1 HEAD)
    git -C "$REPO" worktree add -q "$ROOT"/"$REV" -b e2e --no-checkout
    sleep 10
    assert_file_exists "$ROOT"/link/file2
    assert_file_eq "$ROOT"/link/file2 "$FUNCNAME-ok"
}

##############################################
# Test readlink
##############################################
function e2e::readlink() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_link_eq "$ROOT"/link $(git -C "$REPO" rev-parse HEAD)

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_link_eq "$ROOT"/link $(git -C "$REPO" rev-parse HEAD)

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_link_eq "$ROOT"/link $(git -C "$REPO" rev-parse HEAD)
}

##############################################
# Test branch syncing
##############################################
function e2e::branch_sync() {
    OTHER_BRANCH="other-branch"
    # First sync
    git -C "$REPO" checkout -q -b "$OTHER_BRANCH"
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" checkout -q "$MAIN_BRANCH"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$OTHER_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Add to the branch.
    git -C "$REPO" checkout -q "$OTHER_BRANCH"
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    git -C "$REPO" checkout -q "$MAIN_BRANCH"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"

    # Move the branch backward
    git -C "$REPO" checkout -q "$OTHER_BRANCH"
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" checkout -q "$MAIN_BRANCH"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test switching branch after depth=1 checkout
##############################################
function e2e::branch_switch() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --depth=1 \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"

    OTHER_BRANCH="${MAIN_BRANCH}2"
    git -C "$REPO" checkout -q -b "$OTHER_BRANCH"
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$OTHER_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"
}

##############################################
# Test tag syncing
##############################################
function e2e::tag_sync() {
    TAG="e2e-tag"

    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" tag -f "$TAG" >/dev/null

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$TAG" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Add something and move the tag forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    git -C "$REPO" tag -f "$TAG" >/dev/null
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"

    # Move the tag backward
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" tag -f "$TAG" >/dev/null
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Add something after the tag
    echo "$FUNCNAME 3" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test tag syncing with annotated tags
##############################################
function e2e::tag_sync_annotated() {
    TAG="e2e-tag"

    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" tag -af "$TAG" -m "$FUNCNAME 1" >/dev/null

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$TAG" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Add something and move the tag forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    git -C "$REPO" tag -af "$TAG" -m "$FUNCNAME 2" >/dev/null
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"

    # Move the tag backward
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" tag -af "$TAG" -m "$FUNCNAME 3" >/dev/null
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Add something after the tag
    echo "$FUNCNAME 3" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test rev syncing
##############################################
function e2e::rev_sync() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    REV=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$REV" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Commit something new
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Revert the last change
    git -C "$REPO" reset -q --hard HEAD^
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test rev-sync one-time
##############################################
function e2e::rev_once() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    REV=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$REV" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test syncing after a crash
##############################################
function e2e::crash_cleanup_retry() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Corrupt it
    rm -f "$ROOT"/link

    # Try again
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test changing repos with storage intact
##############################################
function e2e::change_repos_after_sync() {
    # Prepare first repo
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    # First sync
    GIT_SYNC \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --one-time \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Prepare other repo
    echo "$FUNCNAME 2" > "$REPO2"/file
    git -C "$REPO2" commit -qam "$FUNCNAME 2"

    # Now sync the other repo
    GIT_SYNC \
        --repo="file://$REPO2" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --one-time \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"
}

##############################################
# Test sync loop timeout
##############################################
function e2e::sync_loop_timeout() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --git="$SLOW_GIT_CLONE" \
        --one-time \
        --timeout=1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 || true
    # check for failure
    assert_file_absent "$ROOT"/link/file

    # run with slow_git but without timing out
    GIT_SYNC \
        --git="$SLOW_GIT_CLONE" \
        --wait=0.1 \
        --timeout=16 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 10
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # Move forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 10
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"
}

##############################################
# Test depth syncing
##############################################
function e2e::depth() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    expected_depth="1"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
    depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi

    # Move forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"
    depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "forward depth mismatch expected=$expected_depth actual=$depth"
    fi

    # Move backward
    git -C "$REPO" reset -q --hard HEAD^
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
    depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "backward depth mismatch expected=$expected_depth actual=$depth"
    fi
}

##############################################
# Test fetch skipping commit
##############################################
function e2e::fetch_skip_depth_1() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --git="$SLOW_GIT_FETCH" \
        --wait=0.1 \
        --depth=1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &

    # wait for first sync which does a clone followed by an artifically slowed fetch
    sleep 8
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"

    # make a second commit to trigger a sync with shallow fetch
    echo "$FUNCNAME-ok" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"

    # Give time for ls-remote to detect the commit and slowed fetch to start
    sleep 2

    # make a third commit to insert the commit between ls-remote and fetch
    echo "$FUNCNAME-ok" > "$REPO"/file3
    git -C "$REPO" add file3
    git -C "$REPO" commit -qam "$FUNCNAME third file"
    sleep 10
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file3
    assert_file_eq "$ROOT"/link/file3 "$FUNCNAME-ok"
}

##############################################
# Test password
##############################################
function e2e::password() {
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    # run with askpass_git but with wrong password
    GIT_SYNC \
        --git="$ASKPASS_GIT" \
        --username="my-username" \
        --password="wrong" \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 || true
    # check for failure
    assert_file_absent "$ROOT"/link/file

    # run with askpass_git with correct password
    GIT_SYNC \
        --git="$ASKPASS_GIT" \
        --username="my-username" \
        --password="my-password" \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test askpass-url
##############################################
function e2e::askpass_url() {
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    # run the askpass-url service with wrong password
    CTR=$(docker_run \
        e2e/test/test-ncsvr \
        80 'echo -e "HTTP/1.1 200 OK\r\n\r\nusername=my-username\npassword=wrong"')
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --git="$ASKPASS_GIT" \
        --askpass-url="http://$IP/git_askpass" \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 || true
    docker_kill "$CTR"
    # check for failure
    assert_file_absent "$ROOT"/link/file

    # run with askpass_url service with correct password
    CTR=$(docker_run \
        e2e/test/test-ncsvr \
        80 'echo -e "HTTP/1.1 200 OK\r\n\r\nusername=my-username\npassword=my-password"')
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --git="$ASKPASS_GIT" \
        --askpass-url="http://$IP/git_askpass" \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    docker_kill "$CTR"
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
}

##############################################
# Test exechook-success
##############################################
function e2e::exechook_success() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --exechook-command="$EXECHOOK_COMMAND" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/exechook
    assert_file_exists "$ROOT"/link/link-exechook
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
    assert_file_eq "$ROOT"/link/exechook "$FUNCNAME 1"
    assert_file_eq "$ROOT"/link/link-exechook "$FUNCNAME 1"

    # Move forward
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/exechook
    assert_file_exists "$ROOT"/link/link-exechook
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 2"
    assert_file_eq "$ROOT"/link/exechook "$FUNCNAME 2"
    assert_file_eq "$ROOT"/link/link-exechook "$FUNCNAME 2"
}

##############################################
# Test exechook-fail-retry
##############################################
function e2e::exechook_fail_retry() {
    cat /dev/null > "$RUNLOG"
    # First sync - return a failure to ensure that we try again
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --exechook-command="$EXECHOOK_COMMAND_FAIL" \
        --exechook-backoff=1s \
        >> "$1" 2>&1 &
    # Check that exechook was called
    sleep 5
    RUNS=$(cat "$RUNLOG" | wc -l)
    if [[ "$RUNS" < 2 ]]; then
        fail "exechook called $RUNS times, it should be at least 2"
    fi
}

##############################################
# Test exechook-success with GIT_SYNC_ONE_TIME
##############################################
function e2e::exechook_success_once() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --exechook-command="$EXECHOOK_COMMAND_SLEEPY" \
        >> "$1" 2>&1

    sleep 2
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/exechook
    assert_file_exists "$ROOT"/link/link-exechook
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
    assert_file_eq "$ROOT"/link/exechook "$FUNCNAME 1"
    assert_file_eq "$ROOT"/link/link-exechook "$FUNCNAME 1"
}

##############################################
# Test exechook-fail with GIT_SYNC_ONE_TIME
##############################################
function e2e::exechook_fail_once() {
    cat /dev/null > "$RUNLOG"

    # First sync - return a failure to ensure that we try again
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --exechook-command="$EXECHOOK_COMMAND_FAIL_SLEEPY" \
        --exechook-backoff=1s \
        >> "$1" 2>&1

    # Check that exechook was called
    sleep 2
    RUNS=$(cat "$RUNLOG" | wc -l)
    if [[ "$RUNS" != 1 ]]; then
        fail "exechook called $RUNS times, it should be at exactly 1"
    fi
}

##############################################
# Test webhook success
##############################################
function e2e::webhook_success() {
    HITLOG="$WORK/hitlog"

    # First sync
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/test-ncsvr \
        80 'echo -e "HTTP/1.1 200 OK\r\n"')
    IP=$(docker_ip "$CTR")
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --dest="link" \
        >> "$1" 2>&1 &

    # check that basic call works
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" < 1 ]]; then
        fail "webhook 1 called $HITS times"
    fi

    # Move forward
    cat /dev/null > "$HITLOG"
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"

    # check that another call works
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" < 1 ]]; then
        fail "webhook 2 called $HITS times"
    fi
    docker_kill "$CTR"
}

##############################################
# Test webhook fail-retry
##############################################
function e2e::webhook_fail_retry() {
    HITLOG="$WORK/hitlog"

    # First sync - return a failure to ensure that we try again
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/test-ncsvr \
        80 'echo -e "HTTP/1.1 500 Internal Server Error\r\n"')
    IP=$(docker_ip "$CTR")
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --dest="link" \
        >> "$1" 2>&1 &

    # Check that webhook was called
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" < 1 ]]; then
        fail "webhook 1 called $HITS times"
    fi
    docker_kill "$CTR"

    # Now return 200, ensure that it gets called
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        --ip="$IP" \
        -v "$HITLOG":/var/log/hits \
        e2e/test/test-ncsvr \
        80 'echo -e "HTTP/1.1 200 OK\r\n"')
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" < 1 ]]; then
        fail "webhook 2 called $HITS times"
    fi
    docker_kill "$CTR"
}

##############################################
# Test webhook success with --one-time
##############################################
function e2e::webhook_success_once() {
    HITLOG="$WORK/hitlog"

    # First sync
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/test-ncsvr \
        80 'sleep 3 && echo -e "HTTP/1.1 200 OK\r\n"')
    IP=$(docker_ip "$CTR")
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --dest="link" \
        >> "$1" 2>&1

    # check that basic call works
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" != 1 ]]; then
        fail "webhook called $HITS times"
    fi

    docker_kill "$CTR"
}

##############################################
# Test webhook fail with --one-time
##############################################
function e2e::webhook_fail_retry_once() {
    HITLOG="$WORK/hitlog"

    # First sync - return a failure to ensure that we try again
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/test-ncsvr \
        80 'sleep 3 && echo -e "HTTP/1.1 500 Internal Server Error\r\n"')
    IP=$(docker_ip "$CTR")
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --dest="link" \
        >> "$1" 2>&1

    # Check that webhook was called
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" != 1 ]]; then
        fail "webhook called $HITS times"
    fi
    docker_kill "$CTR"
}

##############################################
# Test webhook fire-and-forget
##############################################
function e2e::webhook_fire_and_forget() {
    HITLOG="$WORK/hitlog"

    # First sync
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/test-ncsvr \
        80 'echo -e "HTTP/1.1 404 Not Found\r\n"')
    IP=$(docker_ip "$CTR")

    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=-1 \
        --dest="link" \
        >> "$1" 2>&1 &

    # check that basic call works
    sleep 2
    HITS=$(cat "$HITLOG" | wc -l)
    if [[ "$HITS" < 1 ]]; then
        fail "webhook called $HITS times"
    fi
    docker_kill "$CTR"
}

##############################################
# Test http handler
##############################################
function e2e::http() {
    BINDPORT=8888

    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --git="$SLOW_GIT_CLONE" \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --http-bind=":$BINDPORT" \
        --http-metrics \
        --http-pprof \
        --dest="link" \
        >> "$1" 2>&1 &
    # do nothing, just wait for the HTTP to come up
    for i in $(seq 1 5); do
        sleep 1
        if curl --silent --output /dev/null http://localhost:$BINDPORT; then
            break
        fi
        if [[ "$i" == 5 ]]; then
            fail "HTTP server failed to start"
        fi
    done

    # check that health endpoint fails
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT) -ne 503 ]] ; then
        fail "health endpoint should have failed: $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT)"
    fi
    sleep 2
    # check that health endpoint is alive
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT) -ne 200 ]] ; then
        fail "health endpoint failed"
    fi
    # check that the metrics endpoint exists
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT/metrics) -ne 200 ]] ; then
        fail "metrics endpoint failed"
    fi
    # check that the pprof endpoint exists
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT/debug/pprof/) -ne 200 ]] ; then
        fail "pprof endpoint failed"
    fi
}

##############################################
# Test http handler after restart
##############################################
function e2e::http_after_restart() {
    BINDPORT=8888

    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    # Sync once to set up the repo
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"

    # Sync again and prove readiness.
    GIT_SYNC \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --http-bind=":$BINDPORT" \
        --dest="link" \
        >> "$1" 2>&1 &
    # do nothing, just wait for the HTTP to come up
    for i in $(seq 1 5); do
        sleep 1
        if curl --silent --output /dev/null http://localhost:$BINDPORT; then
            break
        fi
        if [[ "$i" == 5 ]]; then
            fail "HTTP server failed to start"
        fi
    done

    sleep 2
    # check that health endpoint is alive
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT) -ne 200 ]] ; then
        fail "health endpoint failed"
    fi
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test submodule sync
##############################################
function e2e::submodule_sync() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$WORK/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
    git -C "$NESTED_SUBMODULE" add nested-submodule
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"

    # Add submodule
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "submodule"

    # Make change in submodule repo
    echo "$FUNCNAME 2" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" commit -qam "$FUNCNAME 2"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$FUNCNAME 2"

    # Move backward in submodule repo
    git -C "$SUBMODULE" reset -q --hard HEAD^
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "submodule"

    # Add nested submodule to submodule repo
    git -C "$SUBMODULE" submodule add -q file://$NESTED_SUBMODULE
    git -C "$SUBMODULE" commit -aqm "add nested submodule"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 4"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule "nested-submodule"

    # Remove nested submodule
    git -C "$SUBMODULE" submodule deinit -q $NESTED_SUBMODULE_REPO_NAME
    rm -rf "$SUBMODULE"/.git/modules/$NESTED_SUBMODULE_REPO_NAME
    git -C "$SUBMODULE" rm -qf $NESTED_SUBMODULE_REPO_NAME
    git -C "$SUBMODULE" commit -aqm "delete nested submodule"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 5"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule

    # Remove submodule
    git -C "$REPO" submodule deinit -q $SUBMODULE_REPO_NAME
    rm -rf "$REPO"/.git/modules/$SUBMODULE_REPO_NAME
    git -C "$REPO" rm -qf $SUBMODULE_REPO_NAME
    git -C "$REPO" commit -aqm "delete submodule"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    rm -rf $SUBMODULE
    rm -rf $NESTED_SUBMODULE
}

##############################################
# Test submodules depth syncing
##############################################
function e2e::submodule_sync_depth() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -b "$MAIN_BRANCH" > /dev/null

    # First sync
    expected_depth="1"
    echo "$FUNCNAME 1" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "submodule $FUNCNAME 1"
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" config -f "$REPO"/.gitmodules submodule.$SUBMODULE_REPO_NAME.shallow true
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$FUNCNAME 1"
    depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $submodule_depth ]]; then
        fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi

    # Move forward
    echo "$FUNCNAME 2" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" commit -aqm "submodule $FUNCNAME 2"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$FUNCNAME 2"
    depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "forward depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $submodule_depth ]]; then
        fail "forward submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi

    # Move backward
    git -C "$SUBMODULE" reset -q --hard HEAD^
    git -C "$REPO" submodule update --recursive --remote  > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$FUNCNAME 1"
    depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
    if [[ $expected_depth != $submodule_depth ]]; then
        fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi
    rm -rf $SUBMODULE
}

##############################################
# Test submodules off
##############################################
function e2e::submodule_sync_off() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Add submodule
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --submodules=off \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    rm -rf $SUBMODULE
}

##############################################
# Test submodules shallow
##############################################
function e2e::submodule_sync_shallow() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$WORK/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
    git -C "$NESTED_SUBMODULE" add nested-submodule
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"
    git -C "$SUBMODULE" submodule add -q file://$NESTED_SUBMODULE
    git -C "$SUBMODULE" commit -aqm "add nested submodule"

    # Add submodule
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --submodules=shallow \
        --wait=0.1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
    assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule
    rm -rf $SUBMODULE
    rm -rf $NESTED_SUBMODULE
}

##############################################
# Test SSH
##############################################
function e2e::ssh() {
    echo "$FUNCNAME" > "$REPO"/file

    # Run a git-over-SSH server
    CTR=$(docker_run \
        -v "$DOT_SSH":/dot_ssh:ro \
        -v "$REPO":/src:ro \
        e2e/test/test-sshd)
    IP=$(docker_ip "$CTR")
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --ssh \
        --ssh-known-hosts=false \
        --repo="test@$IP:/src" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test sparse-checkout files
##############################################
function e2e::sparse_checkout() {
    echo "!/*" > "$WORK"/sparseconfig
    echo "!/*/" >> "$WORK"/sparseconfig
    echo "file2" >> "$WORK"/sparseconfig
    echo "$FUNCNAME" > "$REPO"/file
    echo "$FUNCNAME" > "$REPO"/file2
    mkdir "$REPO"/dir
    echo "$FUNCNAME" > "$REPO"/dir/file3
    git -C "$REPO" add file2
    git -C "$REPO" add dir
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        --sparse-checkout-file="$WORK/sparseconfig" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file2
    assert_file_absent "$ROOT"/link/file
    assert_file_absent "$ROOT"/link/dir/file3
    assert_file_absent "$ROOT"/link/dir
    assert_file_eq "$ROOT"/link/file2 "$FUNCNAME"
}

##############################################
# Test additional git configs
##############################################
function e2e::additional_git_configs() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        --git-config='http.postBuffer:10485760,sect.k1:"a val",sect.k2:another val' \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test export-error
##############################################
function e2e::export_error() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    (
        set +o errexit
        GIT_SYNC \
            --repo="file://$REPO" \
            --branch=does-not-exit \
            --root="$ROOT" \
            --dest="link" \
            --error-file="error.json" \
            >> "$1" 2>&1
        RET=$?
        if [[ "$RET" != 1 ]]; then
            fail "expected exit code 1, got $RET"
        fi
        assert_file_absent "$ROOT"/link
        assert_file_absent "$ROOT"/link/file
        assert_file_contains "$ROOT"/error.json "Remote branch does-not-exit not found in upstream origin"
    )

    # the error.json file should be removed if sync succeeds.
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --dest="link" \
        --error-file="error.json" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
    assert_file_absent "$ROOT"/error.json
}

##############################################
# Test github HTTPS
# TODO: it would be better if we set up a local HTTPS server
##############################################
function e2e::github_https() {
    GIT_SYNC \
        --one-time \
        --repo="https://github.com/kubernetes/git-sync" \
        --branch=master \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1
    assert_file_exists "$ROOT"/link/LICENSE
}

##############################################
# Test git-gc=auto
##############################################
function e2e::gc_auto() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        --git-gc="auto" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test git-gc=always
##############################################
function e2e::gc_always() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        --git-gc="always" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test git-gc=aggressive
##############################################
function e2e::gc_aggressive() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        --git-gc="aggressive" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test git-gc=off
##############################################
function e2e::gc_off() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        --git-gc="off" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

function list_tests() {
    (
        shopt -s extdebug
        declare -F \
            | cut -f3 -d' ' \
            | grep "^e2e::" \
            | while read X; do declare -F $X; done \
            | sort -n -k2 \
            | cut -f1 -d' ' \
            | sed 's/^e2e:://'
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

# Build it
make container REGISTRY=e2e VERSION=$(make -s version)
make test-tools REGISTRY=e2e

function finish() {
  r=$?
  trap "" INT EXIT
  if [[ $r != 0 ]]; then
    echo
    echo "the directory $DIR was not removed as it contains"\
         "log files useful for debugging"
  fi
  remove_containers
  exit $r
}
trap finish INT EXIT

echo
echo "test root is $DIR"
echo

# Iterate over the chosen tests and run them.
for t; do
    clean_root
    clean_work
    init_repo
    echo -n "testcase $t: "
    if "e2e::${t}" "${DIR}/log.$t"; then
        pass
    fi
done

# Finally...
echo
echo "cleaning up $DIR"
rm -rf "$DIR"
