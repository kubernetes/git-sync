#!/bin/sh

# Copyright 2022 The Kubernetes Authors.
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

# USAGE: clean-distroless.sh <staging_dir>

if [ -z "$1" ]; then
    echo "usage: $0 <staging-dir>"
    exit 1
fi
ROOT="$1"

# This script needs to be "sh" and not "bash", but there are no arrays in sh,
# except for "$@".  We need array semantics on the off chance we ever have a
# pathname with spaces in it.
set -- \
    /usr/share/base-files \
    /usr/share/man \
    /usr/lib/*-linux-gnu/gconv \
    /usr/bin/c_rehash \
    /usr/bin/openssl \
    /iptables-wrapper-installer.sh \
    /clean-distroless.sh

for item; do
    rm -rf "${ROOT}/${item}"
done
