# Copyright 2026 The Kubernetes Authors.
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

# A minimal git-lfs server for tests.  The binary is built by `make test-tools`
# from the version pinned in tools/go.mod; this image just wraps it.

FROM scratch

COPY lfs-test-server /lfs-test-server

# No users, no auth: anyone can upload and download.  This is a test tool.
ENV LFS_PUBLIC=true
# Storage (a bolt DB and content files) is created in the current directory.
WORKDIR /

ENTRYPOINT ["/lfs-test-server"]
