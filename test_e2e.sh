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

# shellcheck disable=SC2120
function caller() {
    local stack_skip=${1:-0}
    stack_skip=$((stack_skip + 1))
    if [[ ${#FUNCNAME[@]} -gt ${stack_skip} ]]; then
        local i
        for ((i=1 ; i <= ${#FUNCNAME[@]} - stack_skip ; i++)); do
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

function skip() {
    echo "SKIP" >&3
    return 43
}

function pass() {
    echo "PASS"
}

# $1: a file/dir name
# $2: max seconds to wait
function wait_for_file_exists() {
    local file=$1
    local ticks=$(($2*10)) # 100ms per tick

    while (( ticks > 0 )); do
        if [[ -f "$file" ]]; then
            break
        fi
        sleep 0.1
        ticks=$((ticks-1))
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
    if [[ $(basename "$(readlink "$1")") == "$2" ]]; then
        return
    fi
    fail "$1 does not point to $2: $(readlink "$1")"
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
    fail "$1 does not contain '$2': $(cat "$1")"
}

function assert_file_contains() {
    if grep -q "$2" "$1"; then
        return
    fi
    fail "$1 does not contain '$2': $(cat "$1")"
}

function assert_file_lines_eq() {
    local n
    n=$(wc -l < "$1")
    if (( "$n" != "$2" )); then
        fail "$1 is not $2 lines: $n"
    fi
}

function assert_file_lines_ge() {
    local n
    n=$(wc -l < "$1")
    if (( "$n" < "$2" )); then
        fail "$1 is not at least $2 lines: $n"
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
        local ret=$?
        if [[ "$ret" != 0 ]]; then
            return
        fi
        fail "expected non-zero exit code, got $ret"
    )
}

# Helper: run a docker container.
function docker_run() {
    local rm="--rm"
    if [[ "${CLEANUP:-}" == 0 ]]; then
        rm=""
    fi
    docker run \
        -d \
        ${rm} `# not quoted on purpose` \
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

# Setting GIT_SYNC_E2E_IMAGE forces the test to use a specific image instead of the
# current tree.
build_container=false
if [[ "${GIT_SYNC_E2E_IMAGE:-unset}" == "unset" ]]; then
    GIT_SYNC_E2E_IMAGE="e2e/git-sync:${E2E_TAG}__$(go env GOOS)_$(go env GOARCH)"
    build_container=true
fi

# DIR is the directory in which all this test's state lives.
RUNID="${RANDOM}${RANDOM}"
DIR="/tmp/git-sync-e2e.$RUNID"
mkdir "$DIR"
function final_cleanup() {
    if [[ "${CLEANUP:-}" == 0 ]]; then
        echo "leaving logs in $DIR"
    else
        rm -rf "$DIR"
    fi
}
# Set the trap to call the final_cleanup function on exit.
trap final_cleanup EXIT

skip_github_app_test="${SKIP_GITHUB_APP_TEST:-true}"
required_env_vars=()
LOCAL_GITHUB_APP_PRIVATE_KEY_FILE="github_app_private_key.pem"
GITHUB_APP_PRIVATE_KEY_MOUNT=()
if [[ "${skip_github_app_test}" != "true" ]]; then
    required_env_vars=(
        "TEST_GITHUB_APP_AUTH_TEST_REPO"
        "TEST_GITHUB_APP_APPLICATION_ID"
        "TEST_GITHUB_APP_INSTALLATION_ID"
        "TEST_GITHUB_APP_CLIENT_ID"
    )

    if [[ -n "${TEST_GITHUB_APP_PRIVATE_KEY_FILE:-}" && -n "${TEST_GITHUB_APP_PRIVATE_KEY:-}" ]]; then
          echo "ERROR: Both TEST_GITHUB_APP_PRIVATE_KEY_FILE and TEST_GITHUB_APP_PRIVATE_KEY were specified."
          exit 1
    fi
    if [[ -n "${TEST_GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
        cp "${TEST_GITHUB_APP_PRIVATE_KEY_FILE}" "${DIR}/${LOCAL_GITHUB_APP_PRIVATE_KEY_FILE}"
    elif [[ -n "${TEST_GITHUB_APP_PRIVATE_KEY:-}" ]]; then
        echo "${TEST_GITHUB_APP_PRIVATE_KEY}" > "${DIR}/${LOCAL_GITHUB_APP_PRIVATE_KEY_FILE}"
    else
        echo "ERROR: Neither TEST_GITHUB_APP_PRIVATE_KEY_FILE nor TEST_GITHUB_APP_PRIVATE_KEY was specified."
        echo "       Either provide a value or skip this test (SKIP_GITHUB_APP_TEST=true)."
        exit 1
    fi

    # Validate all required environment variables for the github-app-auth tests are provided.
    for var in "${required_env_vars[@]}"; do
        if [[ ! -v "${var}" ]]; then
            echo "ERROR: Required environment variable '${var}' is not set."
            echo "       Either provide a value or skip this test (SKIP_GITHUB_APP_TEST=true)."
            exit 1
        fi
    done

    # Mount the GitHub App private key file to the git-sync container
    GITHUB_APP_PRIVATE_KEY_MOUNT=(-v "${DIR}/${LOCAL_GITHUB_APP_PRIVATE_KEY_FILE}":"/${LOCAL_GITHUB_APP_PRIVATE_KEY_FILE}":ro)
fi

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
    local arg="${1}"

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
    local rm="--rm"
    if [[ "${CLEANUP:-}" == 0 ]]; then
        rm=""
    fi
    docker run \
        -i \
        ${rm} `# not quoted on purpose` \
        --label git-sync-e2e="$RUNID" \
        --network="host" \
        -u git-sync:"$(id -g)" `# rely on GID, triggering "dubious ownership"` \
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
        "${GITHUB_APP_PRIVATE_KEY_MOUNT[@]}" \
        "${GIT_SYNC_E2E_IMAGE}" \
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
        | while read -r ctr; do
            docker kill "$ctr" >/dev/null
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
    assert_file_eq "$ROOT/subdir/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/subdir/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/subdir/root/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test HEAD syncing
##############################################
function e2e::sync_head() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test sync with an absolute-path link
##############################################
function e2e::sync_head_absolute_link() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/other/dir/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/root/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/root/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test sync with a subdir-path link
##############################################
function e2e::sync_head_subdir_link() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/other/dir/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link"
    assert_link_exists "$ROOT/other/dir/link"
    assert_file_exists "$ROOT/other/dir/link/file"
    assert_file_eq "$ROOT/other/dir/link/file" "${FUNCNAME[0]} 1"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read -r ctr; do
            docker pause "$ctr" >/dev/null
        done

    # make a second commit
    echo "${FUNCNAME[0]}-ok" > "$REPO/file2"
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "${FUNCNAME[0]} new file"

    # make a worktree to collide with git-sync
    local sha
    sha=$(git -C "$REPO" rev-list -n1 HEAD)
    git -C "$REPO" worktree add -q "$ROOT/.worktrees/$sha" -b e2e --no-checkout
    chmod g+w "$ROOT/.worktrees/$sha"

    # add some garbage
    mkdir -p "$ROOT/.worktrees/not_a_hash/subdir"
    touch "$ROOT/.worktrees/not_a_directory"

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read -r ctr; do
            docker unpause "$ctr" >/dev/null
        done

    wait_for_sync "${MAXWAIT}"
    assert_file_exists "$ROOT/link/file2"
    assert_file_eq "$ROOT/link/file2" "${FUNCNAME[0]}-ok"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
    assert_file_absent "$ROOT/.worktrees/$sha"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read -r ctr; do
            docker pause "$ctr" >/dev/null
        done

    # make a unexpected removal
    local wt
    wt=$(git -C "$REPO" rev-list -n1 HEAD)
    rm -r "$ROOT/.worktrees/$wt"

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read -r ctr; do
            docker unpause "$ctr" >/dev/null
        done

    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # suspend time so we can fake corruption
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read -r ctr; do
            docker pause "$ctr" >/dev/null
        done

    # Corrupt it
    echo "unexpected" > "$ROOT/link/file"
    git -C "$ROOT/link" commit -qam "corrupt it"

    # resume time
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read -r ctr; do
            docker unpause "$ctr" >/dev/null
        done

    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
}

##############################################
# Test stale-worktree-timeout
##############################################
function e2e::stale_worktree_timeout() {
    echo "${FUNCNAME[0]} 1" > "$REPO"/file
    git -C "$REPO" commit -qam "${FUNCNAME[0]}"
    local wt1
    wt1=$(git -C "$REPO" rev-list -n1 HEAD)
    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --stale-worktree-timeout="5s" \
        &

    # wait for first sync
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # wait 2 seconds and make another commit
    sleep 2
    echo "${FUNCNAME[0]} 2" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "${FUNCNAME[0]} new file"
    local wt2
    wt2=$(git -C "$REPO" rev-list -n1 HEAD)

    # wait for second sync
    wait_for_sync "${MAXWAIT}"
    # at this point both wt1 and wt2 should exist, with
    # link pointing to the new wt2
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"

    # wait 2 seconds and make a third commit
    sleep 2
    echo "${FUNCNAME[0]} 3" > "$REPO"/file3
    git -C "$REPO" add file3
    git -C "$REPO" commit -qam "${FUNCNAME[0]} new file"
    local wt3
    wt3=$(git -C "$REPO" rev-list -n1 HEAD)

    wait_for_sync "${MAXWAIT}"

    # at this point wt1, wt2, wt3 should exist, with
    # link pointing to wt3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/link/file3"
    assert_file_exists "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"
    assert_file_absent "$ROOT/.worktrees/$wt1/file3"
    assert_file_exists "$ROOT/.worktrees/$wt2/file"
    assert_file_exists "$ROOT/.worktrees/$wt2/file2"
    assert_file_absent "$ROOT/.worktrees/$wt2/file3"
    assert_file_exists "$ROOT/.worktrees/$wt3/file"
    assert_file_exists "$ROOT/.worktrees/$wt3/file2"
    assert_file_exists "$ROOT/.worktrees/$wt3/file3"

    # wait for wt1 to go stale
    sleep 4

    # now wt1 should be stale and deleted,
    # wt2 and wt3 should still exist
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/link/file3"
    assert_file_absent "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"
    assert_file_absent "$ROOT/.worktrees/$wt1/file3"
    assert_file_exists "$ROOT/.worktrees/$wt2/file"
    assert_file_exists "$ROOT/.worktrees/$wt2/file2"
    assert_file_absent "$ROOT/.worktrees/$wt2/file3"
    assert_file_exists "$ROOT/.worktrees/$wt3/file"
    assert_file_exists "$ROOT/.worktrees/$wt3/file2"
    assert_file_exists "$ROOT/.worktrees/$wt3/file3"

    # wait for wt2 to go stale
    sleep 2

    # now both wt1 and wt2 are stale, wt3 should be the only
    # worktree left
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/link/file3"
    assert_file_absent "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"
    assert_file_absent "$ROOT/.worktrees/$wt1/file3"
    assert_file_absent "$ROOT/.worktrees/$wt2/file"
    assert_file_absent "$ROOT/.worktrees/$wt2/file2"
    assert_file_absent "$ROOT/.worktrees/$wt2/file3"
    assert_file_exists "$ROOT/.worktrees/$wt3/file"
    assert_file_exists "$ROOT/.worktrees/$wt3/file2"
    assert_file_exists "$ROOT/.worktrees/$wt3/file3"
}

##############################################
# Test stale-worktree-timeout with restarts
##############################################
function e2e::stale_worktree_timeout_restart() {
    echo "${FUNCNAME[0]} 1" > "$REPO"/file
    git -C "$REPO" commit -qam "${FUNCNAME[0]}"
    local wt1
    wt1=$(git -C "$REPO" rev-list -n1 HEAD)
    GIT_SYNC \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --one-time

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # wait 2 seconds and make another commit
    sleep 2
    echo "${FUNCNAME[0]} 2" > "$REPO"/file2
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "${FUNCNAME[0]} new file"
    local wt2
    wt2=$(git -C "$REPO" rev-list -n1 HEAD)

    # restart git-sync
    GIT_SYNC \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --stale-worktree-timeout="10s" \
            --one-time

    # at this point both wt1 and wt2 should exist, with
    # link pointing to the new wt2
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"

    # wait 2 seconds and make a third commit
    sleep 4
    echo "${FUNCNAME[0]} 3" > "$REPO"/file3
    git -C "$REPO" add file3
    git -C "$REPO" commit -qam "${FUNCNAME[0]} new file"
    local wt3
    wt3=$(git -C "$REPO" rev-list -n1 HEAD)

    # restart git-sync
    GIT_SYNC \
                --repo="file://$REPO" \
                --root="$ROOT" \
                --link="link" \
                --stale-worktree-timeout="10s" \
                --one-time

    # at this point wt1, wt2, wt3 should exist, with
    # link pointing to wt3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/link/file3"
    assert_file_exists "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"
    assert_file_absent "$ROOT/.worktrees/$wt1/file3"
    assert_file_exists "$ROOT/.worktrees/$wt2/file"
    assert_file_exists "$ROOT/.worktrees/$wt2/file2"
    assert_file_absent "$ROOT/.worktrees/$wt2/file3"
    assert_file_exists "$ROOT/.worktrees/$wt3/file"
    assert_file_exists "$ROOT/.worktrees/$wt3/file2"
    assert_file_exists "$ROOT/.worktrees/$wt3/file3"

    # wait for wt1 to go stale and restart git-sync
    sleep 8
    GIT_SYNC \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --stale-worktree-timeout="10s" \
            --one-time

    # now wt1 should be stale and deleted,
    # wt2 and wt3 should still exist
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/link/file3"
    assert_file_absent "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"
    assert_file_absent "$ROOT/.worktrees/$wt1/file3"
    assert_file_exists "$ROOT/.worktrees/$wt2/file"
    assert_file_exists "$ROOT/.worktrees/$wt2/file2"
    assert_file_absent "$ROOT/.worktrees/$wt2/file3"
    assert_file_exists "$ROOT/.worktrees/$wt3/file"
    assert_file_exists "$ROOT/.worktrees/$wt3/file2"
    assert_file_exists "$ROOT/.worktrees/$wt3/file3"

    # wait for wt2 to go stale and restart git-sync
    sleep 4
    GIT_SYNC \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --stale-worktree-timeout="10s" \
            --one-time

    # now both wt1 and wt2 are stale, wt3 should be the only
    # worktree left
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/file2"
    assert_file_exists "$ROOT/link/file3"
    assert_file_absent "$ROOT/.worktrees/$wt1/file"
    assert_file_absent "$ROOT/.worktrees/$wt1/file2"
    assert_file_absent "$ROOT/.worktrees/$wt1/file3"
    assert_file_absent "$ROOT/.worktrees/$wt2/file"
    assert_file_absent "$ROOT/.worktrees/$wt2/file2"
    assert_file_absent "$ROOT/.worktrees/$wt2/file3"
    assert_file_exists "$ROOT/.worktrees/$wt3/file"
    assert_file_exists "$ROOT/.worktrees/$wt3/file2"
    assert_file_exists "$ROOT/.worktrees/$wt3/file3"
}

##############################################
# Test v3->v4 upgrade
##############################################
function e2e::v3_v4_upgrade_in_place() {
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]}"

    # sync once
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # simulate v3's worktrees
    local wt
    wt="$(readlink "$ROOT/link")"
    local sha
    sha="$(basename "$wt")"
    mv -f "$ROOT/$wt" "$ROOT/$sha"
    ln -sf "$sha" "$ROOT/link"

    # make a second commit
    echo "${FUNCNAME[0]} 2" > "$REPO/file2"
    git -C "$REPO" add file2
    git -C "$REPO" commit -qam "${FUNCNAME[0]} new file"

    # sync again
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_file_exists "$ROOT/link/file2"
    assert_file_eq "$ROOT/link/file2" "${FUNCNAME[0]} 2"
    assert_file_absent "$ROOT/$sha"
}

##############################################
# Test readlink
##############################################
function e2e::readlink() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_link_basename_eq "$ROOT/link" "$(git -C "$REPO" rev-parse HEAD)"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_link_basename_eq "$ROOT/link" "$(git -C "$REPO" rev-parse HEAD)"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_link_basename_eq "$ROOT/link" "$(git -C "$REPO" rev-parse HEAD)"
}

##############################################
# Test branch syncing
##############################################
function e2e::sync_branch() {
    local other_branch="other-branch"

    # First sync
    git -C "$REPO" checkout -q -b "$other_branch"
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    git -C "$REPO" checkout -q "$MAIN_BRANCH"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$other_branch" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Add to the branch.
    git -C "$REPO" checkout -q "$other_branch"
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    git -C "$REPO" checkout -q "$MAIN_BRANCH"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move the branch backward
    git -C "$REPO" checkout -q "$other_branch"
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" checkout -q "$MAIN_BRANCH"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test switching branch after depth=1 checkout
##############################################
function e2e::sync_branch_switch() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$MAIN_BRANCH" \
        --depth=1 \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    local other_branch="${MAIN_BRANCH}2"
    git -C "$REPO" checkout -q -b $other_branch
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$other_branch" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
}

##############################################
# Test tag syncing
##############################################
function e2e::sync_tag() {
    local tag="e2e-tag"

    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    git -C "$REPO" tag -f "$tag" >/dev/null

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$tag" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Add something and move the tag forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    git -C "$REPO" tag -f "$tag" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move the tag backward
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" tag -f "$tag" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3

    # Add something after the tag
    echo "${FUNCNAME[0]} 3" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test tag syncing with annotated tags
##############################################
function e2e::sync_annotated_tag() {
    local tag="e2e-tag"

    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    git -C "$REPO" tag -af "$tag" -m "${FUNCNAME[0]} 1" >/dev/null

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$tag" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Add something and move the tag forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    git -C "$REPO" tag -af "$tag" -m "${FUNCNAME[0]} 2" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2

    # Move the tag backward
    git -C "$REPO" reset -q --hard HEAD^
    git -C "$REPO" tag -af "$tag" -m "${FUNCNAME[0]} 3" >/dev/null
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3

    # Add something after the tag
    echo "${FUNCNAME[0]} 3" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
}

##############################################
# Test SHA syncing
##############################################
function e2e::sync_sha() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    local sha
    sha=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --ref="$sha" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Commit something new
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Revert the last change
    git -C "$REPO" reset -q --hard HEAD^
    sleep 1 # touch-file will not be touched
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1
}

##############################################
# Test SHA-sync one-time
##############################################
function e2e::sync_sha_once() {
    local sha
    sha=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test SHA-sync on a different SHA we already have
##############################################
function e2e::sync_sha_once_sync_different_sha_known() {
    # All revs will be known because we check out the branch
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    local sha1
    sha1=$(git -C "$REPO" rev-list -n1 HEAD)
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    local sha2
    sha2=$(git -C "$REPO" rev-list -n1 HEAD)
    echo "${FUNCNAME[0]} 3" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"

    # Sync sha1
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha1" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Sync sha2
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha2" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
}

##############################################
# Test SHA-sync on a different SHA we do not have
##############################################
function e2e::sync_sha_once_sync_different_sha_unknown() {
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    local sha1
    sha1=$(git -C "$REPO" rev-list -n1 HEAD)

    # Sync sha1
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha1" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # The locally synced repo does not know this new SHA.
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    local sha2
    sha2=$(git -C "$REPO" rev-list -n1 HEAD)
    # Make sure the SHA is not at HEAD, to prevent things that only work in
    # that case.
    echo "${FUNCNAME[0]} 3" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"

    # Sync sha2
    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha2" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test syncing if a file named for the SHA exists
##############################################
function e2e::sync_sha_shafile_exists() {
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    local sha1
    sha1=$(git -C "$REPO" rev-list -n1 HEAD)
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    local sha2
    sha2=$(git -C "$REPO" rev-list -n1 HEAD)

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha1" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    touch "$ROOT/$sha2"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --ref="$sha2" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
}

##############################################
# Test changing repos with storage intact
##############################################
function e2e::sync_repo_switch() {
    # Prepare first repo
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    # First sync
    GIT_SYNC \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --one-time
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Prepare other repo
    echo "${FUNCNAME[0]} 2" > "$REPO2/file"
    git -C "$REPO2" commit -qam "${FUNCNAME[0]} 2"

    # Now sync the other repo
    GIT_SYNC \
        --repo="file://$REPO2" \
        --root="$ROOT" \
        --link="link" \
        --one-time
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
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
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1

    # Move forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "$((MAXWAIT * 3))"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
}

##############################################
# Test sync-on-signal with SIGHUP
##############################################
function e2e::sync_on_signal_sighup() {
     # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    # Send signal (note --period is 100s, signal should trigger sync)
    local ctr
    ctr=$(docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}")
    docker_signal "$ctr" SIGHUP
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
}

##############################################
# Test sync-on-signal with HUP
##############################################
function e2e::sync_on_signal_hup() {
     # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    # Send signal (note --period is 100s, signal should trigger sync)
    local ctr
    ctr=$(docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}")
    docker_signal "$ctr" SIGHUP
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
}

##############################################
# Test sync-on-signal with 1 (SIGHUP)
##############################################
function e2e::sync_on_signal_1() {
     # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    # Send signal (note --period is 100s, signal should trigger sync)
    local ctr
    ctr=$(docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}")
    docker_signal "$ctr" SIGHUP
    wait_for_sync 3
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
}

##############################################
# Test depth default is shallow
##############################################
function e2e::sync_depth_default_shallow() {
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    echo "${FUNCNAME[0]} 3" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    local depth
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ $depth != 1 ]]; then
        fail "expected depth 1, got $depth"
    fi
}

##############################################
# Test depth syncing across updates
##############################################
function e2e::sync_depth_across_updates() {
    local expected_depth=1
    local depth

    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    assert_metric_eq "${METRIC_FETCH_COUNT}" 1
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$depth" ]]; then
        fail "initial: expected depth $expected_depth, got $depth"
    fi

    # Move forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    assert_metric_eq "${METRIC_FETCH_COUNT}" 2
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$depth" ]]; then
        fail "forward: expected depth $expected_depth, got $depth"
    fi

    # Move backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    assert_metric_eq "${METRIC_FETCH_COUNT}" 3
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$depth" ]]; then
        fail "backward: expected depth $expected_depth, got $depth"
    fi
}

##############################################
# Test depth switching on back-to-back runs
##############################################
function e2e::sync_depth_change_on_restart() {
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    echo "${FUNCNAME[0]} 3" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"

    local depth

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
    local ctr
    ctr=$(docker_run \
        -v "$REPO":/git/repo:ro \
        e2e/test/httpd)
    local ip
    ip=$(docker_ip "$ctr")

    # Try with wrong username
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://$ip/repo" \
            --root="$ROOT" \
            --link="link" \
            --username="wrong" \
            --__env__GITSYNC_PASSWORD="testpass"
    assert_file_absent "$ROOT/link/file"

    # Try with wrong password
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://$ip/repo" \
            --root="$ROOT" \
            --link="link" \
            --username="testuser" \
            --__env__GITSYNC_PASSWORD="wrong"
    assert_file_absent "$ROOT/link/file"

    # Try with the right password
    GIT_SYNC \
        --one-time \
        --repo="http://$ip/repo" \
        --root="$ROOT" \
        --link="link" \
        --username="testuser" \
        --__env__GITSYNC_PASSWORD="testpass" \

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test HTTP basicauth with a password in the URL
##############################################
function e2e::auth_http_password_in_url() {
    # Run a git-over-HTTP server.
    local ctr
    ctr=$(docker_run \
        -v "$REPO":/git/repo:ro \
        e2e/test/httpd)
    local ip
    ip=$(docker_ip "$ctr")

    # Try with wrong username
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://wrong:testpass@$ip/repo" \
            --root="$ROOT" \
            --link="link"
    assert_file_absent "$ROOT/link/file"

    # Try with wrong password
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://testuser:wrong@$ip/repo" \
            --root="$ROOT" \
            --link="link"
    assert_file_absent "$ROOT/link/file"

    # Try with the right password
    GIT_SYNC \
        --one-time \
        --repo="http://testuser:testpass@$ip/repo" \
        --root="$ROOT" \
        --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test HTTP basicauth with a password-file
##############################################
function e2e::auth_http_password_file() {
    # Run a git-over-HTTP server.
    local ctr
    ctr=$(docker_run \
        -v "$REPO":/git/repo:ro \
        e2e/test/httpd)
    local ip
    ip=$(docker_ip "$ctr")

    # Make a password file with a bad password.
    echo -n "wrong" > "$WORK/password-file"

    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="http://$ip/repo" \
            --root="$ROOT" \
            --link="link" \
            --username="testuser" \
            --password-file="$WORK/password-file"
    assert_file_absent "$ROOT/link/file"

    # Make a password file the right password.
    echo -n "testpass" > "$WORK/password-file"

    GIT_SYNC \
        --one-time \
        --repo="http://$ip/repo" \
        --root="$ROOT" \
        --link="link" \
        --username="testuser" \
        --password-file="$WORK/password-file"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test SSH (user@host:path syntax)
##############################################
function e2e::auth_ssh() {
    # Run a git-over-SSH server.  Use key #3 to exercise the multi-key logic.
    local ctr
    ctr=$(docker_run \
        -v "$DOT_SSH/server/3":/dot_ssh:ro \
        -v "$REPO":/git/repo:ro \
        e2e/test/sshd)
    local ip
    ip=$(docker_ip "$ctr")

    # Try to sync with key #1.
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="test@$ip:/git/repo" \
            --root="$ROOT" \
            --link="link" \
            --ssh-known-hosts=false \
            --ssh-key-file="/ssh/secret.2"
    assert_file_absent "$ROOT/link/file"

    # Try to sync with multiple keys
    GIT_SYNC \
        --one-time \
        --repo="test@$ip:/git/repo" \
        --root="$ROOT" \
        --link="link" \
        --ssh-known-hosts=false \
        --ssh-key-file="/ssh/secret.1" \
        --ssh-key-file="/ssh/secret.2" \
        --ssh-key-file="/ssh/secret.3"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test SSH (ssh://user@host/path syntax)
##############################################
function e2e::auth_ssh_url() {
    # Run a git-over-SSH server.  Use key #3 to exercise the multi-key logic.
    local ctr
    ctr=$(docker_run \
        -v "$DOT_SSH/server/3":/dot_ssh:ro \
        -v "$REPO":/git/repo:ro \
        e2e/test/sshd)
    local ip
    ip=$(docker_ip "$ctr")

    # Try to sync with key #1.
    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="ssh://test@$ip/git/repo" \
            --root="$ROOT" \
            --link="link" \
            --ssh-known-hosts=false \
            --ssh-key-file="/ssh/secret.2"
    assert_file_absent "$ROOT/link/file"

    # Try to sync with multiple keys
    GIT_SYNC \
        --one-time \
        --repo="ssh://test@$ip/git/repo" \
        --root="$ROOT" \
        --link="link" \
        --ssh-known-hosts=false \
        --ssh-key-file="/ssh/secret.1" \
        --ssh-key-file="/ssh/secret.2" \
        --ssh-key-file="/ssh/secret.3"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test askpass-url with bad password
##############################################
function e2e::auth_askpass_url_wrong_password() {
    # run the askpass_url service with wrong password
    local hitlog="$WORK/hitlog"
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
            echo "username=my-username"
            echo "password=wrong"
            ')
    local ip
    ip=$(docker_ip "$ctr")

    assert_fail \
        GIT_SYNC \
            --one-time \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --link="link" \
            --git="/$ASKPASS_GIT" \
            --askpass-url="http://$ip/git_askpass"
    assert_file_absent "$ROOT/link/file"
}

##############################################
# Test askpass-url
##############################################
function e2e::auth_askpass_url_correct_password() {
    # run with askpass_url service with correct password
    local hitlog="$WORK/hitlog"
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
            echo "username=my-username"
            echo "password=my-password"
            ')
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$ip/git_askpass"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test askpass-url where the URL is sometimes wrong
##############################################
function e2e::auth_askpass_url_sometimes_wrong() {
    # run with askpass_url service which alternates good/bad replies.
    local hitlog="$WORK/hitlog"
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
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
    local ip
    ip=$(docker_ip "$ctr")

    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$ip/git_askpass" \
        --max-failures=2 \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
}

##############################################
# Test askpass-url where the URL is flaky
##############################################
function e2e::auth_askpass_url_flaky() {
    # run with askpass_url service which alternates good/bad replies.
    local hitlog="$WORK/hitlog"
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
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
    local ip
    ip=$(docker_ip "$ctr")

    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$ip/git_askpass" \
        --max-failures=2 \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"

    # Move HEAD backward
    git -C "$REPO" reset -q --hard HEAD^
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
}

##############################################
# Test askpass-url where the URL fails at startup
##############################################
function e2e::auth_askpass_url_slow_start() {
    # run with askpass_url service which takes a while to come up
    local hitlog="$WORK/hitlog"
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        --entrypoint sh \
        e2e/test/ncsvr \
        -c "sleep 4;
            /ncsvr.sh 80 'read X
                echo \"HTTP/1.1 200 OK\"
                echo
                echo \"username=my-username\"
                echo \"password=my-password\"
                '")
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --period=1s \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --git="/$ASKPASS_GIT" \
        --askpass-url="http://$ip/git_askpass" \
        --max-failures=5 \
        &
    sleep 1
    assert_file_absent "$ROOT/link"

    wait_for_sync 5
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test github app auth
##############################################
function e2e::auth_github_app_application_id() {
    if [[ "${skip_github_app_test}" == "true" ]]; then
        skip
    fi
    GIT_SYNC \
        --one-time \
        --repo="${TEST_GITHUB_APP_AUTH_TEST_REPO}" \
        --github-app-application-id "${TEST_GITHUB_APP_APPLICATION_ID}" \
        --github-app-installation-id "${TEST_GITHUB_APP_INSTALLATION_ID}" \
        --github-app-private-key-file "/${LOCAL_GITHUB_APP_PRIVATE_KEY_FILE}" \
        --root="${ROOT}" \
        --link="link"
    assert_file_exists "${ROOT}/link/LICENSE"
}

function e2e::auth_github_app_client_id() {
    if [[ "${skip_github_app_test}" == "true" ]]; then
        skip
    fi
    GIT_SYNC \
        --one-time \
        --repo="${TEST_GITHUB_APP_AUTH_TEST_REPO}" \
        --github-app-client-id "${TEST_GITHUB_APP_CLIENT_ID}" \
        --github-app-installation-id "${TEST_GITHUB_APP_INSTALLATION_ID}" \
        --github-app-private-key-file "/${LOCAL_GITHUB_APP_PRIVATE_KEY_FILE}" \
        --root="${ROOT}" \
        --link="link"
    assert_file_exists "${ROOT}/link/LICENSE"
}

##############################################
# Test exechook-success
##############################################
function e2e::exechook_success() {
    cat /dev/null > "$RUNLOG"

    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"
    assert_file_eq "$ROOT/link/exechook" "${FUNCNAME[0]} 1"
    assert_file_eq "$ROOT/link/exechook-env" "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL"
    assert_file_lines_eq "$RUNLOG" 1

    # Move forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/exechook"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"
    assert_file_eq "$ROOT/link/exechook" "${FUNCNAME[0]} 2"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_file_eq "$ROOT/link/exechook" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_file_eq "$ROOT/link/exechook" "${FUNCNAME[0]}"
    assert_file_eq "$ROOT/link/exechook-env" "$EXECHOOK_ENVKEY=$EXECHOOK_ENVVAL"
    assert_file_lines_eq "$RUNLOG" 1
}

##############################################
# Test webhook success
##############################################
function e2e::webhook_success() {
    local hitlog="$WORK/hitlog"

    # First sync
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
           ')
    local ip
    ip=$(docker_ip "$ctr")
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$ip" \
        --webhook-success-status=200 \
        --link="link" \
        &

    # check that basic call works
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_eq "$hitlog" 1

    # Move forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"

    # check that another call works
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_eq "$hitlog" 2
}

##############################################
# Test webhook fail-retry
##############################################
function e2e::webhook_fail_retry() {
    local hitlog="$WORK/hitlog"
    local script="$WORK/http_resp.sh"
    touch "$script"
    chmod 755 "$script"

    # First sync - return a failure to ensure that we try again
    cat /dev/null > "$hitlog"
    cat > "$script" << __EOF__
#!/bin/sh
read X
echo "HTTP/1.1 500 Internal Server Error"
echo
__EOF__
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        -v "$script":/http_resp.sh \
        e2e/test/ncsvr \
        80 '/http_resp.sh')
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$ip" \
        --webhook-success-status=200 \
        --link="link" \
        &

    # Check that webhook was called
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_ge "$hitlog" 1

    # Now return 200, ensure that it gets called
    cat /dev/null > "$hitlog"
    cat > "$script" << __EOF__
#!/bin/sh
read X
echo "HTTP/1.1 200 OK"
echo
__EOF__
    sleep 2 # webhooks are async
    assert_file_lines_eq "$hitlog" 1
}

##############################################
# Test webhook success with --one-time
##############################################
function e2e::webhook_success_once() {
    local hitlog="$WORK/hitlog"

    # First sync
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 200 OK"
            echo
           ')
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --period=100ms \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$ip" \
        --webhook-success-status=200 \
        --link="link"

    # check that basic call works
    assert_file_lines_eq "$hitlog" 1
}

##############################################
# Test webhook fail with --one-time
##############################################
function e2e::webhook_fail_retry_once() {
    local hitlog="$WORK/hitlog"

    # First sync - return a failure to ensure that we try again
    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 500 Internal Server Error"
            echo
           ')
    local ip
    ip=$(docker_ip "$ctr")

    assert_fail \
        GIT_SYNC \
            --period=100ms \
            --one-time \
            --repo="file://$REPO" \
            --root="$ROOT" \
            --webhook-url="http://$ip" \
            --webhook-success-status=200 \
            --link="link"

    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
    assert_file_lines_eq "$hitlog" 1
}

##############################################
# Test webhook fire-and-forget
##############################################
function e2e::webhook_fire_and_forget() {
    local hitlog="$WORK/hitlog"

    cat /dev/null > "$hitlog"
    local ctr
    ctr=$(docker_run \
        -v "$hitlog":/var/log/hits \
        e2e/test/ncsvr \
        80 'read X
            echo "HTTP/1.1 404 Not Found"
            echo
           ')
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --webhook-url="http://$ip" \
        --webhook-success-status=0 \
        --link="link" \
        &

    # check that basic call works
    wait_for_sync "${MAXWAIT}"
    sleep 1 # webhooks are async
    assert_file_lines_eq "$hitlog" 1
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
    if [[ $(curl --write-out '%{http_code}' --silent --output /dev/null http://localhost:$HTTP_PORT) -ne 503 ]] ; then
        fail "health endpoint should have failed: $(curl --write-out '%{http_code}' --silent --output /dev/null http://localhost:$HTTP_PORT)"
    fi
    wait_for_sync "${MAXWAIT}"

    # check that health endpoint is alive
    if [[ $(curl --write-out '%{http_code}' --silent --output /dev/null http://localhost:$HTTP_PORT) -ne 200 ]] ; then
        fail "health endpoint failed"
    fi

    # check that the metrics endpoint exists
    if [[ $(curl --write-out '%{http_code}' --silent --output /dev/null http://localhost:$HTTP_PORT/metrics) -ne 200 ]] ; then
        fail "metrics endpoint failed"
    fi

    # check that the pprof endpoint exists
    if [[ $(curl --write-out '%{http_code}' --silent --output /dev/null http://localhost:$HTTP_PORT/debug/pprof/) -ne 200 ]] ; then
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"

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
    if [[ $(curl --write-out '%{http_code}' --silent --output /dev/null http://localhost:$HTTP_PORT) -ne 200 ]] ; then
        fail "health endpoint failed"
    fi
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
}

##############################################
# Test submodule sync
##############################################
function e2e::submodule_sync_default() {
    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "init submodule.file"

    # Init nested submodule repo
    local nested_submodule_repo_name="nested-sub"
    local nested_submodule="$WORK/$nested_submodule_repo_name"
    mkdir "$nested_submodule"

    git -C "$nested_submodule" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$nested_submodule/nested-submodule.file"
    git -C "$nested_submodule" add nested-submodule.file
    git -C "$nested_submodule" commit -aqm "init nested-submodule.file"

    # Add submodule
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$submodule "$submodule_repo_name"
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
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    # Make change in submodule repo
    echo "${FUNCNAME[0]} 2" > "$submodule/submodule.file"
    git -C "$submodule" commit -qam "${FUNCNAME[0]} 2"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2

    # Move backward in submodule repo
    git -C "$submodule" reset -q --hard HEAD^
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3

    # Add nested submodule to submodule repo
    git -C "$submodule" -c protocol.file.allow=always submodule add -q file://$nested_submodule "$nested_submodule_repo_name"
    git -C "$submodule" commit -aqm "add nested submodule"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 4"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/$nested_submodule_repo_name/nested-submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/$nested_submodule_repo_name/nested-submodule.file" "nested-submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 4

    # Remove nested submodule
    git -C "$submodule" submodule deinit -q $nested_submodule_repo_name
    rm -rf "$submodule/.git/modules/$nested_submodule_repo_name"
    git -C "$submodule" rm -qf $nested_submodule_repo_name
    git -C "$submodule" commit -aqm "delete nested submodule"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 5"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_absent "$ROOT/link/$submodule_repo_name/$nested_submodule_repo_name/nested-submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 5

    # Remove submodule
    git -C "$REPO" submodule deinit -q $submodule_repo_name
    rm -rf "$REPO/.git/modules/$submodule_repo_name"
    git -C "$REPO" rm -qf $submodule_repo_name
    git -C "$REPO" commit -aqm "delete submodule"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_absent "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 6

    rm -rf $submodule
    rm -rf $nested_submodule
}

##############################################
# Test submodules depth syncing
##############################################
function e2e::submodule_sync_depth() {
    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"

    local expected_depth="1"
    local depth
    local submodule_depth

    # First sync
    echo "${FUNCNAME[0]} 1" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "submodule ${FUNCNAME[0]} 1"
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$submodule "$submodule_repo_name"
    git -C "$REPO" config -f "$REPO/.gitmodules" "submodule.$submodule_repo_name.shallow" true
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --depth="$expected_depth" \
        --root="$ROOT" \
        --link="link" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$depth" ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(git -C "$ROOT/link/$submodule_repo_name" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$submodule_depth" ]]; then
        fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi

    # Move forward
    echo "${FUNCNAME[0]} 2" > "$submodule/submodule.file"
    git -C "$submodule" commit -aqm "submodule ${FUNCNAME[0]} 2"
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote > /dev/null 2>&1
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "${FUNCNAME[0]} 2"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 2
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$depth" ]]; then
        fail "forward depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(git -C "$ROOT/link/$submodule_repo_name" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$submodule_depth" ]]; then
        fail "forward submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi

    # Move backward
    git -C "$submodule" reset -q --hard HEAD^
    git -C "$REPO" -c protocol.file.allow=always submodule update --recursive --remote  > /dev/null 2>&1
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 3"
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "${FUNCNAME[0]} 1"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 3
    depth=$(git -C "$ROOT/link" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$depth" ]]; then
        fail "initial depth mismatch expected=$expected_depth actual=$depth"
    fi
    submodule_depth=$(git -C "$ROOT/link/$submodule_repo_name" rev-list HEAD | wc -l)
    if [[ "$expected_depth" != "$submodule_depth" ]]; then
        fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
    fi
    rm -rf $submodule
}

##############################################
# Test submodules off
##############################################
function e2e::submodule_sync_off() {
    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "init submodule file"

    # Add submodule
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$submodule
    git -C "$REPO" commit -aqm "add submodule"

    GIT_SYNC \
        --period=100ms \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --submodules=off \
        &
    wait_for_sync "${MAXWAIT}"
    assert_file_absent "$ROOT/link/$submodule_repo_name/submodule.file"
    rm -rf $submodule
}

##############################################
# Test submodules shallow
##############################################
function e2e::submodule_sync_shallow() {
    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "init submodule file"

    # Init nested submodule repo
    local nested_submodule_repo_name="nested-sub"
    local nested_submodule="$WORK/$nested_submodule_repo_name"
    mkdir "$nested_submodule"

    git -C "$nested_submodule" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$nested_submodule/nested-submodule.file"
    git -C "$nested_submodule" add nested-submodule.file
    git -C "$nested_submodule" commit -aqm "init nested-submodule file"
    git -C "$submodule" -c protocol.file.allow=always submodule add -q file://$nested_submodule "$nested_submodule_repo_name"
    git -C "$submodule" commit -aqm "add nested submodule"

    # Add submodule
    git -C "$REPO" -c protocol.file.allow=always submodule add -q file://$submodule "$submodule_repo_name"
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
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_absent "$ROOT/link/$submodule_repo_name/$nested_submodule_repo_name/nested-submodule.file"
    rm -rf $submodule
    rm -rf $nested_submodule
}

##############################################
# Test submodule sync with a relative path
##############################################
function e2e::submodule_sync_relative() {
    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "init submodule file"

    # Add submodule
    local rel
    rel="$(realpath --relative-to "$REPO" "$WORK/$submodule_repo_name")"
    git -C "$REPO" -c protocol.file.allow=always submodule add -q "$rel" "$submodule_repo_name"
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
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_eq "$ROOT/link/$submodule_repo_name/submodule.file" "submodule"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    rm -rf $submodule
}

##############################################
# Test submodules over SSH with different keys
##############################################
function e2e::submodule_sync_over_ssh_different_keys() {
    # Init nested submodule repo
    local nested_submodule_repo_name="nested-sub"
    local nested_submodule="$WORK/$nested_submodule_repo_name"
    mkdir "$nested_submodule"

    git -C "$nested_submodule" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$nested_submodule/nested-submodule.file"
    git -C "$nested_submodule" add nested-submodule.file
    git -C "$nested_submodule" commit -aqm "init nested-submodule.file"

    # Run a git-over-SSH server.  Use key #1.
    local ctr_subsub
    ctr_subsub=$(docker_run \
        -v "$DOT_SSH/server/1":/dot_ssh:ro \
        -v "$nested_submodule":/git/repo:ro \
        e2e/test/sshd)
    local ip_subsub
    ip_subsub=$(docker_ip "$ctr_subsub")

    # Tell local git not to do host checking and to use the test keys.
    export GIT_SSH_COMMAND="ssh -F none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $DOT_SSH/1/id_local -i $DOT_SSH/2/id_local"

    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "init submodule.file"

    # Add nested submodule to submodule repo
    git -C "$submodule" submodule add -q "test@$ip_subsub:/git/repo" "$nested_submodule_repo_name"
    git -C "$submodule" commit -aqm "add nested submodule"

    # Run a git-over-SSH server.  Use key #2.
    local ctr_sub
    ctr_sub=$(docker_run \
        -v "$DOT_SSH/server/2":/dot_ssh:ro \
        -v "$submodule":/git/repo:ro \
        e2e/test/sshd)
    local ip_sub
    ip_sub=$(docker_ip "$ctr_sub")

    # Add the submodule to the main repo
    git -C "$REPO" submodule add -q "test@$ip_sub:/git/repo" "$submodule_repo_name"
    git -C "$REPO" commit -aqm "add submodule"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1

    # Run a git-over-SSH server.  Use key #3.
    local ctr
    ctr=$(docker_run \
        -v "$DOT_SSH/server/3":/dot_ssh:ro \
        -v "$REPO":/git/repo:ro \
        e2e/test/sshd)
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --period=100ms \
        --repo="test@$ip:/git/repo" \
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
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/$nested_submodule_repo_name/nested-submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    rm -rf $submodule
    rm -rf $nested_submodule
}

##############################################
# Test submodules over HTTP with different passwords
##############################################
function e2e::submodule_sync_over_http_different_passwords() {
    # Init nested submodule repo
    local nested_submodule_repo_name="nested-sub"
    local nested_submodule="$WORK/$nested_submodule_repo_name"
    mkdir "$nested_submodule"

    git -C "$nested_submodule" init -q -b "$MAIN_BRANCH"
    echo "nested-submodule" > "$nested_submodule/nested-submodule.file"
    git -C "$nested_submodule" add nested-submodule.file
    git -C "$nested_submodule" commit -aqm "init nested-submodule.file"

    # Run a git-over-SSH server.  Use password "test1".
    # shellcheck disable=SC2016
    echo 'test:$apr1$cXiFWR90$Pmoz7T8kEmlpC9Bpj4MX3.' > "$WORK/htpasswd.1"
    local ctr_subsub
    ctr_subsub=$(docker_run \
        -v "$nested_submodule":/git/repo:ro \
        -v "$WORK/htpasswd.1":/etc/htpasswd:ro \
        e2e/test/httpd)
    local ip_subsub
    ip_subsub=$(docker_ip "$ctr_subsub")

    # Init submodule repo
    local submodule_repo_name="sub"
    local submodule="$WORK/$submodule_repo_name"
    mkdir "$submodule"

    git -C "$submodule" init -q -b "$MAIN_BRANCH"
    echo "submodule" > "$submodule/submodule.file"
    git -C "$submodule" add submodule.file
    git -C "$submodule" commit -aqm "init submodule.file"

    # Add nested submodule to submodule repo
    echo -ne "url=http://$ip_subsub/repo\nusername=test\npassword=test1\n" | git credential approve
    git -C "$submodule" submodule add -q "http://$ip_subsub/repo" "$nested_submodule_repo_name"
    git -C "$submodule" commit -aqm "add nested submodule"

    # Run a git-over-SSH server.  Use password "test2".
    # shellcheck disable=SC2016
    echo 'test:$apr1$vWBoWUBS$2H.WFxF8T7rH/gZF99Edl/' > "$WORK/htpasswd.2"
    local ctr_sub
    ctr_sub=$(docker_run \
        -v "$submodule":/git/repo:ro \
        -v "$WORK/htpasswd.2":/etc/htpasswd:ro \
        e2e/test/httpd)
    local ip_sub
    ip_sub=$(docker_ip "$ctr_sub")

    # Add the submodule to the main repo
    echo -ne "url=http://$ip_sub/repo\nusername=test\npassword=test2\n" | git credential approve
    git -C "$REPO" submodule add -q "http://$ip_sub/repo" "$submodule_repo_name"
    git -C "$REPO" commit -aqm "add submodule"
    git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1

    # Run a git-over-SSH server.  Use password "test3".
    # shellcheck disable=SC2016
    echo 'test:$apr1$oKP2oGwp$ESJ4FESEP/8Sisy02B/vM/' > "$WORK/htpasswd.3"
    local ctr
    ctr=$(docker_run \
        -v "$REPO":/git/repo:ro \
        -v "$WORK/htpasswd.3":/etc/htpasswd:ro \
        e2e/test/httpd)
    local ip
    ip=$(docker_ip "$ctr")

    GIT_SYNC \
        --period=100ms \
        --repo="http://$ip/repo" \
        --root="$ROOT" \
        --link="link" \
        --credential="{ \"url\": \"http://$ip_subsub/repo\", \"username\": \"test\", \"password\": \"test1\" }" \
        --credential="{ \"url\": \"http://$ip_sub/repo\", \"username\": \"test\", \"password\": \"test2\" }" \
        --credential="{ \"url\": \"http://$ip/repo\", \"username\": \"test\", \"password\": \"test3\" }" \
        &
    wait_for_sync "${MAXWAIT}"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/submodule.file"
    assert_file_exists "$ROOT/link/$submodule_repo_name/$nested_submodule_repo_name/nested-submodule.file"
    assert_metric_eq "${METRIC_GOOD_SYNC_COUNT}" 1

    rm -rf $submodule
    rm -rf $nested_submodule
}

##############################################
# Test sparse-checkout files
##############################################
function e2e::sparse_checkout() {
    echo "!/*" > "$WORK/sparseconfig"
    echo "!/*/" >> "$WORK/sparseconfig"
    echo "file2" >> "$WORK/sparseconfig"
    echo "${FUNCNAME[0]}" > "$REPO/file"
    echo "${FUNCNAME[0]}" > "$REPO/file2"
    mkdir "$REPO/dir"
    echo "${FUNCNAME[0]}" > "$REPO/dir/file3"
    git -C "$REPO" add file2
    git -C "$REPO" add dir
    git -C "$REPO" commit -qam "${FUNCNAME[0]}"

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
    assert_file_eq "$ROOT/link/file2" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/touch.file"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_file_exists "$ROOT/touch.file" 3
    assert_file_exists "$ROOT/touch.file"
    rm -f "$ROOT/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/touch.file"
}

##############################################
# Test touch-file with an absolute path
##############################################
function e2e::touch_file_abs_path() {
    # First sync
    echo "${FUNCNAME[0]} 1" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

    # It should not come back until we commit again.
    sleep 1
    assert_file_absent "$ROOT/dir/touch.file"

    # Move HEAD forward
    echo "${FUNCNAME[0]} 2" > "$REPO/file"
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    wait_for_file_exists "$ROOT/dir/touch.file" 3
    assert_file_exists "$ROOT/dir/touch.file"
    rm -f "$ROOT/dir/touch.file"
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/file"
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 2"

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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]} 1"

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
    local sha1
    sha1=$(git -C "$REPO" rev-parse HEAD)
    dd if=/dev/urandom of="$REPO/big1" bs=1024 count=4096 >/dev/null
    git -C "$REPO" add .
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 1"
    local sha2
    sha2=$(git -C "$REPO" rev-parse HEAD)
    dd if=/dev/urandom of="$REPO/big2" bs=1024 count=4096 >/dev/null
    git -C "$REPO" add .
    git -C "$REPO" commit -qam "${FUNCNAME[0]} 2"
    local sha3
    sha3=$(git -C "$REPO" rev-parse HEAD)

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$sha3" \
        --depth=0
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/big1"
    assert_file_exists "$ROOT/link/big2"
    local size
    size=$(du -s "$ROOT" | cut -f1)
    if [ "$size" -lt 14000 ]; then
        fail "repo is impossibly small: $size"
    fi
    if [ "$size" -gt 18000 ]; then
        fail "repo is too big: $size"
    fi

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$sha3" \
        --depth=1
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/big1"
    assert_file_exists "$ROOT/link/big2"
    size=$(du -s "$ROOT" | cut -f1)
    if [ "$size" -lt 14000 ]; then
        fail "repo is impossibly small: $size"
    fi
    if [ "$size" -gt 18000 ]; then
        fail "repo is too big: $size"
    fi

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$sha2" \
        --depth=1
    assert_link_exists "$ROOT/link"
    assert_file_exists "$ROOT/link/big1"
    assert_file_absent "$ROOT/link/big2"
    size=$(du -s "$ROOT" | cut -f1)
    if [ "$size" -lt 7000 ]; then
        fail "repo is impossibly small: $size"
    fi
    if [ "$size" -gt 9000 ]; then
        fail "repo is too big: $size"
    fi

    GIT_SYNC \
        --one-time \
        --repo="file://$REPO" \
        --root="$ROOT" \
        --link="link" \
        --ref="$sha1" \
        --depth=1
    assert_link_exists "$ROOT/link"
    assert_file_absent "$ROOT/link/big1"
    assert_file_absent "$ROOT/link/big2"
    size=$(du -s "$ROOT" | cut -f1)
    if [ "$size" -lt 100 ]; then
        fail "repo is impossibly small: $size"
    fi
    if [ "$size" -gt 1000 ]; then
        fail "repo is too big: $size"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
    assert_file_eq "$ROOT/link/file" "${FUNCNAME[0]}"
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
            | while read -r X; do declare -F "$X"; done \
            | sort -n -k2 \
            | cut -f1 -d' ' \
            | sed 's/^e2e:://'
    )
}

# Figure out which, if any, tests to run.
mapfile -t all_tests < <(list_tests)
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
            if [[ " ${tests_to_run[*]} " == *" ${t} "* ]]; then
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
$build_container && make container REGISTRY=e2e VERSION="${E2E_TAG}" ALLOW_STALE_APT=1
make test-tools REGISTRY=e2e

function finish() {
    local ret=$?
    trap "" INT EXIT ERR
    if [[ $ret != 0 ]]; then
        echo
        echo "the directory $DIR was not removed as it contains"\
             "log files useful for debugging"
    fi
    exit $ret
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
    local retvar=$1
    shift

    declare -g "$retvar"
    local restore_opts
    restore_opts=$(set +o)
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

# Log some info
if [[ -n "${VERBOSE:-}" ]]; then
    git version
    echo
    docker version
    echo
fi

failures=()
final_ret=0
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
    test_fn="e2e::${t}"
    test_ret=0
    run=0
    while (( "${run}" < "${RUNS}" )); do
        clean_root
        clean_work
        init_repo "${test_fn}"

        sfx=""
        if (( "${RUNS}" > 1 )); then
            sfx=" ($((run+1))/${RUNS})"
        fi
        echo -n "testcase ${t}${sfx}: "

        # Set &3 for our own output, let testcases use &2 and &1.
        exec 3>&1

        # See comments on run_test for details.
        run_ret=0
        log="${DIR}/log.$t"
        run_test run_ret "${test_fn}" >"${log}.${run}" 2>&1
        if [[ "$run_ret" == 0 ]]; then
            pass
        elif [[ "$run_ret" == 43 ]]; then
            true # do nothing
        else
            test_ret=1
            if [[ "$run_ret" != 42 ]]; then
                echo "FAIL: unknown error"
            fi
            if [[ -n "${VERBOSE:-}" ]]; then
                echo -ne "\n\n"
                echo "log ----------------------"
                cat "${log}.${run}"
                echo "--------------------------"
                echo -ne "\n\n"
            fi
        fi
        remove_containers || true
        run=$((run+1))
    done
    if [[ "$test_ret" != 0 ]]; then
        final_ret=1
        failures+=("$t  (log: ${log}.*)")
    fi
done
if [[ "$final_ret" != 0 ]]; then
    echo
    echo "the following tests failed:"
    for f in "${failures[@]}"; do
        echo "    $f"
    done
    exit 1
fi


