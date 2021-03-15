#!/bin/sh

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
