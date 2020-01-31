#!/bin/bash

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

NCPORT=8888
function freencport() {
  while :; do
    NCPORT=$((RANDOM+2000))
    ss -lpn | grep -q ":$NCPORT " || break
  done
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
echo "test root is $DIR"

REPO="$DIR/repo"
function init_repo() {
    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
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
    echo "The directory $DIR was not removed as it contains"\
         "log files useful for debugging"
  fi
  remove_containers
}
trap finish INT EXIT

SLOW_GIT=/slow_git.sh
ASKPASS_GIT=/askpass_git.sh

function GIT_SYNC() {
    #./bin/linux_amd64/git-sync "$@"
    docker run \
        -i \
        --rm \
        --label git-sync-e2e="$RUNID" \
        --network="host" \
        -u $(id -u):$(id -g) \
        -v "$DIR":"$DIR":rw \
        -v "$(pwd)/slow_git.sh":"$SLOW_GIT":ro \
        -v "$(pwd)/askpass_git.sh":"$ASKPASS_GIT":ro \
        -v "$DOT_SSH/id_test":"/etc/git-secret/ssh":ro \
        --env XDG_CONFIG_HOME=$DIR \
        e2e/git-sync:$(make -s version)__$(go env GOOS)_$(go env GOARCH) \
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

##############################################
# Test HEAD one-time
##############################################
testcase "head-once"
# First sync
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
    --branch=master \
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
# Test default syncing
##############################################
testcase "default-sync"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --logtostderr \
    --v=5 \
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
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
    --branch=master \
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
# Test branch syncing
##############################################
testcase "branch-sync"
BRANCH="$TESTCASE"--BRANCH
# First sync
git -C "$REPO" checkout -q -b "$BRANCH"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" checkout -q master
GIT_SYNC \
    --logtostderr \
    --v=5 \
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
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the branch backward
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" checkout -q master
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
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
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
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
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
# Test cross-branch tag syncing
##############################################
testcase "cross-branch-tag-sync"
BRANCH="$TESTCASE"--BRANCH
TAG="$TESTCASE"--TAG
# First sync
git -C "$REPO" checkout -q -b "$BRANCH"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
git -C "$REPO" checkout -q master
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
    --rev="$TAG" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move the tag forward
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move the tag forward again
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 3" >/dev/null
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 3"
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
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
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
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
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
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
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
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
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
    --git="$SLOW_GIT" \
    --logtostderr \
    --v=5 \
    --one-time \
    --timeout=1 \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
# run with slow_git but without timing out
GIT_SYNC \
    --git="$SLOW_GIT" \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --timeout=16 \
    --repo="file://$REPO" \
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
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
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
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
    --branch=master \
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
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
    --branch=master \
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
freencport
git -C "$REPO" commit -qam "$TESTCASE 1"
# run the askpass_url service with wrong password
{ (
    for i in 1 2; do
        echo -e 'HTTP/1.1 200 OK\r\n\r\nusername=my-username\npassword=wrong' \
            | nc -N -l $NCPORT > /dev/null;
    done
  ) &
}
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --askpass-url="http://localhost:$NCPORT/git_askpass" \
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
# run with askpass_url service with correct password
{ (
    for i in 1 2; do
        echo -e 'HTTP/1.1 200 OK\r\n\r\nusername=my-username\npassword=my-password' \
            | nc -N -l $NCPORT > /dev/null;
    done
  ) &
}
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --askpass-url="http://localhost:$NCPORT/git_askpass" \
    --logtostderr \
    --v=5 \
    --one-time \
    --repo="file://$REPO" \
    --branch=master \
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
# Test webhook
##############################################
testcase "webhook"
freencport
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --webhook-url="http://127.0.0.1:$NCPORT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
# check that basic call works
{ (echo -e "HTTP/1.1 200 OK\r\n" | nc -q1 -l $NCPORT > /dev/null) &}
NCPID=$!
sleep 3
if kill -0 $NCPID > /dev/null 2>&1; then
    fail "webhook 1 not called, server still running"
fi
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
# return a failure to ensure that we try again
{ (echo -e "HTTP/1.1 500 Internal Server Error\r\n" | nc -q1 -l $NCPORT > /dev/null) &}
NCPID=$!
sleep 3
if kill -0 $NCPID > /dev/null 2>&1; then
    fail "webhook 2 not called, server still running"
fi
# Now return 200, ensure that it gets called
{ (echo -e "HTTP/1.1 200 OK\r\n" | nc -q1 -l $NCPORT > /dev/null) &}
NCPID=$!
sleep 3
if kill -0 $NCPID > /dev/null 2>&1; then
    fail "webhook 3 not called, server still running"
fi
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
    --git="$SLOW_GIT" \
    --logtostderr \
    --v=5 \
    --repo="file://$REPO" \
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

git -C "$SUBMODULE" init -q
echo "submodule" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "init submodule file"

# Init nested submodule repo
NESTED_SUBMODULE_REPO_NAME="nested-sub"
NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
mkdir "$NESTED_SUBMODULE"

git -C "$NESTED_SUBMODULE" init -q
echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
git -C "$NESTED_SUBMODULE" add nested-submodule
git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"

# Add submodule
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" commit -aqm "add submodule"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
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

git -C "$SUBMODULE" init > /dev/null

# First sync
expected_depth="1"
echo "$TESTCASE 1" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "submodule $TESTCASE 1"
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" config -f "$REPO"/.gitmodules submodule.$SUBMODULE_REPO_NAME.shallow true
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="file://$REPO" \
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
# Test SSH
##############################################
testcase "ssh"
echo "$TESTCASE" > "$REPO"/file
# Run a git-over-SSH server
CTR=$(docker run \
    -d \
    --rm \
    --label git-sync-e2e="$RUNID" \
    -v "$DOT_SSH":/dot_ssh:ro \
    -v "$REPO":/src:ro \
    e2e/test/test-sshd)
sleep 3 # wait for sshd to come up
IP=$(docker inspect "$CTR" | jq -r .[0].NetworkSettings.IPAddress)
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --one-time \
    --ssh \
    --ssh-known-hosts=false \
    --repo="test@$IP:/src" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

echo "cleaning up $DIR"
rm -rf "$DIR"
