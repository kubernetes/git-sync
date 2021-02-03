# Stolen from https://github.com/linuxkit/linuxkit/tree/master/pkg/sshd/

FROM alpine AS base

RUN mkdir -p /out/etc/apk && cp -r /etc/apk/* /out/etc/apk/
RUN apk add --no-cache --initdb -p /out \
    alpine-baselayout \
    apk-tools \
    busybox \
    util-linux \
    netcat-openbsd \
    && true

###############

FROM scratch

ENTRYPOINT []
WORKDIR /

COPY --from=base /out/ /

COPY ncsvr.sh /

ENTRYPOINT ["/ncsvr.sh"]
