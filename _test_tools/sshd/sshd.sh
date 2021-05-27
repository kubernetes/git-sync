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


KEYS=$(find /etc/ssh -name 'ssh_host_*_key')
[ -z "$KEYS" ] && ssh-keygen -A >/dev/null 2>/dev/null

# Copy creds for the test user, so we don't have to bake them into the image
# and so users don't have to manage permissions.
mkdir -p /home/test/.ssh
cp -a /dot_ssh/* /home/test/.ssh
chown -R test /home/test/.ssh
chmod 0700 /home/test/.ssh
chmod 0600 /home/test/.ssh/*

exec /usr/sbin/sshd -D -e
