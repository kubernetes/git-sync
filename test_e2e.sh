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

# #####################
# main
# #####################

# Build it
make container REGISTRY=e2e VERSION=$(make -s version)
make test-tools REGISTRY=e2e

RUNID="${RANDOM}${RANDOM}"
DIR=""
for i in $(seq 1 10); do
    DIR="/tmp/git-sync-e2e.$RUNID"
    mkdir "$DIR" && break
done
if [[ -z "$DIR" ]]; then
    echo "Failed to make a temp dir"
    exit 1
fi
echo
echo "test root is $DIR"
echo

REPO="$DIR/repo"
MAIN_BRANCH="e2e-branch"
function init_repo() {
    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b "$MAIN_BRANCH"
    touch "$REPO"/file
    git -C "$REPO" add file
    git -C "$REPO" commit -aqm "init file"
}

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

SLOW_GIT_CLONE=/slow_git_clone.sh
SLOW_GIT_FETCH=/slow_git_fetch.sh
ASKPASS_GIT=/askpass_git.sh
EXECHOOK_COMMAND=/test_exechook_command.sh
EXECHOOK_COMMAND_FAIL=/test_exechook_command_fail.sh
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
        -v "$DIR":"$DIR":rw \
        -v "$(pwd)/slow_git_clone.sh":"$SLOW_GIT_CLONE":ro \
        -v "$(pwd)/slow_git_fetch.sh":"$SLOW_GIT_FETCH":ro \
        -v "$(pwd)/askpass_git.sh":"$ASKPASS_GIT":ro \
        -v "$(pwd)/test_exechook_command.sh":"$EXECHOOK_COMMAND":ro \
        -v "$(pwd)/test_exechook_command_fail.sh":"$EXECHOOK_COMMAND_FAIL":ro \
        -v "$RUNLOG":/var/log/runs \
        -v "$DOT_SSH/id_test":"/etc/git-secret/ssh":ro \
        --env XDG_CONFIG_HOME=$DIR \
        e2e/git-sync:$(make -s version)__$(go env GOOS)_$(go env GOARCH) \
            -v=5 \
            --add-user \
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
# Test HEAD one-time when root doesn't exist
##############################################
function e2e::head_once_root_doesnt_exist() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    rm -rf "$ROOT" # remove the root to test
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test HEAD one-time when root exists and is empty
##############################################
function e2e::head_once_root_exists_empty() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test HEAD one-time with a weird --root flag
##############################################
function e2e::head_once_root_flag_is_weird() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="../../../../../$ROOT/../../../../../../$ROOT" \
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test HEAD one-time with a symlink in --root
##############################################
function e2e::head_once_root_flag_has_symlink() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    ln -s "$ROOT" "$DIR/rootlink" # symlink to test
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$DIR/rootlink" \
        --link="link" \
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
    ln -s "$ROOT" "$DIR/rootlink" # symlink to test
    (
        set +o errexit
        GIT_SYNC \
            --one-time \
            --repo="file://$REPO" \
            --branch="$MAIN_BRANCH" \
            --rev=does-not-exit \
            --root="$DIR/rootlink" \
            --link="link" \
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
# Test HEAD one-time when root is under a git repo
##############################################
function e2e::head_once_root_exists_but_is_not_git_root() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"

    # Make a parent dir that is a git repo.
    mkdir -p "$ROOT/subdir/root"
    date > "$ROOT/subdir/root/file" # so it is not empty
    git -C "$ROOT/subdir" init >/dev/null
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT/subdir/root" \
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/subdir/root/link
    assert_file_exists "$ROOT"/subdir/root/link/file
    assert_file_eq "$ROOT"/subdir/root/link/file "$FUNCNAME"
}

