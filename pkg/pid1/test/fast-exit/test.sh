#!/bin/sh

go build
docker build -t example.com/fast-exit .

# In the past we have observed hangs and missed signals.  This *should* run
# forever.
while true; do
    docker run -ti --rm example.com/fast-exit
done
