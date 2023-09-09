# Copyright 2023 The Kubernetes Authors.
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
    git \
    git-daemon \
    nginx \
    fcgiwrap \
    apache2-utils \
    tini \
    && true

###############

FROM scratch

ENTRYPOINT []
WORKDIR /

COPY --from=base /out/ /

RUN htpasswd -b -c /etc/htpasswd testuser testpass

# Callers should mount a directory with git repos here.
VOLUME /git

COPY nginx.conf /etc/nginx/
COPY run.sh /

CMD ["/sbin/tini", "/run.sh"]