##############################################
# Test HEAD one-time when root fails sanity
##############################################
function e2e::head_once_root_exists_but_fails_sanity() {
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    SHA=$(git -C "$REPO" rev-parse HEAD)

    # Make an invalid git repo.
    mkdir -p "$ROOT"
    git -C "$ROOT" init >/dev/null
    echo "ref: refs/heads/nonexist" > "$ROOT/.git/HEAD"
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="HEAD" \
        --root="$ROOT" \
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

## FIXME: test when repo is valid git, but wrong remote
## FIXME: test when repo is valid git, but not ar ref we need
## FIXME: test when repo is valid git, and is already correct

##############################################
# Test default syncing (master)
##############################################
function e2e::default_sync_master() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" checkout -q -b master
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --dest="link" \
        >> "$1" 2>&1 &

    # wait for first sync
    sleep 3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker pause "$CTR" >/dev/null
        done

    # make a second commit
    echo "$FUNCNAME-ok" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"

    # make a worktree to collide with git-sync
    REV=$(git -C "$REPO" rev-list -n1 HEAD)
    git -C "$REPO" worktree add -q "$ROOT"/"$REV" -b e2e --no-checkout

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker unpause "$CTR" >/dev/null
        done

    sleep 3
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$OTHER_BRANCH" \
        --root="$ROOT" \
        --link="link" \
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
    # First sync
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --depth=1 \
        --root="$ROOT" \
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
    OTHER_BRANCH="${MAIN_BRANCH}2"
    git -C "$REPO" checkout -q -b $OTHER_BRANCH
    echo "$FUNCNAME 2" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch=$OTHER_BRANCH \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$TAG" \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$TAG" \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$REV" \
        --root="$ROOT" \
        --link="link" \
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
    # First sync
    echo "$FUNCNAME" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    REV=$(git -C "$REPO" rev-list -n1 HEAD)
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev="$REV" \
        --root="$ROOT" \
        --link="link" \
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
        --link="link" \
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
        --link="link" \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"
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
        --sync-timeout=1s \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
        >> "$1" 2>&1 || true

    # check for failure
    assert_file_absent "$ROOT"/link/file

    # run with slow_git_clone but without timing out
    GIT_SYNC \
        --git="$SLOW_GIT_CLONE" \
        --period=100ms \
        --sync-timeout=16s \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --depth=1 \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
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
        --link="link" \
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
        --link="link" \
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

    # run the askpass_url service with wrong password
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
        --link="link" \
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
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
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
# Test webhook success
##############################################
function e2e::webhook_success() {
    HITLOG="$DIR/hitlog"

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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --link="link" \
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
    HITLOG="$DIR/hitlog"

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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --link="link" \
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
# Test webhook fire-and-forget
##############################################
function e2e::webhook_fire_and_forget() {
    HITLOG="$DIR/hitlog"

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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=-1 \
        --link="link" \
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --http-bind=":$BINDPORT" \
        --http-metrics \
        --http-pprof \
        --link="link" \
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
# Test submodule sync
##############################################
function e2e::submodule_sync() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
    git -C "$NESTED_SUBMODULE" add nested-submodule
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"

    # Add submodule
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" commit -aqm "add submodule"
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
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
    SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"

    # First sync
    expected_depth="1"
    echo "$FUNCNAME 1" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "submodule $FUNCNAME 1"
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" config -f "$REPO"/.gitmodules submodule.$SUBMODULE_REPO_NAME.shallow true
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --link="link" \
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
    SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Add submodule
    git -C "$REPO" submodule add -q file://$SUBMODULE
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
        --submodules=off \
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
    SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE"/submodule
    git -C "$SUBMODULE" add submodule
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
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
        --period=100ms \
        --repo="file://$REPO" \
        --branch="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
        --submodules=shallow \
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
        --repo="test@$IP:/src" \
        --branch="$MAIN_BRANCH" \
        --rev=HEAD \
        --root="$ROOT" \
        --link="link" \
        --ssh \
        --ssh-known-hosts=false \
        >> "$1" 2>&1
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME"
}

##############################################
# Test sparse-checkout files
##############################################
function e2e::sparse_checkout() {
    echo "!/*" > "$DIR"/sparseconfig
    echo "!/*/" >> "$DIR"/sparseconfig
    echo "file2" >> "$DIR"/sparseconfig
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
        --link="link" \
        --sparse-checkout-file="$DIR/sparseconfig" \
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
        --link="link" \
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
            --link="link" \
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
        --link="link" \
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

#
# main
#

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

# Iterate over all tests and run them.
tests=($(list_tests))

if [[ "$#" == 1 && "$1" == "-?" ]]; then
    echo "available tests:"
    for t in "${tests[@]}"; do
        echo "    $t"
    done
    exit 0
fi

if [[ "$#" == 0 ]]; then
    set -- "${tests[@]}"
fi

for t; do
    clean_root
    init_repo
    echo -n "testcase $t: "
    if "e2e::${t}" "${DIR}/log.$t"; then
         pass
    fi
done

# Finally...
echo
echo "all tests passed: cleaning up $DIR"
rm -rf "$DIR"
