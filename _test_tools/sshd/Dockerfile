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
