#!/bin/sh
#
# Copyright 2019 The Kubernetes Authors.
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

# This script uses the in-container shell which is limited.  For example, it
# does not support the 'pipefail' option.
set -o errexit
set -o nounset

# Ask pass some ops, fail if it mismatched the magic password.
if [ "$1" = "clone" -o "$1" = "ls-remote" -o "$1" = "fetch" ]; then
    # `git credential fill` requires the repo url match to consume the credentials stored by git-sync.
    # Askpass git only support repo started with "file://" which is used in test_e2e.sh.
    REPO=$(echo "$@" | grep -o "file://[^ ]*")
    OUTPUT=$(echo "url=${REPO}" | git credential fill)
    USERNAME=$(echo "${OUTPUT}" | grep "^username=.*")
    PASSWD=$(echo "${OUTPUT}" | grep "^password=.*")
    # Test case must match the magic username and password below.
    if [ "${USERNAME}" != "username=my-username" -o "${PASSWD}" != "password=my-password" ]; then
        echo "invalid test username/password pair: ${USERNAME}:${PASSWD}"
        exit 1
    fi
fi

git "$@"
