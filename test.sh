#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

DIR=""
for i in $(seq 1 10); do
    DIR="/tmp/git-sync-test.$RANDOM"
    mkdir "$DIR" && break
done
if [[ -z "$DIR" ]]; then
    echo "Failed to make a temp dir"
    exit 1
fi
echo "Test root is $DIR"

TESTCASE=""
function testcase() {
    clean_root
    echo -n "testcase $1: "
    TESTCASE="$1"
}

function fail() {
    echo "FAIL: " "$@"
    exit 1
}

function pass() {
    echo "PASS"
    TESTCASE=""
    git -C "$REPO" checkout -q master
}

function assert_link_exists() {
    if [[ -L "$1" ]]; then
        return
    fi
    fail "$1 does not exist or is not a symlink"
}

function assert_file_exists() {
    if [[ -f "$1" ]]; then
        return
    fi
    fail "$1 does not exist"
}

function assert_file_eq() {
    if [[ $(cat "$1") == "$2" ]]; then
        return
    fi
    fail "file $1 does contain '$2': $(cat $1)"
}

#########################
# main
#########################
REPO="$DIR/repo"
mkdir "$REPO"

ROOT="$DIR/root"
function clean_root() {
    rm -rf "$ROOT"
    mkdir "$ROOT"
}

# Init the temp repo.
TESTCASE=init
git -C "$REPO" init
touch "$REPO"/file
git -C "$REPO" add file
git -C "$REPO" commit -aqm "init file"

# Build git-sync
make >/dev/null
GIT_SYNC=./bin/git-sync-amd64

# Test HEAD one-time
testcase "head-once"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
$GIT_SYNC \
    --repo="$REPO" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    --one-time > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
pass

# Test default syncing
testcase "default-sync"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
$GIT_SYNC \
    --repo="$REPO" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
kill %1
pass

# Test HEAD syncing
testcase "head-sync"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
$GIT_SYNC \
    --repo="$REPO" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
kill %1
pass

# Test branch syncing
testcase "branch-sync"
git -C "$REPO" checkout -q -b mybranch
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
$GIT_SYNC \
    --repo="$REPO" \
    --branch=mybranch \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
kill %1
pass

# Test tag syncing
testcase "tag-sync"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -af "$TESTCASE" -m "$TESTCASE 1" >/dev/null
$GIT_SYNC \
    --repo="$REPO" \
    --rev="$TESTCASE" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -af "$TESTCASE" -m "$TESTCASE 2" >/dev/null
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -af "$TESTCASE" -m "$TESTCASE 3" >/dev/null
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
kill %1
pass

# Test rev syncing
testcase "rev-sync"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
$GIT_SYNC \
    --repo="$REPO" \
    --rev=$(git -C "$REPO" rev-list -n1 HEAD) \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
kill %1
pass

echo "Cleaning up $DIR"
rm -rf "$DIR"
