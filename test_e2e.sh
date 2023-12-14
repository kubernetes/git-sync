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

function caller() {
  local stack_skip=${1:-0}
  stack_skip=$((stack_skip + 1))
  if [[ ${#FUNCNAME[@]} -gt ${stack_skip} ]]; then
    local i
    for ((i=1 ; i <= ${#FUNCNAME[@]} - stack_skip ; i++))
    do
      local frame_no=$((i - 1 + stack_skip))
      local source_lineno=${BASH_LINENO[$((frame_no - 1))]}
      local funcname=${FUNCNAME[${frame_no}]}
      if [[ "$funcname" =~ 'e2e::' ]]; then
          echo "${source_lineno}"
      fi
    done
  fi
}

function fail() {
    echo "FAIL: line $(caller):" "$@" >&3
    return 42
}

function pass() {
    echo "PASS"
}

# $1: a file/dir name
# $2: max seconds to wait
function wait_for_file_exists() {
    local file=$1
    local ticks=$(($2*10)) # 100ms per tick

    while (( $ticks > 0 )); do
        if [[ -f "$file" ]]; then
            break
        fi
        sleep 0.1
        ticks=$(($ticks-1))
    done
}

function assert_link_exists() {
    if ! [[ -e "$1" ]]; then
        fail "$1 does not exist"
    fi
    if ! [[ -L "$1" ]]; then
        fail "$1 is not a symlink"
    fi
}

function assert_link_basename_eq() {
    if [[ $(basename $(readlink "$1")) == "$2" ]]; then
        return
    fi
    fail "$1 does not point to $2: $(readlink $1)"
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

function assert_file_eq() {
    if [[ $(cat "$1") == "$2" ]]; then
        return
    fi
    fail "$1 does not contain '$2': $(cat $1)"
}

function assert_file_contains() {
    if grep -q "$2" "$1"; then
        return
    fi
    fail "$1 does not contain '$2': $(cat $1)"
}

function assert_file_lines_eq() {
    N=$(cat "$1" | wc -l)
    if (( "$N" != "$2" )); then
        fail "$1 is not $2 lines: $N"
    fi
}

function assert_file_lines_ge() {
    N=$(cat "$1" | wc -l)
    if (( "$N" < "$2" )); then
        fail "$1 is not at least $2 lines: $N"
    fi
}

function assert_metric_eq() {
    local val
    val="$(curl --silent "http://localhost:$HTTP_PORT/metrics" \
        | grep "^$1 " \
        | awk '{print $NF}')"
    if [[ "${val}" == "$2" ]]; then
        return
    fi
    fail "metric $1 was expected to be '$2': ${val}"
}

function assert_fail() {
    (
        set +o errexit
        "$@"
        RET=$?
        if [[ "$RET" != 0 ]]; then
            return
        fi
        fail "expected non-zero exit code, got $RET"
    )
}

# Helper: run a docker container.
function docker_run() {
    RM="--rm"
    if [[ "${CLEANUP:-}" == 0 ]]; then
        RM=""
    fi
    docker run \
        -d \
        ${RM} \
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

function docker_signal() {
    if [[ -z "$1" || -z "$2" ]]; then
        echo "usage: $0 <id> <signal>"
        return 1
    fi
    docker kill "--signal=$2" "$1" >/dev/null
}

# E2E_TAG is the tag used for docker builds.  This is needed because docker
# tags are system-global, but one might have multiple repos checked out.
E2E_TAG=$(git rev-parse --show-toplevel | sed 's|/|_|g')

# Setting IMAGE forces the test to use a specific image instead of the current
# tree.
IMAGE="${IMAGE:-"e2e/git-sync:${E2E_TAG}__$(go env GOOS)_$(go env GOARCH)"}"

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
    arg="${1}"

    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b "$MAIN_BRANCH"
    echo "$arg" > "$REPO/file"
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
    chmod g+rwx "$ROOT"
}

# How long we wait for sync operations to happen between test steps, in seconds
MAXWAIT="${MAXWAIT:-3}"

# INTERLOCK is a file, under $ROOT, used to coordinate tests and syncs.
INTERLOCK="_sync_lock"
function wait_for_sync() {
    if [[ -z "$1" ]]; then
        echo "usage: $0 <max-wait-seconds>"
        return 1
    fi
    local path="$ROOT/$INTERLOCK"
    wait_for_file_exists "$path" "$1"
    rm -f "$path"
}

# Init SSH for test cases.
DOT_SSH="$DIR/dot_ssh"
for i in $(seq 1 3); do
    mkdir -p "$DOT_SSH/$i"
    ssh-keygen -f "$DOT_SSH/$i/id_test" -P "" >/dev/null
    cp -a "$DOT_SSH/$i/id_test" "$DOT_SSH/$i/id_local" # for outside-of-container use
    mkdir -p "$DOT_SSH/server/$i"
    cat "$DOT_SSH/$i/id_test.pub" > "$DOT_SSH/server/$i/authorized_keys"
done
# Allow files to be read inside containers running as a different UID.
# Note: this does not include the *.local forms.
chmod g+r "$DOT_SSH"/*/id_test* "$DOT_SSH"/server/*

TEST_TOOLS="_test_tools"
SLOW_GIT_FETCH="$TEST_TOOLS/git_slow_fetch.sh"
ASKPASS_GIT="$TEST_TOOLS/git_askpass.sh"
EXECHOOK_COMMAND="$TEST_TOOLS/exechook_command.sh"
EXECHOOK_COMMAND_FAIL="$TEST_TOOLS/exechook_command_fail.sh"
EXECHOOK_COMMAND_SLEEPY="$TEST_TOOLS/exechook_command_with_sleep.sh"
EXECHOOK_COMMAND_FAIL_SLEEPY="$TEST_TOOLS/exechook_command_fail_with_sleep.sh"
EXECHOOK_ENVKEY=ENVKEY
EXECHOOK_ENVVAL=envval
RUNLOG="$DIR/runlog"
rm -f "$RUNLOG"
touch "$RUNLOG"
chmod g+rw "$RUNLOG"
HTTP_PORT=9376
METRIC_GOOD_SYNC_COUNT='git_sync_count_total{status="success"}'
METRIC_FETCH_COUNT='git_fetch_count_total'

function GIT_SYNC() {
    #./bin/linux_amd64/git-sync "$@"
    RM="--rm"
    if [[ "${CLEANUP:-}" == 0 ]]; then
        RM=""
    fi
    docker run \
        -i \
        ${RM} \
        --label git-sync-e2e="$RUNID" \
        --network="host" \
        -u git-sync:$(id -g) `# rely on GID, triggering "dubious ownership"` \
        -v "$ROOT":"$ROOT":rw \
        -v "$REPO":"$REPO":ro \
        -v "$REPO2":"$REPO2":ro \
        -v "$WORK":"$WORK":ro \
        -v "$(pwd)/$TEST_TOOLS":"/$TEST_TOOLS":ro \
        --env "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL" \
        -v "$RUNLOG":/var/log/runs \
        -v "$DOT_SSH/1/id_test":"/ssh/secret.1":ro \
        -v "$DOT_SSH/2/id_test":"/ssh/secret.2":ro \
        -v "$DOT_SSH/3/id_test":"/ssh/secret.3":ro \
        "${IMAGE}" \
            -v=6 \
            --add-user \
            --group-write \
            --touch-file="$INTERLOCK" \
            --git-config='protocol.file.allow:always' \
            --http-bind=":$HTTP_PORT" \
            --http-metrics \
            --http-pprof \
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
# Test init when root doesn't exist
##############################################
function e2e::init_root_doesnt_exist() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT/subdir" \
        --link="link"
    assert_link_exists "$ROOT/subdir/link"
    assert_file_exists "$ROOT/subdir/link/file"
    assert_file_eq "$ROOT/subdir/link/file" "$FUNCNAME"
}

##############################################
# Test init when root exists and is empty
##############################################
function e2e::init_root_exists_empty() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test init with a weird --root flag
##############################################
function e2e::init_root_flag_is_weird() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="../../../../../$ROOT/../../../../../../$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test init with a symlink in --root
##############################################
function e2e::init_root_flag_has_symlink() {
    mkdir -p "$ROOT/subdir"
    ln -s "$ROOT/subdir" "$ROOT/rootlink" # symlink to test

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT/rootlink" \
        --link="link"
    assert_link_exists "$ROOT/subdir/link"
    assert_file_exists "$ROOT/subdir/link/file"
    assert_file_eq "$ROOT/subdir/link/file" "$FUNCNAME"
}

##############################################
# Test init when root is under a git repo
##############################################
function e2e::init_root_is_under_another_repo() {
    # Make a parent dir that is a git repo.
    mkdir -p "$ROOT/subdir/root"
    date > "$ROOT/subdir/root/file" # so it is not empty
    git -C "$ROOT/subdir" init -q

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT/subdir/root" \
        --link="link"
    assert_link_exists "$ROOT/subdir/root/link"
    assert_file_exists "$ROOT/subdir/root/link/file"
    assert_file_eq "$ROOT/subdir/root/link/file" "$FUNCNAME"
}

##############################################
# Test init when root fails sanity
##############################################
function e2e::init_root_fails_sanity() {
    # Make an invalid git repo.
    git -C "$ROOT" init -q
    echo "ref: refs/heads/nonexist" > "$ROOT/.git/HEAD"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test non-zero exit with a bad ref
##############################################
function e2e::bad_ref_non_zero_exit() {
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="file://$REPO" \
            --ref=does-not-exist \
            --root="$ROOT" \
            --link="link"
    assert_file_absent "$ROOT/link"
}

##############################################
# Test default ref syncing
##############################################
function e2e::sync_default_ref() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" checkout -q -b weird-name

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test HEAD syncing
##############################################
function e2e::sync_head() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref=HEAD \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test sync with an absolute-path link
##############################################
function e2e::sync_head_absolute_link() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref=HEAD \
        --root="$ROOT/root" \
        --link="$ROOT/other/dir/link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/root/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/root/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/root/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test sync with a subdir-path link
##############################################
function e2e::sync_head_subdir_link() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref=HEAD \
        --root="$ROOT" \
        --link="other/dir/link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test worktree-cleanup
##############################################
function e2e::worktree_cleanup() {
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &

    # wait for first sync
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker pause "$CTR" >/dev/null
        done

    # make a second commit
    echo "$FUNCNAME-ok" > "$REPO/file2"
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"

    # make a worktree to collide with git-sync
    SHA=$(git -C "$REPO" rev-list -n1 HEAD)
    git -C "$REPO" worktree add -q "$ROOT/.worktrees/$SHA" -b e2e --no-checkout
    chmod g+w "$ROOT/.worktrees/$SHA"

    # add some garbage
    mkdir -p "$ROOT/.worktrees/not_a_hash/subdir"
    touch "$ROOT/.worktrees/not_a_directory"

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker unpause "$CTR" >/dev/null
        done

    wait_for_sync "${MAXWAIT}"
    assert_file_exists "$ROOT/link/file2"
    assert_file_eq "$ROOT/link/file2" "$FUNCNAME-ok"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
    assert_file_absent "$ROOT/.worktrees/$SHA"
    assert_file_absent "$ROOT/.worktrees/not_a_hash"
    assert_file_absent "$ROOT/.worktrees/not_a_directory"
}

##############################################
# Test worktree unexpected removal
##############################################
function e2e::worktree_unexpected_removal() {
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &

    # wait for first sync
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker pause "$CTR" >/dev/null
        done

    # make a unexpected removal
    WT=$(git -C "$REPO" rev-list -n1 HEAD)
    rm -r "$ROOT/.worktrees/$WT"

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker unpause "$CTR" >/dev/null
        done

    echo "$METRIC_GOOD_SYNC_COUNT"

    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
}

##############################################
# Test syncing when the worktree is wrong hash
##############################################
function e2e::sync_recover_wrong_worktree_hash() {
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &

    # wait for first sync
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker pause "$CTR" >/dev/null
        done

    # Corrupt it
    echo "unexpected" > "$ROOT/link/file"
    git -C "$ROOT/link" commit -qam "corrupt it"

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker unpause "$CTR" >/dev/null
        done

    echo "$METRIC_GOOD_SYNC_COUNT"

    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
}

##############################################
# Test stale-worktree-timeout
##############################################
function e2e::stale_worktree_timeout() {
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    WT1=$(git -C "$REPO" rev-list -n1 HEAD)
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --stale-worktree-timeout="5s" \
        &

    # wait for first sync
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # wait 2 seconds and make another commit
    sleep 2
    echo "$FUNCNAME 2" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"
    WT2=$(git -C "$REPO" rev-list -n1 HEAD)

    # wait for second sync
    wait_for_sync "${MAXWAIT}"
    # at this point both WT1 and WT2 should exist, with
    # link pointing to the new WT2
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2

    # wait 2 seconds and make a third commit
    sleep 2
    echo "$FUNCNAME 3" > "$REPO"/file3
    git -C "$REPO" add file3
    git -C "$REPO" commit -qam "$FUNCNAME new file"
    WT3=$(git -C "$REPO" rev-list -n1 HEAD)

    wait_for_sync "${MAXWAIT}"

    # at this point WT1, WT2, WT3 should exist, with
    # link pointing to WT3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/link/file3
    assert_file_exists "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2
    assert_file_absent "$ROOT"/.worktrees/$WT1/file3
    assert_file_exists "$ROOT"/.worktrees/$WT2/file
    assert_file_exists "$ROOT"/.worktrees/$WT2/file2
    assert_file_absent "$ROOT"/.worktrees/$WT2/file3
    assert_file_exists "$ROOT"/.worktrees/$WT3/file
    assert_file_exists "$ROOT"/.worktrees/$WT3/file2
    assert_file_exists "$ROOT"/.worktrees/$WT3/file3

    # wait for WT1 to go stale
    sleep 4

    # now WT1 should be stale and deleted,
    # WT2 and WT3 should still exist
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/link/file3
    assert_file_absent "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2
    assert_file_absent "$ROOT"/.worktrees/$WT1/file3
    assert_file_exists "$ROOT"/.worktrees/$WT2/file
    assert_file_exists "$ROOT"/.worktrees/$WT2/file2
    assert_file_absent "$ROOT"/.worktrees/$WT2/file3
    assert_file_exists "$ROOT"/.worktrees/$WT3/file
    assert_file_exists "$ROOT"/.worktrees/$WT3/file2
    assert_file_exists "$ROOT"/.worktrees/$WT3/file3

    # wait for WT2 to go stale
    sleep 2

    # now both WT1 and WT2 are stale, WT3 should be the only
    # worktree left
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/link/file3
    assert_file_absent "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2
    assert_file_absent "$ROOT"/.worktrees/$WT1/file3
    assert_file_absent "$ROOT"/.worktrees/$WT2/file
    assert_file_absent "$ROOT"/.worktrees/$WT2/file2
    assert_file_absent "$ROOT"/.worktrees/$WT2/file3
    assert_file_exists "$ROOT"/.worktrees/$WT3/file
    assert_file_exists "$ROOT"/.worktrees/$WT3/file2
    assert_file_exists "$ROOT"/.worktrees/$WT3/file3
}

##############################################
# Test stale-worktree-timeout with restarts
##############################################
function e2e::stale_worktree_timeout_restart() {
    echo "$FUNCNAME 1" > "$REPO"/file
    git -C "$REPO" commit -qam "$FUNCNAME"
    WT1=$(git -C "$REPO" rev-list -n1 HEAD)
    GIT_SYNC \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --one-time

    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_eq "$ROOT"/link/file "$FUNCNAME 1"

    # wait 2 seconds and make another commit
    sleep 2
    echo "$FUNCNAME 2" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"
    WT2=$(git -C "$REPO" rev-list -n1 HEAD)

    # restart git-sync
    GIT_SYNC \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --stale-worktree-timeout="10s" \
            --one-time

    # at this point both WT1 and WT2 should exist, with
    # link pointing to the new WT2
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2

    # wait 2 seconds and make a third commit
    sleep 4
    echo "$FUNCNAME 3" > "$REPO"/file3
    git -C "$REPO" add file3
    git -C "$REPO" commit -qam "$FUNCNAME new file"
    WT3=$(git -C "$REPO" rev-list -n1 HEAD)

    # restart git-sync
    GIT_SYNC \
                --repo="file://$REPO" \
                --root="$ROOT" \
                --link="link" \
                --stale-worktree-timeout="10s" \
                --one-time

    # at this point WT1, WT2, WT3 should exist, with
    # link pointing to WT3
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/link/file3
    assert_file_exists "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2
    assert_file_absent "$ROOT"/.worktrees/$WT1/file3
    assert_file_exists "$ROOT"/.worktrees/$WT2/file
    assert_file_exists "$ROOT"/.worktrees/$WT2/file2
    assert_file_absent "$ROOT"/.worktrees/$WT2/file3
    assert_file_exists "$ROOT"/.worktrees/$WT3/file
    assert_file_exists "$ROOT"/.worktrees/$WT3/file2
    assert_file_exists "$ROOT"/.worktrees/$WT3/file3

    # wait for WT1 to go stale and restart git-sync
    sleep 8
    GIT_SYNC \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --stale-worktree-timeout="10s" \
            --one-time

    # now WT1 should be stale and deleted,
    # WT2 and WT3 should still exist
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/link/file3
    assert_file_absent "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2
    assert_file_absent "$ROOT"/.worktrees/$WT1/file3
    assert_file_exists "$ROOT"/.worktrees/$WT2/file
    assert_file_exists "$ROOT"/.worktrees/$WT2/file2
    assert_file_absent "$ROOT"/.worktrees/$WT2/file3
    assert_file_exists "$ROOT"/.worktrees/$WT3/file
    assert_file_exists "$ROOT"/.worktrees/$WT3/file2
    assert_file_exists "$ROOT"/.worktrees/$WT3/file3

    # wait for WT2 to go stale and restart git-sync
    sleep 4
    GIT_SYNC \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --stale-worktree-timeout="10s" \
            --one-time

    # now both WT1 and WT2 are stale, WT3 should be the only
    # worktree left
    assert_link_exists "$ROOT"/link
    assert_file_exists "$ROOT"/link/file
    assert_file_exists "$ROOT"/link/file2
    assert_file_exists "$ROOT"/link/file3
    assert_file_absent "$ROOT"/.worktrees/$WT1/file
    assert_file_absent "$ROOT"/.worktrees/$WT1/file2
    assert_file_absent "$ROOT"/.worktrees/$WT1/file3
    assert_file_absent "$ROOT"/.worktrees/$WT2/file
    assert_file_absent "$ROOT"/.worktrees/$WT2/file2
    assert_file_absent "$ROOT"/.worktrees/$WT2/file3
    assert_file_exists "$ROOT"/.worktrees/$WT3/file
    assert_file_exists "$ROOT"/.worktrees/$WT3/file2
    assert_file_exists "$ROOT"/.worktrees/$WT3/file3
}

##############################################
# Test v3->v4 upgrade
##############################################
function e2e::v3_v4_upgrade_in_place() {
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME"

    # sync once
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # simulate v3's worktrees
    WT="$(readlink "$ROOT/link")"
    SHA="$(basename "$WT")"
    mv -f "$ROOT/$WT" "$ROOT/$SHA"
    ln -sf "$SHA" "$ROOT/link"

    # make a second commit
    echo "$FUNCNAME 2" > "$REPO/file2"
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "$FUNCNAME new file"

    # sync again
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_file_exists "$ROOT/link/file2"
    assert_file_eq "$ROOT/link/file2" "$FUNCNAME 2"
    assert_file_absent "$ROOT/$SHA"
}

##############################################
# Test readlink
##############################################
function e2e::readlink() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_link_basename_eq "$ROOT/link" $(git -C "$REPO" rev-parse HEAD)

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_link_basename_eq "$ROOT/link" $(git -C "$REPO" rev-parse HEAD)

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_link_basename_eq "$ROOT/link" $(git -C "$REPO" rev-parse HEAD)
}

##############################################
# Test branch syncing
##############################################
function e2e::sync_branch() {
    OTHER_BRANCH="other-branch"

    # First sync
    git -C "$REPO" checkout -q -b "$OTHER_BRANCH"
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" checkout -q "$MAIN_BRANCH"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$OTHER_BRANCH" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Add to the branch.
    git -C "$REPO" checkout -q "$OTHER_BRANCH"
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    git -C "$REPO" checkout -q "$MAIN_BRANCH"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move the branch backward
    git -C "$REPO" checkout -q "$OTHER_BRANCH"
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" checkout -q "$MAIN_BRANCH"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test switching branch after depth=1 checkout
##############################################
function e2e::sync_branch_switch() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$MAIN_BRANCH" \
        --depth=1 \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    OTHER_BRANCH="${MAIN_BRANCH}2"
    git -C "$REPO" checkout -q -b $OTHER_BRANCH
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$OTHER_BRANCH" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test tag syncing
##############################################
function e2e::sync_tag() {
    TAG="e2e-tag"

    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" tag -f "$TAG" >/dev/null

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$TAG" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Add something and move the tag forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    git -C "$REPO" tag -f "$TAG" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move the tag backward
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" tag -f "$TAG" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3

    # Add something after the tag
    echo "$FUNCNAME 3" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test tag syncing with annotated tags
##############################################
function e2e::sync_annotated_tag() {
    TAG="e2e-tag"

    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    git -C "$REPO" tag -af "$TAG" -m "$FUNCNAME 1" >/dev/null

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$TAG" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Add something and move the tag forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    git -C "$REPO" tag -af "$TAG" -m "$FUNCNAME 2" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move the tag backward
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" tag -af "$TAG" -m "$FUNCNAME 3" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3

    # Add something after the tag
    echo "$FUNCNAME 3" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test SHA syncing
##############################################
function e2e::sync_sha() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    SHA=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$SHA" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Commit something new
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Revert the last change
    git -C "$REPO" reset -q --hard HEAD^
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1
}

##############################################
# Test SHA-sync one-time
##############################################
function e2e::sync_sha_once() {
    SHA=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$SHA" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test SHA-sync on a different SHA we already have
##############################################
function e2e::sync_sha_once_sync_different_sha_known() {
    # All revs will be known because we check out the branch
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    SHA1=$(git -C "$REPO" rev-list -n1 HEAD)
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    SHA2=$(git -C "$REPO" rev-list -n1 HEAD)
    echo "$FUNCNAME 3" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 3"

    # Sync SHA1
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$SHA1" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Sync SHA2
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$SHA2" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test SHA-sync on a different SHA we do not have
##############################################
function e2e::sync_sha_once_sync_different_sha_unknown() {
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    SHA1=$(git -C "$REPO" rev-list -n1 HEAD)

    # Sync SHA1
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$SHA1" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # The locally synced repo does not know this new SHA.
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    SHA2=$(git -C "$REPO" rev-list -n1 HEAD)
    # Make sure the SHA is not at HEAD, to prevent things that only work in
    # that case.
    echo "$FUNCNAME 3" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 3"

    # Sync SHA2
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$SHA2" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test syncing after a crash
##############################################
function e2e::sync_crash_no_link_cleanup_retry() {
    # First sync
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"

    # Corrupt it
    rm -f "$ROOT/link"

    # Try again
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test syncing after a crash
##############################################
function e2e::sync_crash_no_worktree_cleanup_retry() {
    # First sync
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"

    # Corrupt it
    rm -rf "$ROOT/.worktrees/"

    # Try again
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test changing repos with storage intact
##############################################
function e2e::sync_repo_switch() {
    # Prepare first repo
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    # First sync
    GIT_SYNC \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --one-time
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Prepare other repo
    echo "$FUNCNAME 2" > "$REPO2/file"
    git -C "$REPO2" commit -qam "$FUNCNAME 2"

    # Now sync the other repo
    GIT_SYNC \
        --repo="file://$REPO2" \
        --root="$ROOT" \
        --link="link" \
        --one-time
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test with slow git, short timeout
##############################################
function e2e::error_slow_git_short_timeout() {
    assert_fail \
        GIT_SYNC \
            --git="/$SLOW_GIT_FETCH" \
            --one-time \
            --sync-timeout=1s \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link"
    assert_file_absent "$ROOT/link/file"
}

##############################################
# Test with slow git, long timeout
##############################################
function e2e::sync_slow_git_long_timeout() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    # run with slow_git_clone but without timing out
    GIT_SYNC \
        --git="/$SLOW_GIT_FETCH" \
        --period=100ms \
        --sync-timeout=16s \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "$((MAXWAIT * 3))"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "$((MAXWAIT * 3))"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
}

##############################################
# Test sync-on-signal with SIGHUP
##############################################
function e2e::sync_on_signal_sighup() {
     # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100s \
        --sync-on-signal="SIGHUP" \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    # Send signal (note --period is 100s, signal should trigger sync)
    CTR=$(docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}")
    docker_signal "$CTR" SIGHUP
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test sync-on-signal with HUP
##############################################
function e2e::sync_on_signal_hup() {
     # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100s \
        --sync-on-signal="HUP" \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    # Send signal (note --period is 100s, signal should trigger sync)
    CTR=$(docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}")
    docker_signal "$CTR" SIGHUP
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test sync-on-signal with 1 (SIGHUP)
##############################################
function e2e::sync_on_signal_1() {
     # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100s \
        --sync-on-signal=1 \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    # Send signal (note --period is 100s, signal should trigger sync)
    CTR=$(docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}")
    docker_signal "$CTR" SIGHUP
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
}

##############################################
# Test depth default is shallow
##############################################
function e2e::sync_depth_default_shallow() {
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    echo "$FUNCNAME 3" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 3"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $depth != 1 ]]; then
        fail "expected depth 1, got $depth"
    fi
}

##############################################
# Test depth syncing across updates
##############################################
function e2e::sync_depth_across_updates() {
    # First sync
    expected_depth="1"
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "initial: expected depth $expected_depth, got $depth"
    fi

    # Move forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "forward: expected depth $expected_depth, got $depth"
    fi

    # Move backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "backward: expected depth $expected_depth, got $depth"
    fi
}

##############################################
# Test depth switching on back-to-back runs
##############################################
function e2e::sync_depth_change_on_restart() {
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    echo "$FUNCNAME 3" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 3"

    # Sync depth=1
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --depth=1 \
        --root="$ROOT" \
        --link="link"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $depth != 1 ]]; then
        fail "expected depth 1, got $depth"
    fi

    # Sync depth=2
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --depth=2 \
        --root="$ROOT" \
        --link="link"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $depth != 2 ]]; then
        fail "expected depth 2, got $depth"
    fi

    # Sync depth=1
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --depth=1 \
        --root="$ROOT" \
        --link="link"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $depth != 1 ]]; then
        fail "expected depth 1, got $depth"
    fi

    # Sync depth=0 (full)
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --depth=0 \
        --root="$ROOT" \
        --link="link"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $depth != 4 ]]; then
        fail "expected depth 4, got $depth"
    fi
}

##############################################
# Test HTTP basicauth with a password
##############################################
function e2e::auth_http_password() {
    # Run a git-over-HTTP server.
    CTR=$(docker_run \
        -v "$REPO":/git/repo:ro \
        e2e/test/httpd)
    IP=$(docker_ip "$CTR")

    # Try with wrong username
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://$IP/repo" \
            --root="$ROOT" \
            --link="link" \
            --username="wrong" \
            --password="testpass"
    assert_file_absent "$ROOT/link/file"

    # Try with wrong password
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://$IP/repo" \
            --root="$ROOT" \
            --link="link" \
            --username="testuser" \
            --password="wrong"
    assert_file_absent "$ROOT/link/file"

    # Try with the right password
    GIT_SYNC \
        --one-time \
        --repo="http://$IP/repo" \
        --root="$ROOT" \
        --link="link" \
        --username="testuser" \
        --password="testpass" \

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test HTTP basicauth with a password in the URL
##############################################
function e2e::auth_http_password_in_url() {
    # Run a git-over-HTTP server.
    CTR=$(docker_run \
        -v "$REPO":/git/repo:ro \
        e2e/test/httpd)
    IP=$(docker_ip "$CTR")

    # Try with wrong username
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://wrong:testpass@$IP/repo" \
            --root="$ROOT" \
            --link="link"
    assert_file_absent "$ROOT/link/file"

    # Try with wrong password
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://testuser:wrong@$IP/repo" \
            --root="$ROOT" \
            --link="link"
    assert_file_absent "$ROOT/link/file"

    # Try with the right password
    GIT_SYNC \
        --one-time \
        --repo="http://testuser:testpass@$IP/repo" \
        --root="$ROOT" \
        --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test HTTP basicauth with a password-file
##############################################
function e2e::auth_http_password_file() {
    # Run a git-over-HTTP server.
    CTR=$(docker_run \
        -v "$REPO":/git/repo:ro \
        e2e/test/httpd)
    IP=$(docker_ip "$CTR")

    # Make a password file with a bad password.
    echo -n "wrong" > "$WORK/password-file"

    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://$IP/repo" \
            --root="$ROOT" \
            --link="link" \
            --username="testuser" \
            --password-file="$WORK/password-file"
    assert_file_absent "$ROOT/link/file"

    # Make a password file the right password.
    echo -n "testpass" > "$WORK/password-file"

    GIT_SYNC \
        --one-time \
        --repo="http://$IP/repo" \
        --root="$ROOT" \
        --link="link" \
        --username="testuser" \
        --password-file="$WORK/password-file"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test SSH
##############################################
function e2e::auth_ssh() {
    # Run a git-over-SSH server.  Use key #3 to exercise the multi-key logic.
    CTR=$(docker_run \
        -v "$DOT_SSH/server/3":/dot_ssh:ro \
        -v "$REPO":/git/repo:ro \
        e2e/test/sshd)
    IP=$(docker_ip "$CTR")

    # Try to sync with key #1.
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="test@$IP:/git/repo" \
            --root="$ROOT" \
            --link="link" \
            --ssh-known-hosts=false \
            --ssh-key-file="/ssh/secret.2"
    assert_file_absent "$ROOT/link/file"

    # Try to sync with multiple keys
    GIT_SYNC \
        --one-time \
        --repo="test@$IP:/git/repo" \
        --root="$ROOT" \
        --link="link" \
        --ssh-known-hosts=false \
        --ssh-key-file="/ssh/secret.1" \
        --ssh-key-file="/ssh/secret.2" \
        --ssh-key-file="/ssh/secret.3"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test askpass-url with bad password
##############################################
function e2e::auth_askpass_url_wrong_password() {
    # run the askpass_url service with wrong password
    HITLOG="$WORK/hitlog"
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
            echo "username=my-username"
            echo "password=wrong"
            ')
    IP=$(docker_ip "$CTR")

    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --git="/$ASKPASS_GIT" \
            --askpass-url="http://$IP/git_askpass"
    assert_file_absent "$ROOT/link/file"
}

##############################################
# Test askpass-url
##############################################
function e2e::auth_askpass_url_correct_password() {
    # run with askpass_url service with correct password
    HITLOG="$WORK/hitlog"
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
            echo "username=my-username"
            echo "password=my-password"
            ')
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$IP/git_askpass"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test askpass-url where the URL is sometimes wrong
##############################################
function e2e::auth_askpass_url_sometimes_wrong() {
    # run with askpass_url service which alternates good/bad replies.
    HITLOG="$WORK/hitlog"
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
            if [ -f /tmp/flag ]; then
                echo "username=my-username"
                echo "password=my-password"
                rm /tmp/flag
            else
                echo "username=my-username"
                echo "password=wrong"
                touch /tmp/flag
            fi
            ')
    IP=$(docker_ip "$CTR")

    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$IP/git_askpass" \
        --max-failures=2 \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
}

##############################################
# Test askpass-url where the URL is flaky
##############################################
function e2e::auth_askpass_url_flaky() {
    # run with askpass_url service which alternates good/bad replies.
    HITLOG="$WORK/hitlog"
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            if [ -f /tmp/flag ]; then
                echo "HTTP/1.1 200 OK"
                echo
                echo "username=my-username"
                echo "password=my-password"
                rm /tmp/flag
            else
                echo "HTTP/1.1 503 Service Unavailable"
                echo
                touch /tmp/flag
            fi
            ')
    IP=$(docker_ip "$CTR")

    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$IP/git_askpass" \
        --max-failures=2 \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
}

##############################################
# Test askpass-url where the URL fails at startup
##############################################
function e2e::auth_askpass_url_slow_start() {
    # run with askpass_url service which takes a while to come up
    HITLOG="$WORK/hitlog"
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        --entrypoint sh \
        e2e/test/ncsvr \
        -c "sleep 4;
            /ncsvr.sh 80 'read X
                echo \"HTTP/1.1 200 OK\"
                echo
                echo \"username=my-username\"
                echo \"password=my-password\"
                '")
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --period=1s \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$IP/git_askpass" \
        --max-failures=5 \
        &
    sleep 1
    assert_file_absent "$ROOT/link"

    wait_for_sync 5
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test exechook-success
##############################################
function e2e::exechook_success() {
    cat /dev/null > "$RUNLOG"

    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --exechook-command="/$EXECHOOK_COMMAND" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/exechook"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"
    assert_file_eq "$ROOT/link/exechook" "$FUNCNAME 1"
    assert_file_eq "$ROOT/link/exechook-env" "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL"
    assert_file_lines_eq "$RUNLOG" 1

    # Move forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/exechook"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"
    assert_file_eq "$ROOT/link/exechook" "$FUNCNAME 2"
    assert_file_eq "$ROOT/link/exechook-env" "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL"
    assert_file_lines_eq "$RUNLOG" 2
}

##############################################
# Test exechook-fail-retry
##############################################
function e2e::exechook_fail_retry() {
    cat /dev/null > "$RUNLOG"

    # First sync - return a failure to ensure that we try again
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --exechook-command="/$EXECHOOK_COMMAND_FAIL" \
        --exechook-backoff=1s \
        &
    sleep 3 # give it time to retry

    # Check that exechook was called
    assert_file_lines_ge "$RUNLOG" 2
}

##############################################
# Test exechook-success with --one-time
##############################################
function e2e::exechook_success_once() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --exechook-command="/$EXECHOOK_COMMAND_SLEEPY"

    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/exechook"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_file_eq "$ROOT/link/exechook" "$FUNCNAME"
    assert_file_eq "$ROOT/link/exechook-env" "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL"
}

##############################################
# Test exechook-fail with --one-time
##############################################
function e2e::exechook_fail_once() {
    cat /dev/null > "$RUNLOG"

    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --exechook-command="/$EXECHOOK_COMMAND_FAIL_SLEEPY" \
            --exechook-backoff=1s

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_file_lines_eq "$RUNLOG" 1
}

##############################################
# Test exechook at startup with correct SHA
##############################################
function e2e::exechook_startup_after_crash() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"

    # No changes to repo

    cat /dev/null > "$RUNLOG"
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$MAIN_BRANCH" \
        --root="$ROOT" \
        --link="link" \
        --exechook-command="/$EXECHOOK_COMMAND"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/exechook"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_file_eq "$ROOT/link/exechook" "$FUNCNAME"
    assert_file_eq "$ROOT/link/exechook-env" "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL"
    assert_file_lines_eq "$RUNLOG" 1
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
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
           ')
    IP=$(docker_ip "$CTR")
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --link="link" \
        &

    # check that basic call works
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_eq "$HITLOG" 1

    # Move forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"

    # check that another call works
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_eq "$HITLOG" 2
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
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 500 Internal Server Error"
            echo
           ')
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --link="link" \
        &

    # Check that webhook was called
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_ge "$HITLOG" 1

    # Now return 200, ensure that it gets called
    docker_kill "$CTR"
    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        --ip="$IP" \
        -v "$HITLOG":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
           ')
    sleep 2 # webhooks are async
    assert_file_lines_eq "$HITLOG" 1
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
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
           ')
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --period=100ms \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=200 \
        --link="link"

    # check that basic call works
    assert_file_lines_eq "$HITLOG" 1
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
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 500 Internal Server Error"
            echo
           ')
    IP=$(docker_ip "$CTR")

    assert_fail \
        GIT_SYNC \
            --period=100ms \
            --one-time \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --webhook-url="http://$IP" \
            --webhook-success-status=200 \
            --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_file_lines_eq "$HITLOG" 1
}

##############################################
# Test webhook fire-and-forget
##############################################
function e2e::webhook_fire_and_forget() {
    HITLOG="$WORK/hitlog"

    cat /dev/null > "$HITLOG"
    CTR=$(docker_run \
        -v "$HITLOG":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 404 Not Found"
            echo
           ')
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$IP" \
        --webhook-success-status=0 \
        --link="link" \
        &

    # check that basic call works
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_eq "$HITLOG" 1
}

##############################################
# Test http handler
##############################################
function e2e::expose_http() {
    GIT_SYNC \
        --git="/$SLOW_GIT_FETCH" \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &

    # do nothing, just wait for the HTTP to come up
    for i in $(seq 1 5); do
        sleep 1
        if curl --silent --output /dev/null http://localhost:$HTTP_PORT; then
            break
        fi
        if [[ "$i" == 5 ]]; then
            fail "HTTP server failed to start"
        fi
    done

    # check that health endpoint fails
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$HTTP_PORT) -ne 503 ]] ; then
        fail "health endpoint should have failed: $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$HTTP_PORT)"
    fi
    wait_for_sync "${MAXWAIT}"

    # check that health endpoint is alive
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$HTTP_PORT) -ne 200 ]] ; then
        fail "health endpoint failed"
    fi

    # check that the metrics endpoint exists
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$HTTP_PORT/metrics) -ne 200 ]] ; then
        fail "metrics endpoint failed"
    fi

    # check that the pprof endpoint exists
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$HTTP_PORT/debug/pprof/) -ne 200 ]] ; then
        fail "pprof endpoint failed"
    fi
}

##############################################
# Test http handler after restart
##############################################
function e2e::expose_http_after_restart() {
    # Sync once to set up the repo
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"

    # Sync again and prove readiness.
    GIT_SYNC \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    # do nothing, just wait for the HTTP to come up
    for i in $(seq 1 5); do
        sleep 1
        if curl --silent --output /dev/null http://localhost:$HTTP_PORT; then
            break
        fi
        if [[ "$i" == 5 ]]; then
            fail "HTTP server failed to start"
        fi
    done

    sleep 2 # wait for first loop to confirm synced

    # check that health endpoint is alive
    if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$HTTP_PORT) -ne 200 ]] ; then
        fail "health endpoint failed"
    fi
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test submodule sync
##############################################
function e2e::submodule_sync_default() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "init submodule.file"

    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$WORK/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE/nested-submodule.file"
    git -C "$NESTED_SUBMODULE" add nested-submodule.file
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule.file"

    # Add submodule
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$SUBMODULE "$SUBMODULE_REPO_NAME"
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    # Make change in submodule repo
    echo "$FUNCNAME 2" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" commit -qam "$FUNCNAME 2"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2

    # Move backward in submodule repo
    git -C "$SUBMODULE" reset -q --hard HEAD^
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3

    # Add nested submodule to submodule repo
    git -C "$SUBMODULE" -c protocol.file.allow=always submodule add -q file://$NESTED_SUBMODULE "$NESTED_SUBMODULE_REPO_NAME"
    git -C "$SUBMODULE" commit -aqm "add nested submodule"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 4"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule.file" "nested-submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 4

    # Remove nested submodule
    git -C "$SUBMODULE" submodule deinit -q $NESTED_SUBMODULE_REPO_NAME
    rm -rf "$SUBMODULE/.git/modules/$NESTED_SUBMODULE_REPO_NAME"
    git -C "$SUBMODULE" rm -qf $NESTED_SUBMODULE_REPO_NAME
    git -C "$SUBMODULE" commit -aqm "delete nested submodule"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 5"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_absent "$ROOT/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 5

    # Remove submodule
    git -C "$REPO" submodule deinit -q $SUBMODULE_REPO_NAME
    rm -rf "$REPO/.git/modules/$SUBMODULE_REPO_NAME"
    git -C "$REPO" rm -qf $SUBMODULE_REPO_NAME
    git -C "$REPO" commit -aqm "delete submodule"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_absent "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 6

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

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"

    # First sync
    expected_depth="1"
    echo "$FUNCNAME 1" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "submodule $FUNCNAME 1"
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$SUBMODULE "$SUBMODULE_REPO_NAME"
    git -C "$REPO" config -f "$REPO/.gitmodules" "submodule.$SUBMODULE_REPO_NAME.shallow" true
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(git -C "$ROOT/link/$SUBMODULE_REPO_NAME" rev-list HEAD | wc -l)
    if [[ $expected_depth != $submodule_depth ]]; then
        fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi

    # Move forward
    echo "$FUNCNAME 2" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" commit -aqm "submodule $FUNCNAME 2"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "$FUNCNAME 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "forward depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(git -C "$ROOT/link/$SUBMODULE_REPO_NAME" rev-list HEAD | wc -l)
    if [[ $expected_depth != $submodule_depth ]]; then
        fail "forward submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi

    # Move backward
    git -C "$SUBMODULE" reset -q --hard HEAD^
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote  > /dev/null 2>&1
    git -C "$REPO" commit -qam "$FUNCNAME 3"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "$FUNCNAME 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $expected_depth != $depth ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(git -C "$ROOT/link/$SUBMODULE_REPO_NAME" rev-list HEAD | wc -l)
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
    echo "submodule" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Add submodule
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$SUBMODULE
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --submodules=off \
        &
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
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
    echo "submodule" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$WORK/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE/nested-submodule.file"
    git -C "$NESTED_SUBMODULE" add nested-submodule.file
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"
    git -C "$SUBMODULE" -c protocol.file.allow=always submodule add -q file://$NESTED_SUBMODULE "$NESTED_SUBMODULE_REPO_NAME"
    git -C "$SUBMODULE" commit -aqm "add nested submodule"

    # Add submodule
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$SUBMODULE "$SUBMODULE_REPO_NAME"
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --submodules=shallow \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_absent "$ROOT/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule.file"
    rm -rf $SUBMODULE
    rm -rf $NESTED_SUBMODULE
}

##############################################
# Test submodule sync with a relative path
##############################################
function e2e::submodule_sync_relative() {
    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "init submodule file"

    # Add submodule
    REL="$(realpath --relative-to "$REPO" "$WORK/$SUBMODULE_REPO_NAME")"
    echo $REL
    git -C "$REPO" -c protocol.file.allow=always submodule add -q "$REL" "$SUBMODULE_REPO_NAME"
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_eq "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file" "submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    rm -rf $SUBMODULE
}

##############################################
# Test submodules over SSH with different keys
##############################################
function e2e::submodule_sync_over_ssh_different_keys() {
    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$WORK/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE/nested-submodule.file"
    git -C "$NESTED_SUBMODULE" add nested-submodule.file
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule.file"

    # Run a git-over-SSH server.  Use key #1.
    CTR_SUBSUB=$(docker_run \
        -v "$DOT_SSH/server/1":/dot_ssh:ro \
        -v "$NESTED_SUBMODULE":/git/repo:ro \
        e2e/test/sshd)
    IP_SUBSUB=$(docker_ip "$CTR_SUBSUB")

    # Tell local git not to do host checking and to use the test keys.
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $DOT_SSH/1/id_local -i $DOT_SSH/2/id_local"

    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "init submodule.file"

    # Add nested submodule to submodule repo
    git -C "$SUBMODULE" submodule add -q "test@$IP_SUBSUB:/git/repo" "$NESTED_SUBMODULE_REPO_NAME"
    git -C "$SUBMODULE" commit -aqm "add nested submodule"

    # Run a git-over-SSH server.  Use key #2.
    CTR_SUB=$(docker_run \
        -v "$DOT_SSH/server/2":/dot_ssh:ro \
        -v "$SUBMODULE":/git/repo:ro \
        e2e/test/sshd)
    IP_SUB=$(docker_ip "$CTR_SUB")

    # Add the submodule to the main repo
    git -C "$REPO" submodule add -q "test@$IP_SUB:/git/repo" "$SUBMODULE_REPO_NAME"
    git -C "$REPO" commit -aqm "add submodule"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1

    # Run a git-over-SSH server.  Use key #3.
    CTR=$(docker_run \
        -v "$DOT_SSH/server/3":/dot_ssh:ro \
        -v "$REPO":/git/repo:ro \
        e2e/test/sshd)
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --period=100ms \
        --repo="test@$IP:/git/repo" \
        --root="$ROOT" \
        --link="link" \
        --ssh-key-file="/ssh/secret.1" \
        --ssh-key-file="/ssh/secret.2" \
        --ssh-key-file="/ssh/secret.3" \
        --ssh-known-hosts=false \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    rm -rf $SUBMODULE
    rm -rf $NESTED_SUBMODULE
}

##############################################
# Test submodules over HTTP with different passwords
##############################################
function e2e::submodule_sync_over_http_different_passwords() {
    # Init nested submodule repo
    NESTED_SUBMODULE_REPO_NAME="nested-sub"
    NESTED_SUBMODULE="$WORK/$NESTED_SUBMODULE_REPO_NAME"
    mkdir "$NESTED_SUBMODULE"

    git -C "$NESTED_SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$NESTED_SUBMODULE/nested-submodule.file"
    git -C "$NESTED_SUBMODULE" add nested-submodule.file
    git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule.file"

    # Run a git-over-SSH server.  Use password "test1".
    echo 'test:$apr1$cXiFWR90$Pmoz7T8kEmlpC9Bpj4MX3.' > "$WORK/htpasswd.1"
    CTR_SUBSUB=$(docker_run \
        -v "$NESTED_SUBMODULE":/git/repo:ro \
        -v "$WORK/htpasswd.1":/etc/htpasswd:ro \
        e2e/test/httpd)
    IP_SUBSUB=$(docker_ip "$CTR_SUBSUB")

    # Init submodule repo
    SUBMODULE_REPO_NAME="sub"
    SUBMODULE="$WORK/$SUBMODULE_REPO_NAME"
    mkdir "$SUBMODULE"

    git -C "$SUBMODULE" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$SUBMODULE/submodule.file"
    git -C "$SUBMODULE" add submodule.file
    git -C "$SUBMODULE" commit -aqm "init submodule.file"

    # Add nested submodule to submodule repo
    echo -ne "url=http://$IP_SUBSUB/repo\nusername=test\npassword=test1\n" | git credential approve
    git -C "$SUBMODULE" submodule add -q "http://$IP_SUBSUB/repo" "$NESTED_SUBMODULE_REPO_NAME"
    git -C "$SUBMODULE" commit -aqm "add nested submodule"

    # Run a git-over-SSH server.  Use password "test2".
    echo 'test:$apr1$vWBoWUBS$2H.WFxF8T7rH/gZF99Edl/' > "$WORK/htpasswd.2"
    CTR_SUB=$(docker_run \
        -v "$SUBMODULE":/git/repo:ro \
        -v "$WORK/htpasswd.2":/etc/htpasswd:ro \
        e2e/test/httpd)
    IP_SUB=$(docker_ip "$CTR_SUB")

    # Add the submodule to the main repo
    echo -ne "url=http://$IP_SUB/repo\nusername=test\npassword=test2\n" | git credential approve
    git -C "$REPO" submodule add -q "http://$IP_SUB/repo" "$SUBMODULE_REPO_NAME"
    git -C "$REPO" commit -aqm "add submodule"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1

    # Run a git-over-SSH server.  Use password "test3".
    echo 'test:$apr1$oKP2oGwp$ESJ4FESEP/8Sisy02B/vM/' > "$WORK/htpasswd.3"
    CTR=$(docker_run \
        -v "$REPO":/git/repo:ro \
        -v "$WORK/htpasswd.3":/etc/htpasswd:ro \
        e2e/test/httpd)
    IP=$(docker_ip "$CTR")

    GIT_SYNC \
        --period=100ms \
        --repo="http://$IP/repo" \
        --root="$ROOT" \
        --link="link" \
        --credential="{ \"url\": \"http://$IP_SUBSUB/repo\", \"username\": \"test\", \"password\": \"test1\" }" \
        --credential="{ \"url\": \"http://$IP_SUB/repo\", \"username\": \"test\", \"password\": \"test2\" }" \
        --credential="{ \"url\": \"http://$IP/repo\", \"username\": \"test\", \"password\": \"test3\" }" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/submodule.file"
    assert_file_exists "$ROOT/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    rm -rf $SUBMODULE
    rm -rf $NESTED_SUBMODULE
}

##############################################
# Test sparse-checkout files
##############################################
function e2e::sparse_checkout() {
    echo "!/*" > "$WORK/sparseconfig"
    echo "!/*/" >> "$WORK/sparseconfig"
    echo "file2" >> "$WORK/sparseconfig"
    echo "$FUNCNAME" > "$REPO/file"
    echo "$FUNCNAME" > "$REPO/file2"
    mkdir "$REPO/dir"
    echo "$FUNCNAME" > "$REPO/dir/file3"
    git -C "$REPO" add file2
    git -C "$REPO" add dir
    git -C "$REPO" commit -qam "$FUNCNAME"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --sparse-checkout-file="$WORK/sparseconfig"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file2"
    assert_file_absent "$ROOT/link/file"
    assert_file_absent "$ROOT/link/dir/file3"
    assert_file_absent "$ROOT/link/dir"
    assert_file_eq "$ROOT/link/file2" "$FUNCNAME"
}

##############################################
# Test additional git configs
##############################################
function e2e::additional_git_configs() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git-config='http.postBuffer:10485760,sect.k1:"a val",sect.k2:another val'
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test export-error
##############################################
function e2e::export_error() {
    assert_fail \
        GIT_SYNC \
            --repo="file://$REPO" \
            --ref=does-not-exit \
            --root="$ROOT" \
            --link="link" \
            --error-file="error.json"
        assert_file_absent "$ROOT/link"
        assert_file_absent "$ROOT/link/file"
        assert_file_contains "$ROOT/error.json" "couldn't find remote ref"

    # the error.json file should be removed if sync succeeds.
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --error-file="error.json"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
    assert_file_absent "$ROOT/error.json"
}

##############################################
# Test export-error with an absolute path
##############################################
function e2e::export_error_abs_path() {
    assert_fail \
        GIT_SYNC \
            --repo="file://$REPO" \
            --ref=does-not-exit \
            --root="$ROOT" \
            --link="link" \
            --error-file="$ROOT/dir/error.json"
        assert_file_absent "$ROOT/link"
        assert_file_absent "$ROOT/link/file"
        assert_file_contains "$ROOT/dir/error.json" "couldn't find remote ref"
}

##############################################
# Test touch-file
##############################################
function e2e::touch_file() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --touch-file="touch.file" \
        &
    wait_for_file_exists "$ROOT/touch.file" 3
    assert_file_exists "$ROOT/touch.file"
    rm -f "$ROOT/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/touch.file"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_file_exists "$ROOT/touch.file" 3
    assert_file_exists "$ROOT/touch.file"
    rm -f "$ROOT/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/touch.file"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_file_exists "$ROOT/touch.file" 3
    assert_file_exists "$ROOT/touch.file"
    rm -f "$ROOT/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/touch.file"
}

##############################################
# Test touch-file with an absolute path
##############################################
function e2e::touch_file_abs_path() {
    # First sync
    echo "$FUNCNAME 1" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --touch-file="$ROOT/dir/touch.file" \
        &
    wait_for_file_exists "$ROOT/dir/touch.file" 3
    assert_file_exists "$ROOT/dir/touch.file"
    rm -f "$ROOT/dir/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/dir/touch.file"

    # Move HEAD forward
    echo "$FUNCNAME 2" > "$REPO/file"
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    wait_for_file_exists "$ROOT/dir/touch.file" 3
    assert_file_exists "$ROOT/dir/touch.file"
    rm -f "$ROOT/dir/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 2"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/dir/touch.file"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_file_exists "$ROOT/dir/touch.file" 3
    assert_file_exists "$ROOT/dir/touch.file"
    rm -f "$ROOT/dir/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/dir/touch.file"
}

##############################################
# Test github HTTPS
##############################################
function e2e::github_https() {
    GIT_SYNC \
        --one-time \
        --repo="https://github.com/kubernetes/git-sync" \
        --root="$ROOT" \
        --link="link"
    assert_file_exists "$ROOT/link/LICENSE"
}

##############################################
# Test git-gc default
##############################################
function e2e::gc_default() {
    SHA1=$(git -C "$REPO" rev-parse HEAD)
    dd if=/dev/urandom of="$REPO/big1" bs=1024 count=4096 >/dev/null
    git -C "$REPO" add .
    git -C "$REPO" commit -qam "$FUNCNAME 1"
    SHA2=$(git -C "$REPO" rev-parse HEAD)
    dd if=/dev/urandom of="$REPO/big2" bs=1024 count=4096 >/dev/null
    git -C "$REPO" add .
    git -C "$REPO" commit -qam "$FUNCNAME 2"
    SHA3=$(git -C "$REPO" rev-parse HEAD)

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$SHA3" \
        --depth=0
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/big1"
    assert_file_exists "$ROOT/link/big2"
    SIZE=$(du -s "$ROOT" | cut -f1)
    if [ "$SIZE" -lt 14000 ]; then
        fail "repo is impossibly small: $SIZE"
    fi
    if [ "$SIZE" -gt 18000 ]; then
        fail "repo is too big: $SIZE"
    fi

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$SHA3" \
        --depth=1
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/big1"
    assert_file_exists "$ROOT/link/big2"
    SIZE=$(du -s "$ROOT" | cut -f1)
    if [ "$SIZE" -lt 14000 ]; then
        fail "repo is impossibly small: $SIZE"
    fi
    if [ "$SIZE" -gt 18000 ]; then
        fail "repo is too big: $SIZE"
    fi

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$SHA2" \
        --depth=1
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/big1"
    assert_file_absent "$ROOT/link/big2"
    SIZE=$(du -s "$ROOT" | cut -f1)
    if [ "$SIZE" -lt 7000 ]; then
        fail "repo is impossibly small: $SIZE"
    fi
    if [ "$SIZE" -gt 9000 ]; then
        fail "repo is too big: $SIZE"
    fi

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$SHA1" \
        --depth=1
    assert_link_exists "$ROOT/link"
    assert_file_absent "$ROOT/link/big1"
    assert_file_absent "$ROOT/link/big2"
    SIZE=$(du -s "$ROOT" | cut -f1)
    if [ "$SIZE" -lt 100 ]; then
        fail "repo is impossibly small: $SIZE"
    fi
    if [ "$SIZE" -gt 1000 ]; then
        fail "repo is too big: $SIZE"
    fi
}

##############################################
# Test git-gc=auto
##############################################
function e2e::gc_auto() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git-gc="auto"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test git-gc=always
##############################################
function e2e::gc_always() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git-gc="always"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test git-gc=aggressive
##############################################
function e2e::gc_aggressive() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git-gc="aggressive"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
}

##############################################
# Test git-gc=off
##############################################
function e2e::gc_off() {
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git-gc="off"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "$FUNCNAME"
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
make container REGISTRY=e2e VERSION="${E2E_TAG}" ALLOW_STALE_APT=1
make test-tools REGISTRY=e2e

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
export GIT_CONFIG_GLOBAL="$DIR/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email "git-sync-test@example.com"
git config --global user.name "git-sync-test"

# Make sure files we create can be group writable.
umask 0002

# Mark all repos as safe, to avoid "dubious ownership".
git config --global --add safe.directory '*'

# Store credentials for the test.
git config --global credential.helper "store --file $DIR/gitcreds"

FAILS=()
FINAL_RET=0
RUNS="${RUNS:-1}"

echo
echo "test root is $DIR"
if (( "${RUNS}" > 1 )); then
    echo "  RUNS=$RUNS"
fi
if [[ "${CLEANUP:-}" == 0 ]]; then
    echo "  CLEANUP disabled"
fi
if [[ -n "${VERBOSE:-}" ]]; then
    echo "  VERBOSE enabled"
fi
echo

# Iterate over the chosen tests and run them.
for t; do
    TEST_FN="e2e::${t}"
    TEST_RET=0
    RUN=0
    while (( "${RUN}" < "${RUNS}" )); do
        clean_root
        clean_work
        init_repo "${TEST_FN}"

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
        run_test RUN_RET "${TEST_FN}" >"${LOG}.${RUN}" 2>&1
        if [[ "$RUN_RET" == 0 ]]; then
            pass
        else
            TEST_RET=1
            if [[ "$RUN_RET" != 42 ]]; then
                echo "FAIL: unknown error"
            fi
            if [[ -n "${VERBOSE:-}" ]]; then
                echo -ne "\n\n"
                echo "LOG ----------------------"
                cat "${LOG}.${RUN}"
                echo "--------------------------"
                echo -ne "\n\n"
            fi
        fi
        remove_containers || true
        RUN=$((RUN+1))
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

