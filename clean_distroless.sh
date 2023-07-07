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

# This script needs to be "sh" and not "bash", but there are no arrays in sh,
# except for "$@".  We need array semantics on the off chance we ever have a
# pathname with spaces in it.
#
# This list is not generic - it is specific to git-sync on debian bookworm.
set -- \
    /usr/share/base-files \
    /usr/share/doc \
    /usr/share/man \
    /usr/lib/*-linux-gnu/gconv \
    /usr/bin/c_rehash \
    /usr/bin/git-shell \
    /usr/bin/openssl \
    /usr/bin/scalar \
    /usr/bin/scp \
    /usr/bin/sftp \
    /usr/bin/ssh-add \
    /usr/bin/ssh-agent \
    /usr/bin/ssh-keygen \
    /usr/bin/ssh-keyscan \
    /usr/lib/git-core/git-shell \
    /usr/bin/openssl \
    /usr/lib/git-core/git-daemon \
    /usr/lib/git-core/git-http-backend \
    /usr/lib/git-core/git-http-fetch \
    /usr/lib/git-core/git-http-push \
    /usr/lib/git-core/git-imap-send \
    /usr/lib/openssh/ssh-keysign \
    /usr/lib/openssh/ssh-pkcs11-helper \
    /usr/lib/openssh/ssh-sk-helper \
    /usr/share/gitweb \
    /clean-distroless.sh

for item; do
    rm -rf "${ROOT}/${item}"
done
