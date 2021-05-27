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

# Stolen from https://github.com/linuxkit/linuxkit/tree/master/pkg/sshd/

FROM alpine AS base

RUN mkdir -p /out/etc/apk && cp -r /etc/apk/* /out/etc/apk/
RUN apk add --no-cache --initdb -p /out \
    alpine-baselayout \
    apk-tools \
    busybox \
    ca-certificates \
    git \
    musl \
    openssh-server \
    tini \
    util-linux \
    wireguard-tools \
    && true

###############

FROM scratch

ENTRYPOINT []
WORKDIR /

COPY --from=base /out/ /

RUN mkdir -p /etc/ssh && rm /etc/motd
COPY sshd_config /etc/ssh/
COPY sshd.sh /

# Callers should mount a .ssh directory here. Our sshd.sh will copy it and
# manage permissions.
VOLUME /dot_ssh

# Callers can SSH as user "test"
RUN echo "test:x:65533:65533::/home/test:/usr/bin/git-shell" >> /etc/passwd

CMD ["/sbin/tini", "/sshd.sh"]
