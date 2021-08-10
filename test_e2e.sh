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

TESTCASE=""
function testcase() {
    clean_root
    init_repo
    echo -n "testcase $1: "
    TESTCASE="$1"
}

function fail() {
    echo "FAIL: " "$@"
    remove_containers || true
    exit 1
}

function pass() {
    echo "PASS"
    remove_containers || true
    TESTCASE=""
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
    if [ -z "$1" ]; then
        echo "usage: $0 <id>"
        return 1
    fi
    docker inspect "$1" | jq -r .[0].NetworkSettings.IPAddress
}

function docker_kill() {
    if [ -z "$1" ]; then
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
function init_repo() {
    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b e2e-branch
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
  if [ $? -ne 0 ]; then
    echo
    echo "the directory $DIR was not removed as it contains"\
         "log files useful for debugging"
  fi
  remove_containers
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

##############################################
# Test HEAD one-time
##############################################
testcase "head-once"
# First sync
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test non-zero exit
##############################################
testcase "non-zero-exit"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
ln -s "$ROOT" "$DIR/rootlink" # symlink to test
(
  set +o errexit
  GIT_SYNC \
      --one-time \
      --repo="file://$REPO" \
      --branch=e2e-branch \
      --rev=does-not-exit \
      --root="$DIR/rootlink" \
      --dest="link" \
      > "$DIR"/log."$TESTCASE" 2>&1
  RET=$?
  if [[ "$RET" != 1 ]]; then
      fail "expected exit code 1, got $RET"
  fi
  assert_file_absent "$ROOT"/link
  assert_file_absent "$ROOT"/link/file
)
# Wrap up
pass

##############################################
# Test default syncing (master)
##############################################
testcase "default-sync-master"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" checkout -q -b master
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test HEAD syncing
##############################################
testcase "head-sync"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move HEAD forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move HEAD backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test worktree-cleanup
##############################################
testcase "worktree-cleanup"

echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --wait=10 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &

# wait for first sync
sleep 4
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"

# second commit
echo "$TESTCASE-ok" > "$REPO"/file2
git -C "$REPO" add file2
git -C "$REPO" commit -qam "$TESTCASE new file"
REV=$(git -C "$REPO" rev-list -n1 HEAD)
git -C "$REPO" worktree add -q "$ROOT"/"$REV" -b e2e --no-checkout
sleep 10

assert_file_exists "$ROOT"/link/file2
assert_file_eq "$ROOT"/link/file2 "$TESTCASE-ok"
# Wrap up
pass

##############################################
# Test readlink
##############################################
testcase "readlink"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_link_eq "$ROOT"/link $(git -C "$REPO" rev-parse HEAD)
# Move HEAD forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_link_eq "$ROOT"/link $(git -C "$REPO" rev-parse HEAD)
# Move HEAD backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_link_eq "$ROOT"/link $(git -C "$REPO" rev-parse HEAD)
# Wrap up
pass

##############################################
# Test branch syncing
##############################################
testcase "branch-sync"
BRANCH="$TESTCASE"--BRANCH
# First sync
git -C "$REPO" checkout -q -b "$BRANCH"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" checkout -q e2e-branch
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch="$BRANCH" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add to the branch.
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" checkout -q e2e-branch
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the branch backward
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" checkout -q e2e-branch
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test tag syncing
##############################################
testcase "tag-sync"
TAG="$TESTCASE"--TAG
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -f "$TAG" >/dev/null
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev="$TAG" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something and move the tag forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -f "$TAG" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -f "$TAG" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test tag syncing with annotated tags
##############################################
testcase "tag-sync-annotated"
TAG="$TESTCASE"--TAG
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev="$TAG" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something and move the tag forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 2" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 3" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test rev syncing
##############################################
testcase "rev-sync"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
REV=$(git -C "$REPO" rev-list -n1 HEAD)
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev="$REV" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Commit something new
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Revert the last change
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test rev-sync one-time
##############################################
testcase "rev-once"
# First sync
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
REV=$(git -C "$REPO" rev-list -n1 HEAD)
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev="$REV" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test syncing after a crash
##############################################
testcase "crash-cleanup-retry"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Corrupt it
rm -f "$ROOT"/link
# Try again
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test sync loop timeout
##############################################
testcase "sync-loop-timeout"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --git="$SLOW_GIT_CLONE" \
    --one-time \
    --timeout=1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
# run with slow_git but without timing out
GIT_SYNC \
    --git="$SLOW_GIT_CLONE" \
    --wait=0.1 \
    --timeout=16 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 10
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 10
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Wrap up
pass

##############################################
# Test depth syncing
##############################################
testcase "depth"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
expected_depth="1"
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --depth="$expected_depth" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "initial depth mismatch expected=$expected_depth actual=$depth"
fi
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "forward depth mismatch expected=$expected_depth actual=$depth"
fi
# Move backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "backward depth mismatch expected=$expected_depth actual=$depth"
fi
# Wrap up
pass

##############################################
# Test fetch skipping commit
##############################################
testcase "fetch-skip-depth-1"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --git="$SLOW_GIT_FETCH" \
    --wait=0.1 \
    --depth=1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &

# wait for first sync which does a clone followed by an artifically slowed fetch
sleep 8
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"

# make a second commit to trigger a sync with shallow fetch
echo "$TESTCASE-ok" > "$REPO"/file2
git -C "$REPO" add file2
git -C "$REPO" commit -qam "$TESTCASE new file"

# Give time for ls-remote to detect the commit and slowed fetch to start
sleep 2

# make a third commit to insert the commit between ls-remote and fetch
echo "$TESTCASE-ok" > "$REPO"/file3
git -C "$REPO" add file3
git -C "$REPO" commit -qam "$TESTCASE third file"
sleep 10
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file3
assert_file_eq "$ROOT"/link/file3 "$TESTCASE-ok"

pass

##############################################
# Test password
##############################################
testcase "password"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
# run with askpass_git but with wrong password
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --username="my-username" \
    --password="wrong" \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
# run with askpass_git with correct password
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --username="my-username" \
    --password="my-password" \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test askpass_url
##############################################
testcase "askpass_url"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
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
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
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
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1
docker_kill "$CTR"
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test exechook-success
##############################################
testcase "exechook-success"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    --exechook-command="$EXECHOOK_COMMAND" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/exechook
assert_file_exists "$ROOT"/link/link-exechook
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
assert_file_eq "$ROOT"/link/exechook "$TESTCASE 1"
assert_file_eq "$ROOT"/link/link-exechook "$TESTCASE 1"
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/exechook
assert_file_exists "$ROOT"/link/link-exechook
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
assert_file_eq "$ROOT"/link/exechook "$TESTCASE 2"
assert_file_eq "$ROOT"/link/link-exechook "$TESTCASE 2"
# Wrap up
pass

##############################################
# Test exechook-fail-retry
##############################################
testcase "exechook-fail-retry"
cat /dev/null > "$RUNLOG"
# First sync - return a failure to ensure that we try again
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    --exechook-command="$EXECHOOK_COMMAND_FAIL" \
    --exechook-command-backoff=1s \
    > "$DIR"/log."$TESTCASE" 2>&1 &
# Check that exechook was called
sleep 5
RUNS=$(cat "$RUNLOG" | wc -l)
if [ "$RUNS" -lt 2 ]; then
    fail "exechook called $RUNS times, it should be at least 2"
fi
pass

##############################################
# Test webhook success
##############################################
testcase "webhook-success"
HITLOG="$DIR/hitlog.$TESTCASE"
# First sync
cat /dev/null > "$HITLOG"
CTR=$(docker_run \
    -v "$HITLOG":/var/log/hits \
    e2e/test/test-ncsvr \
    80 'echo -e "HTTP/1.1 200 OK\r\n"')
IP=$(docker_ip "$CTR")
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --webhook-url="http://$IP" \
    --webhook-success-status=200 \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
# check that basic call works
sleep 2
HITS=$(cat "$HITLOG" | wc -l)
if [ "$HITS" -lt 1 ]; then
    fail "webhook 1 called $HITS times"
fi
# Move forward
cat /dev/null > "$HITLOG"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
# check that another call works
sleep 2
HITS=$(cat "$HITLOG" | wc -l)
if [ "$HITS" -lt 1 ]; then
    fail "webhook 2 called $HITS times"
fi
docker_kill "$CTR"
# Wrap up
pass

##############################################
# Test webhook fail-retry
##############################################
testcase "webhook-fail-retry"
HITLOG="$DIR/hitlog.$TESTCASE"
# First sync - return a failure to ensure that we try again
cat /dev/null > "$HITLOG"
CTR=$(docker_run \
    -v "$HITLOG":/var/log/hits \
    e2e/test/test-ncsvr \
    80 'echo -e "HTTP/1.1 500 Internal Server Error\r\n"')
IP=$(docker_ip "$CTR")
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --webhook-url="http://$IP" \
    --webhook-success-status=200 \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
# Check that webhook was called
sleep 2
HITS=$(cat "$HITLOG" | wc -l)
if [ "$HITS" -lt 1 ]; then
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
if [ "$HITS" -lt 1 ]; then
    fail "webhook 2 called $HITS times"
fi
docker_kill "$CTR"
# Wrap up
pass

##############################################
# Test webhook fire-and-forget
##############################################
testcase "webhook-fire-and-forget"
HITLOG="$DIR/hitlog.$TESTCASE"
# First sync
cat /dev/null > "$HITLOG"
CTR=$(docker_run \
    -v "$HITLOG":/var/log/hits \
    e2e/test/test-ncsvr \
    80 'echo -e "HTTP/1.1 404 Not Found\r\n"')
IP=$(docker_ip "$CTR")
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --webhook-url="http://$IP" \
    --webhook-success-status=-1 \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
# check that basic call works
sleep 2
HITS=$(cat "$HITLOG" | wc -l)
if [ "$HITS" -lt 1 ]; then
    fail "webhook called $HITS times"
fi
docker_kill "$CTR"
# Wrap up
pass

##############################################
# Test http handler
##############################################
testcase "http"
BINDPORT=8888
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --git="$SLOW_GIT_CLONE" \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --http-bind=":$BINDPORT" \
    --http-metrics \
    --http-pprof \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
while ! curl --silent --output /dev/null http://localhost:$BINDPORT; do
    # do nothing, just wait for the HTTP to come up
    true
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
# Wrap up
pass

##############################################
# Test submodule sync
##############################################
testcase "submodule-sync"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q -b e2e-branch
echo "submodule" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "init submodule file"

# Init nested submodule repo
NESTED_SUBMODULE_REPO_NAME="nested-sub"
NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
mkdir "$NESTED_SUBMODULE"

git -C "$NESTED_SUBMODULE" init -q -b e2e-branch
echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
git -C "$NESTED_SUBMODULE" add nested-submodule
git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"

# Add submodule
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" commit -aqm "add submodule"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "submodule"
# Make change in submodule repo
echo "$TESTCASE 2" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" commit -qam "$TESTCASE 2"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 2"
# Move backward in submodule repo
git -C "$SUBMODULE" reset -q --hard HEAD^
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "submodule"
# Add nested submodule to submodule repo
git -C "$SUBMODULE" submodule add -q file://$NESTED_SUBMODULE
git -C "$SUBMODULE" commit -aqm "add nested submodule"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 4"
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
git -C "$REPO" commit -qam "$TESTCASE 5"
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
# Wrap up
rm -rf $SUBMODULE
rm -rf $NESTED_SUBMODULE
pass

##############################################
# Test submodules depth syncing
##############################################
testcase "submodule-sync-depth"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -b e2e-branch > /dev/null

# First sync
expected_depth="1"
echo "$TESTCASE 1" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "submodule $TESTCASE 1"
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" config -f "$REPO"/.gitmodules submodule.$SUBMODULE_REPO_NAME.shallow true
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --depth="$expected_depth" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "initial depth mismatch expected=$expected_depth actual=$depth"
fi
submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
if [ $expected_depth != $submodule_depth ]; then
    fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
fi
# Move forward
echo "$TESTCASE 2" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" commit -aqm "submodule $TESTCASE 2"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 2"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "forward depth mismatch expected=$expected_depth actual=$depth"
fi
submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
if [ $expected_depth != $submodule_depth ]; then
    fail "forward submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
fi
# Move backward
git -C "$SUBMODULE" reset -q --hard HEAD^
git -C "$REPO" submodule update --recursive --remote  > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "initial depth mismatch expected=$expected_depth actual=$depth"
fi
submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
if [ $expected_depth != $submodule_depth ]; then
    fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
fi
# Wrap up
rm -rf $SUBMODULE
pass

##############################################
# Test submodules off
##############################################
testcase "submodule-sync-off"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q -b e2e-branch
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
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
rm -rf $SUBMODULE
pass

##############################################
# Test submodules shallow
##############################################
testcase "submodule-sync-shallow"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q -b e2e-branch
echo "submodule" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "init submodule file"
# Init nested submodule repo
NESTED_SUBMODULE_REPO_NAME="nested-sub"
NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
mkdir "$NESTED_SUBMODULE"

git -C "$NESTED_SUBMODULE" init -q -b e2e-branch
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
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule
rm -rf $SUBMODULE
rm -rf $NESTED_SUBMODULE
pass

##############################################
# Test SSH
##############################################
testcase "ssh"
echo "$TESTCASE" > "$REPO"/file
# Run a git-over-SSH server
CTR=$(docker_run \
    -v "$DOT_SSH":/dot_ssh:ro \
    -v "$REPO":/src:ro \
    e2e/test/test-sshd)
IP=$(docker_ip "$CTR")
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --one-time \
    --ssh \
    --ssh-known-hosts=false \
    --repo="test@$IP:/src" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test sparse-checkout files
##############################################
testcase "sparse-checkout"
echo "!/*" > "$DIR"/sparseconfig
echo "!/*/" >> "$DIR"/sparseconfig
echo "file2" >> "$DIR"/sparseconfig
echo "$TESTCASE" > "$REPO"/file
echo "$TESTCASE" > "$REPO"/file2
mkdir "$REPO"/dir
echo "$TESTCASE" > "$REPO"/dir/file3
git -C "$REPO" add file2
git -C "$REPO" add dir
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    --sparse-checkout-file="$DIR/sparseconfig" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file2
assert_file_absent "$ROOT"/link/file
assert_file_absent "$ROOT"/link/dir/file3
assert_file_absent "$ROOT"/link/dir
assert_file_eq "$ROOT"/link/file2 "$TESTCASE"
# Wrap up
pass

##############################################
# Test additional git configs
##############################################
testcase "additional-git-configs"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --branch=e2e-branch \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    --git-config='http.postBuffer:10485760,sect.k1:"a val",sect.k2:another val' \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test export-error
##############################################
testcase "export-error"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
(
  set +o errexit
  GIT_SYNC \
      --repo="file://$REPO" \
      --branch=does-not-exit \
      --root="$ROOT" \
      --dest="link" \
      --error-file="error.json" \
      > "$DIR"/log."$TESTCASE" 2>&1
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
    --branch=e2e-branch \
    --root="$ROOT" \
    --dest="link" \
    --error-file="error.json" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
assert_file_absent "$ROOT"/error.json
# Wrap up
pass

##############################################
# Test github HTTPS
# TODO: it would be better if we set up a local HTTPS server
##############################################
testcase "github-https"
GIT_SYNC \
    --one-time \
    --repo="https://github.com/kubernetes/git-sync" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_file_exists "$ROOT"/link/LICENSE
# Wrap up
pass

# Finally...
echo
echo "cleaning up $DIR"
rm -rf "$DIR"

