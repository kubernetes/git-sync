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


go build
docker build -t example.com/fast-exit .

# This should exit(42)
docker run -ti --rm example.com/fast-exit
RET=$?
if [ "$RET" != 42 ]; then
    echo "FAIL: exit code was not preserved: $RET"
    exit 1
fi

# In the past we have observed hangs and missed signals.  This *should* run
# forever.
while true; do
    docker run -ti --rm example.com/fast-exit
done
