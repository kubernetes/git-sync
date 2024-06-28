#!/bin/sh
#
# Copyright 2020 The Kubernetes Authors.
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

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "usage: $0 <port> <shell-command>"
    exit 1
fi

# This construction allows the passed-in command ($2) to optionally read from
# the client before responding (e.g. an HTTP request).
CMD_TO_NC=$(mktemp -u)
NC_TO_CMD=$(mktemp -u)
mkfifo "$CMD_TO_NC" "$NC_TO_CMD"
while true; do
    sh -c "$2" > "$CMD_TO_NC" 2>&1 < "$NC_TO_CMD" &
    nc -l -p "$1" -N -w1 < "$CMD_TO_NC" > "$NC_TO_CMD"
    date >> /var/log/hits
done
