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


if [ -z "$1" -o -z "$2" ]; then
    echo "usage: $0 <port> <shell-command>"
    exit 1
fi

F="/tmp/fifo.$RANDOM"

while true; do
    rm -f "$F"
    mkfifo "$F"
    cat "$F" | sh -c "$2" 2>&1 | nc -l -p "$1" -N -w1 > "$F"
    date >> /var/log/hits
done
