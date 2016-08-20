#!/bin/sh

# Copyright 2016 The Kubernetes Authors All rights reserved.
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

# This script wraps the standard SSH binary so that the mounted SSH key can be used without user confirmation.
# In the Dockerfile, the original SSH binary is moved to /usr/bin/ssh-binary (and is then used as the base command here).
# This script is moved to /usr/bin/ssh so that Git uses it by default.

# The "UserKnownHostsFile" and "StrictHostKeyChecking" options avoid the user confirmation check.
# The -i flag specifies where the SSH key is located.

secret_path=/etc/git-secret/ssh
ssh-binary -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i $secret_path "$@"
