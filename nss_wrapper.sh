#!/bin/sh

echo "git-sync:x:$(id -u):$(id -g):git-sync:/tmp:/bin/sh" > /tmp/passwd
echo "git-sync:x:$(id -g):" > /tmp/group

exec /git-sync $*
